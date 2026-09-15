# Гибридный балансировщик BOINC

Документ описывает архитектуру стенда, штатный scheduler, экспериментальную
политику и воспроизводимый протокол измерений.

## 1. Порядок работ

1. Зафиксировать baseline BOINC 8.3.0 и проверить один полный жизненный цикл
   workunit.
2. Поднять четыре CPU-профиля клиентов и исключить захват очереди первым
   клиентом.
3. Создать контролируемую смесь коротких, средних и длинных задач.
4. Собрать baseline-метрики при stable/moderate/heavy churn.
5. Включить custom policy тем же `config.xml`, не меняя workload.
6. Выполнить парные A/B-прогоны с одинаковыми профилями и churn.
7. Рассчитать доверительные интервалы и effect size.
8. Зафиксировать ограничения модели и подготовить графики для публикации.

## 2. Локальная модель гибридной системы

Основной стенд использует Docker Compose:

- `mysql`: состояние BOINC;
- `makeproject`: сборка текущего корневого `boinc/` и создание проекта;
- `apache`: scheduler CGI и backend daemons;
- `client-cluster`: 4 CPU, 4 GiB;
- `client-cluster-2`: 4 CPU, 4 GiB (идентичный peer для fairness among equals);
- `client-desktop`: 2 CPU, 2 GiB;
- `client-low-power`: 1 CPU, 1 GiB;
- `client-phone`: 0.5 CPU, 512 MiB;
- `client-phone-2`: 0.5 CPU, 512 MiB (идентичный mobile peer для churn/fairness).

Каждый клиент имеет отдельный BOINC data directory и поэтому регистрируется
как отдельный host. Гетерогенность задаётся одновременно через cgroup limits и
BOINC preferences. Это моделирует доступную вычислительную мощность, память,
work buffer и доступность, но не микроархитектуру другого CPU.

На Apple Silicon GPU passthrough в Linux-контейнеры не является корректной
моделью NVIDIA/AMD. Поэтому основной эксперимент CPU-only. Дополнительная
проверка выполняется в отдельной Linux ARM64 VM (UTM/QEMU), подключённой к тому
же проекту. Она подтверждает сетевую распределённость, но не используется как
доказательство GPU-балансировки.

## 3. Появление и исчезновение устройств

Профили churn:

- `stable`: все hosts работают весь прогон;
- `moderate`: у каждого клиента один цикл offline → restart;
- `heavy`: у каждого клиента `CHURN_CYCLES` таких циклов.

Отказы **рассинхронизированы**: каждый клиент крутит свой цикл в фоне, старт
сдвинут на `index × CHURN_STAGGER_SECONDS` (по умолчанию 8 с). Пока один host
offline, остальные могут продолжать работу. `CHURN_STAGGER_SECONDS=0` убирает
сдвиг — все циклы стартуют одновременно.

Churn реализован через `docker compose pause/unpause`: контейнер «пропадает из
сети», но BOINC-процесс не перезапускается и не теряет in-flight задачи.
`stop/start` убивали long/medium workunits после исчерпания `max_total_results`.
Когда все workunits validated, churn **останавливается** (оставшиеся циклы не
доигрываются, paused-контейнеры сразу unpause).

Все события записываются в `events.csv`. Основная партия workunits публикуется
только после запуска всех клиентов.

Захват очереди первым RPC ограничивают:

- `<max_wus_to_send>1</max_wus_to_send>`;
- `<max_wus_in_progress>2</max_wus_in_progress>`;
- work buffer порядка 17–120 секунд в зависимости от профиля;
- `target_nresults=1` и `min_quorum=1`;
- одновременный запуск клиентов до создания workload.

## 4. Разная сложность задач

Используется штатное приложение BOINC `uppercase`. Параметр
`--cpu_time N` выполняет реальную CPU-нагрузку, поэтому является ground truth.
Поле `rsc_fpops_est` — независимая оценка, доступная scheduler.

| Класс | CPU time | `rsc_fpops_est` | Deadline |
|---|---:|---:|---:|
| short | 5 s | 5e9 | 600 s |
| medium | 30 s | 3e10 | 1200 s |
| long | 120 s | 1.2e11 | 3600 s |

Количество классов задаётся переменными `SHORT_JOBS`, `MEDIUM_JOBS` и
`LONG_JOBS`.

## 5. Штатная балансировка BOINC

Путь одного запроса:

1. `send_work_setup()` вычисляет запрос в секундах, CPU/GPU, память, диск,
   reliability и квоты.
2. `send_work()` выбирает locality, old array scan или score scheduler.
3. `send_work_score()` сканирует shared-memory массив feeder, получает
   совместимую app version, рассчитывает BOINC score и сортирует кандидатов.
4. Fast и slow feasibility checks проверяют deadline, ресурсы, homogeneous
   redundancy и состояние result.
5. `add_result_to_reply()` атомарно насколько позволяет текущая архитектура
   обновляет WU/result и добавляет задание в RPC reply.

Штатный scheduler решает совместимость, квоты, deadline, replication,
reliability, CPU/GPU plan classes и file locality. Его основные ограничения для
гибридной системы:

- host рассматривается как единый ресурс, понятия cluster segment нет;
- нет глобального queue depth и normalized load по сегментам;
- locality описывает файлы одного host, а не shared storage кластера;
- score не оптимизирует глобальный makespan и fairness;
- нет структурированной телеметрии решений;
- фактическая доступность поступает с задержкой через host statistics.

## 6. Экспериментальная политика

`send_work_custom()` повторяет locking, quota и feasibility contract
`send_work_score()`. Изменяется только порядок допустимых кандидатов.

Для job `i` и host `j` (hybrid v3, churn-aware):

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

Следствия:

- быстрые hosts предпочитают крупные задачи;
- медленные hosts предпочитают короткие задачи;
- при низкой `availability` custom-члены ослабляются, baseline score доминирует;
- long/medium jobs штрафуются на phone/low-power и на flaky hosts;
- deadline pressure предотвращает голодание срочной работы.

Это проверяемая гипотеза, а не гарантированное улучшение. Ошибка
`rsc_fpops_est` или неверные веса могут ухудшить результат. Feature flag
`custom_load_balancer` позволяет A/B без пересборки.

Один dispatch-контур реализует четыре исследовательские политики:

| Политика | Ranking | Назначение |
|---|---|---|
| `random` | детерминированный hash `(result_id, host_id)` | слабый контроль P0 |
| `lpt` | максимальный predicted runtime первым | контроль P2 для makespan |
| `sjf` | минимальный predicted runtime первым | контроль P3 для response time |
| `hybrid` | size affinity + deadline + runtime penalty | предлагаемая P4 |

Штатный `send_work_score()` остаётся отдельным baseline при
`custom_load_balancer=0`.

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
- число failed/incomplete results.

Дополнительно сохраняются CPU time, elapsed time, FLOPS estimates, host
benchmarks, container limits, client/server logs, container statistics и
полный `config.xml`.

## 8. Запуск

Предварительно требуется Docker Desktop с Compose v2 и BuildKit.

```bash
# Парный baseline/hybrid прогон (по умолчанию moderate churn)
bash experiments/run_experiment.sh both

# Все пять политик
bash experiments/run_experiment.sh all

# Один режим
CHURN_PROFILE=stable bash experiments/run_experiment.sh baseline
CHURN_PROFILE=heavy bash experiments/run_experiment.sh sjf

# Стресс-тест с намеренно перепутанными оценками сложности
ESTIMATE_PROFILE=mixed bash experiments/run_experiment.sh all

# Управляемая длительность отказов
CHURN_PROFILE=heavy CHURN_ONLINE_SECONDS=30 \
CHURN_OFFLINE_SECONDS=20 CHURN_CYCLES=4 CHURN_STAGGER_SECONDS=10 \
bash experiments/run_experiment.sh hybrid

# Более короткий smoke test
SHORT_JOBS=4 MEDIUM_JOBS=2 LONG_JOBS=1 \
RUN_TIMEOUT_SECONDS=600 \
bash experiments/run_experiment.sh both
```

Каждый режим получает свежую БД и одинаковый состав workload. Артефакты:

```text
results/<pair-id>_<policy>/
├── manifest.json
├── events.csv
├── checksums.sha256
├── config/config.xml
├── raw/tasks.tsv
├── raw/hosts.tsv
├── raw/scheduler.log
├── raw/docker-compose.log
├── raw/container_stats.jsonl
└── analysis/
    ├── metrics.json
    ├── per_node.csv
    └── summary.csv
```

При запуске `both` рядом создаётся
`results/<pair-id>_comparison.json` с абсолютными и относительными отличиями
baseline/hybrid. Режим `all` создаёт `<pair-id>_policy_summary.csv`.

`results/` исключён из Git.

## 9. Методика анализа

Для каждого scenario/seed нужны парные прогоны политик. После
exploratory серии оценивается дисперсия и выбирается число повторов; начальная
цель — 10 exploratory и около 30 confirmatory пар.

Проверяемые гипотезы:

1. `lpt`/`hybrid` снижают makespan при гетерогенных host относительно baseline.
2. `sjf` снижает response коротких jobs, но ухудшает длинные.
3. Bounded dispatch сильнее влияет на fairness при heavy churn, чем ranking.
4. `hybrid` направляет большую долю long jobs стабильному cluster-сегменту.
5. При `ESTIMATE_PROFILE=mixed` size-aware политики деградируют сильнее
   baseline — оценка устойчивости к ошибкам runtime prediction.

Рекомендуется:

- bootstrap 95% CI для p95/p99;
- paired t-test либо Wilcoxon signed-rank;
- McNemar/Fisher для deadline misses;
- Cohen's d или Cliff's delta;
- Benjamini–Hochberg для множественных сравнений.

При публикации отдельно указываются ограничения: container quotas не меняют
ISA CPU, GPU не эмулируется, четыре клиента не моделируют Internet-scale BOINC,
а scheduler видит неполную и запаздывающую информацию о доступности.

## 10. Теоретическая база и план чтения

Материалы следует читать не как общий обзор, а связывать с гипотезами:

1. Krallmann, Schwiegelshohn, Yahyapour, *On the Design and Evaluation of Job
   Scheduling Systems* — критерии сравнения scheduler.
2. Pinedo, *Scheduling: Theory, Algorithms, and Systems* — parallel и unrelated
   machines, makespan и list scheduling.
3. Graham, работы о list scheduling и LPT — теоретическая база политики `lpt`.
4. Harchol-Balter, *Performance Modeling and Design of Computer Systems* —
   SJF/SRPT, response time и starvation.
5. Topcuoglu et al., HEFT — earliest-finish идеи для гетерогенных ресурсов.
6. Maheswaran et al., Min-min/Max-min/Sufferage — grid mapping эвристики.
7. Anderson, публикации по BOINC/public-resource computing — штатная модель
   volunteer scheduling.
8. Kondo, Taufer, Anderson, работы об availability/churn volunteer hosts —
   обоснование сценариев отказов.
9. Zaikin et al., CluBoRun — включение кластерных ресурсов в BOINC grid.
10. Jain, *The Art of Computer Systems Performance Analysis* — план
    эксперимента, повторения и доверительные интервалы.
11. Feitelson, *Workload Modeling for Computer Systems Performance Evaluation*
    — синтетические и репрезентативные workload.
12. Naik, Manthalkar, utilization-based scheduling — сигнал текущей загрузки.

Минимальная экспериментальная матрица для курсовой:

```text
policy:     baseline, random, lpt, sjf, hybrid
load:       low, saturated
churn:      stable, heavy
estimates:  accurate
repeats:    8–10 пар на ячейку

отдельный стресс:
policy × ESTIMATE_PROFILE=mixed
```

Не следует одновременно варьировать все доступные параметры. Каждая серия
меняет один фактор и отвечает на заранее записанную гипотезу.
