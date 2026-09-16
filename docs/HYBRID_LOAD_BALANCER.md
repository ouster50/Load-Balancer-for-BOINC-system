# Гибридный балансировщик BOINC

Данный файл описывает архитектуру тестового стенда, балансировщик по умолчанию "из коробки", экспериментальную
политику и описание самих экспериментов

## 1. Порядок работ

1. Зафиксировать baseline BOINC 8.3.0 и проверить один полный жизненный цикл
   workunit
2. Поднять четыре различных CPU-профиля клиентов и конфигурационно исключить захват всей очереди задач одним
   клиентом
3. Создать контролируемую группу коротких, средних и длинных задач
4. Собрать baseline-метрики при различных уровнях churn
5. Включить custom policy в конфиге, оставив остальные настройки без изменений
6. Выполнить A/B-прогоны с одинаковыми параметрами
7. Рассчитать доверительные интервалы
8. Зафиксировать ограничения модели тестирования, подготовить графики и числовые данные для демонстрации

## 2. Локальная модель гибридной системы

Основной стенд использует Docker Compose:

- `mysql`: база данных BOINC
- `makeproject`: сборка текущего корневого `boinc/` и создание проекта (запускается один раз и поднимает все остальные контейнеры)
- `apache`: сам сервер с балансировщиком нагрузки
- `client-cluster`: кластерный клиент - 4 CPU, 4 GiB
- `client-cluster-2`: кластерный клиент - 4 CPU, 4 GiB
- `client-desktop`: клиент ПК - 2 CPU, 2 GiB
- `client-low-power`: клиент ПК (послабее) - 1 CPU, 1 GiB
- `client-phone`: клиент мобильное устройство - 0.5 CPU, 512 MiB
- `client-phone-2`: клиент мобильное устройство - 0.5 CPU, 512 MiB

Решение сделать 2 кластера и 2 телефона было обусловлено несколькими причинами
- Кроме балансировки между разными по мощности клиентами надо также сравнивать балансировку между одинаковыми, что они делятся примерно поровну
- Разнообразие выборки клиентов
- Приближение модели к реальной жизни

Каждый клиент регистрируется как отдельный host. Гетерогенность задаётся одновременно через cgroup limits и BOINC preferences. Это моделирует доступную вычислительную мощность, память, work buffer и доступность, но не микроархитектуру другого CPU.

На Apple Silicon GPU passthrough в Linux-контейнеры не является корректной моделью NVIDIA/AMD. Поэтому основной эксперимент CPU-only. Дополнительная проверка выполняется в отдельной Linux ARM64 VM (UTM/QEMU), подключённой к тому же проекту. Она подтверждает сетевую распределённость, но не используется как доказательство GPU-балансировки.

## 3. Моделирование переменной доступности устройств

Профили churn:

- `stable`: все хосты работают стабильно на протяжении всего прогона
- `moderate`: у каждого клиента ровно один цикл: выключение -> включение
- `heavy`: у каждого клиента `CHURN_CYCLES` таких циклов

Отказы рассинхронизированы: каждый клиент крутит свой цикл в фоне, старт для каждого сдвинут на `index × CHURN_STAGGER_SECONDS` (по умолчанию 8 секунд). Пока один хост недоступен, остальные могут продолжать работу

Churn реализован через `docker compose pause/unpause`: контейнер приостанавливает работу, сохраняя задачи в работе

Все события записываются в `events.csv`

Захват очереди первым хостом ограничивают:

- `<max_wus_to_send>1</max_wus_to_send>`
- `<max_wus_in_progress>2</max_wus_in_progress>`
- work buffer порядка 17–120 секунд в зависимости от профиля
- `target_nresults=1` и `min_quorum=1`
- одновременный запуск клиентов до создания workload

## 4. Разнообразие задач

Используется штатное приложение BOINC `uppercase`. Параметр
`--cpu_time N` эмулирует реальную CPU-нагрузку.
Поле `rsc_fpops_est` — независимая оценка, доступная балансировщику.

| Класс | CPU time | `rsc_fpops_est` | Deadline |
|---|---:|---:|---:|
| short | 5 s | 5e9 | 600 s |
| medium | 30 s | 3e10 | 1200 s |
| long | 120 s | 1.2e11 | 3600 s |

Количество задач каждого типа задаётся переменными соответственно: `SHORT_JOBS`, `MEDIUM_JOBS` и
`LONG_JOBS`.

## 5. Балансировка BOINC по умолчанию

Жизненный цикл запроса:

1. `send_work_setup()` вычисляет запрос в секундах, CPU/GPU, память, диск,
   reliability и квоты.
2. `send_work()` выбирает locality, old array scan или score scheduler.
3. `send_work_score()` сканирует shared-memory массив feeder, получает
   совместимую app version, рассчитывает BOINC score и сортирует кандидатов.
4. Fast и slow feasibility checks проверяют deadline, ресурсы, homogeneous
   redundancy и состояние result.
5. `add_result_to_reply()` атомарно насколько позволяет текущая архитектура
   обновляет WU/result и добавляет задание в RPC reply.

Штатный балансировщик анализирует совместимость, квоты, deadline, replication,
reliability, CPU/GPU plan classes и file locality. Его основные ограничения для
гибридной системы:

- хост рассматривается как единый ресурс, понятия cluster segment нет
- нет глобального queue depth и normalized load по сегментам
- locality описывает файлы одного host, а не shared storage кластера
- score не оптимизирует глобальный makespan и fairness
- нет структурированной телеметрии решений
- фактическая доступность поступает с задержкой через host statistics

## 6. Экспериментальная политика

`send_work_custom()` повторяет locking, quota и feasibility contract
`send_work_score()`. Изменяется только порядок допустимых кандидатов.

Для job `i` и host `j`:

```text
availability_j = clamp(cpu_available_frac_j, 0.15, 1.0)
effective_time_ij = predicted_time_ij / availability_j
runtime_ratio_ij = clamp(effective_time_ij / target_runtime, 0.01, 100)
size_affinity_ij = -abs(log(runtime_ratio_ij)) * availability_j
host_fit_ij = (log(1 + host_speed_j) - log(1 + effective_time_ij)) * availability_j^2
slow_host_long_penalty_ij = 0
  if predicted_time_ij > 0.5 * target_runtime and host_speed_j < 2:
    1.5 * (predicted_time_ij / target_runtime) * (2 - host_speed_j) / availability_j
  elif predicted_time_ij > target_runtime and host_speed_j < 4:
    0.5 * (predicted_time_ij / target_runtime - 1) * (4 - host_speed_j) / availability_j

score_ij =
    (25 + 55 * availability_j) * boinc_score_ij
  + w_size * size_affinity_ij
  + w_deadline * target_runtime / delay_bound_i
  - w_runtime * log(1 + effective_time_ij / target_runtime)
  + 0.05 * w_size * host_fit_ij
  - w_runtime * slow_host_long_penalty_ij
```

Плюсы:

- быстрые hosts предпочитают крупные задачи
- медленные hosts предпочитают короткие задачи
- при низкой доступности custom-члены ослабляются, baseline score доминирует (отсутствует деградация)
- long/medium jobs штрафуются на phone/low-power и на часто отваливающихся хостах
- deadline pressure предотвращает долгое ожидание следующей задачи

Тестовый стенд реализует четыре политики:

| Политика | Ranking | Назначение |
|---|---|---|
| `random` | детерминированный hash `(result_id, host_id)` | слабый контроль P0 |
| `lpt` | максимальный predicted runtime первым | контроль P2 для makespan |
| `sjf` | минимальный predicted runtime первым | контроль P3 для response time |
| `round_robin` | циклический: `result_id mod 6 -> host_id mod 6` | классический round robin для сравнения |
| `weighted_least_loaded` | `log(1 + speed * availability / (in_progress + 1))` | capacity-aware метод |
| `hybrid` | size affinity + deadline + runtime penalty | предлагаемая P4 |

Дефолтный `send_work_score()` остаётся baseline для контроля, что метрики не стали хуже, чем у балансировщика по умолчанию

Параметры `config.xml`:

```xml
<custom_load_balancer>1</custom_load_balancer>
<custom_lb_policy>hybrid</custom_lb_policy>
<custom_lb_target_runtime>30</custom_lb_target_runtime>
<custom_lb_size_weight>2</custom_lb_size_weight>
<custom_lb_deadline_weight>5</custom_lb_deadline_weight>
<custom_lb_runtime_weight>0.55</custom_lb_runtime_weight>
<debug_custom_load_balancer>1</debug_custom_load_balancer>
```

## 7. Метрики

Основные:

- throughput: `N_completed / observation_time`;
- response time: `received_time - workunit.create_time`;
- service time: `received_time - sent_time`;
- queueing delay: `sent_time - workunit.create_time`;
- makespan: `max(received_time) - min(workunit.create_time)`;
- deadline miss rate;
- utilization по host;
- coefficient of variation utilization;
- Jain fairness по числу завершённых задач;
- scheduler decision time p50/p95/p99;
- scheduler overhead как доля wall time;
- число failed / incomplete results.

Дополнительно сохраняются CPU time, elapsed time, FLOPS estimates, host
benchmarks, container limits, client/server logs, container statistics и
полный `config.xml`.

## 8. Запуск

Для запуска требуется Docker Desktop с Compose v2 и BuildKit.

```bash
# Парный baseline/hybrid прогон для быстрого стравнения baseline / кастомный балансировщик
bash experiments/run_experiment.sh both

# Все пять политик подряд (для полного сравнения)
bash experiments/run_experiment.sh all

# Один режим
CHURN_PROFILE=stable bash experiments/run_experiment.sh baseline
CHURN_PROFILE=heavy bash experiments/run_experiment.sh sjf

# Управляемая длительность отказов
CHURN_PROFILE=heavy CHURN_ONLINE_SECONDS=30 \
CHURN_OFFLINE_SECONDS=20 CHURN_CYCLES=4 CHURN_STAGGER_SECONDS=10 \
bash experiments/run_experiment.sh hybrid
```

Каждый запуск получает свою БД и фиксированный набор задач. Артефакты запуска:

```text
results/<pair-id>_<policy>/
├── manifest.json             настройки запуска
├── events.csv                события: отключения / включения клиентов
├── checksums.sha256
├── config/config.xml         конфиг запуска
├── raw/tasks.tsv
├── raw/hosts.tsv
├── raw/scheduler.log
├── raw/docker-compose.log
├── raw/container_stats.jsonl
└── analysis/
    ├── metrics.json          общие метрики по запуску
    ├── per_node.csv          метрики по каждому хосту
    └── summary.csv           краткая выжимка основных метрик из metrics.json
```

## 9. Эксперименты

Для предотвращения появления шума делалось по 3-5 запусков с одинаковыми параметрами, после чего бралось среднее значение по каждой метрике.
Было по группе запусков для каждого профиля CHURN: `stable`, `moderate`, `heavy`. Каждый раз прогонялись все 5 политик для корректного сравнения экспериментального подхода с остальными методами.
