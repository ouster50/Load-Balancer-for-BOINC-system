#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

REQUESTED_POLICY=${1:-both}
CHURN_PROFILE=${CHURN_PROFILE:-moderate}
CHURN_ONLINE_SECONDS=${CHURN_ONLINE_SECONDS:-20}
CHURN_OFFLINE_SECONDS=${CHURN_OFFLINE_SECONDS:-15}
CHURN_CYCLES=${CHURN_CYCLES:-3}
CHURN_STAGGER_SECONDS=${CHURN_STAGGER_SECONDS:-8}
ESTIMATE_PROFILE=${ESTIMATE_PROFILE:-accurate}
MAX_WUS_TO_SEND=${MAX_WUS_TO_SEND:-1}
MAX_WUS_IN_PROGRESS=${MAX_WUS_IN_PROGRESS:-2}
RUN_TIMEOUT_SECONDS=${RUN_TIMEOUT_SECONDS:-1800}
SHORT_JOBS=${SHORT_JOBS:-18}
MEDIUM_JOBS=${MEDIUM_JOBS:-12}
LONG_JOBS=${LONG_JOBS:-6}
PAIR_ID=${PAIR_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
KEEP_STACK=${KEEP_STACK:-0}

case "$REQUESTED_POLICY" in
    baseline|random|lpt|sjf|hybrid|custom) POLICIES=("$REQUESTED_POLICY") ;;
    both) POLICIES=(baseline hybrid) ;;
    all) POLICIES=(baseline random lpt sjf hybrid) ;;
    *) echo "Usage: $0 [baseline|random|lpt|sjf|hybrid|custom|both|all]" >&2; exit 2 ;;
esac
case "$CHURN_PROFILE" in
    stable|moderate|heavy) ;;
    *) echo "CHURN_PROFILE must be stable, moderate or heavy" >&2; exit 2 ;;
esac
case "$ESTIMATE_PROFILE" in
    accurate|underestimate|overestimate|mixed) ;;
    *) echo "ESTIMATE_PROFILE must be accurate, underestimate, overestimate or mixed" >&2; exit 2 ;;
esac

for command in docker curl python3; do
    command -v "$command" >/dev/null || {
        echo "Missing required command: $command" >&2
        exit 3
    }
done

if docker compose version >/dev/null 2>&1; then
    compose() { docker compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
    compose() { docker-compose "$@"; }
else
    echo "Missing required command: docker compose" >&2
    exit 3
fi
compose version >/dev/null

epoch_now() {
    python3 -c 'import time; print(time.time())'
}

ship_experiment() {
    COPYFILE_DISABLE=1 tar -cf - -C "$ROOT_DIR/experiments" .
}
UNPACK_EXPERIMENT='rm -rf /tmp/experiment && mkdir -p /tmp/experiment && tar -xf - -C /tmp/experiment'

record_event() {
    local lock_dir="${EVENTS_FILE}.lock.d"
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 0.01
    done
    printf '%s,%s,%s\n' "$(epoch_now)" "$1" "$2" >> "$EVENTS_FILE"
    rmdir "$lock_dir"
}

wait_for_project() {
    local attempt
    for ((attempt=1; attempt<=180; attempt++)); do
        if curl -fsS "http://127.0.0.1/${PROJECT:-boincserver}/get_project_config.php" \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "BOINC project did not become ready" >&2
    return 1
}

boinc_exec() {
    compose exec -T apache su -s /bin/bash "${BOINC_USER:-boincadm}" -c \
        "cd \"${PROJECT_ROOT:-/home/boincadm/project}\" && $*"
}

DB_CFG_LOADED=0
DB_HOST=
DB_USER=
DB_PASSWD=
DB_NAME=

load_db_config() {
    if (( DB_CFG_LOADED )); then
        return 0
    fi

    local config_xml
    config_xml=$(
        compose exec -T apache cat "${PROJECT_ROOT:-/home/boincadm/project}/config.xml" 2>/dev/null \
            | tr -d '\r'
    )
    if [[ -z "$config_xml" ]]; then
        echo "Could not read ${PROJECT_ROOT}/config.xml from apache container" >&2
        return 1
    fi

    local parsed
    parsed=$(
        printf '%s' "$config_xml" | python3 -c "
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.stdin).getroot()
cfg = root.find('config')
if cfg is None:
    cfg = root

def cfg_text(tag, default=''):
    value = cfg.findtext(tag)
    return default if value is None else value

print(
    '\t'.join(
        (
            cfg_text('db_host', 'mysql'),
            cfg_text('db_user', 'root'),
            cfg_text('db_passwd', ''),
            cfg_text('db_name', 'boincserver'),
        )
    ),
    end='',
)
"
    )
    IFS=$'\t' read -r DB_HOST DB_USER DB_PASSWD DB_NAME <<< "$parsed"
    DB_NAME=${DB_NAME:-${PROJECT:-boincserver}}
    if [[ -z "$DB_PASSWD" || "$DB_PASSWD" == \$\{db_passwd\} || "$DB_PASSWD" == \$\{DB_PASSWD\} ]]; then
        if [[ -f "$ROOT_DIR/images/makeproject/secrets.env" ]]; then
            source "$ROOT_DIR/images/makeproject/secrets.env"
            DB_PASSWD=${DB_PASSWD:-password}
        else
            DB_PASSWD=password
        fi
    fi
    DB_CFG_LOADED=1
}

mysql_query() {
    local sql=$1
    load_db_config || return 1
    compose exec -T -e MYSQL_PWD="$DB_PASSWD" apache \
        mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -e "$sql"
}

mysql_query_batch() {
    local sql=$1
    load_db_config || return 1
    compose exec -T -e MYSQL_PWD="$DB_PASSWD" apache \
        mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -B -e "$sql"
}

show_db_password_hint() {
    load_db_config || true
    echo "config.xml db_host=${DB_HOST:-?} db_name=${DB_NAME:-?} db_passwd=${DB_PASSWD:-<empty>}" >&2
    if [[ -z "${DB_PASSWD:-}" || "$DB_PASSWD" == \$\{db_passwd\} || "$DB_PASSWD" == \$\{DB_PASSWD\} ]]; then
        echo "Password placeholder was not substituted. Recreate volumes:" >&2
        echo "  docker compose down -v && SKIP_BUILD=1 ./experiments/run_experiment.sh baseline" >&2
    fi
}

wait_for_feeder() {
    local attempt
    for ((attempt=1; attempt<=60; attempt++)); do
        if boinc_exec \
            'h=$(hostname -s); test -f "pid_${h}/feeder.pid" && kill -0 "$(cat "pid_${h}/feeder.pid")" 2>/dev/null'; then
            sleep 3
            echo "BOINC feeder is running." >&2
            return 0
        fi
        sleep 2
    done
    echo "BOINC feeder did not start. Daemon status:" >&2
    boinc_exec 'bin/status -v' >&2 || true
    return 1
}

wait_for_start_idle() {
    local attempt
    for ((attempt=1; attempt<=90; attempt++)); do
        if boinc_exec 'h=$(hostname -s); test ! -e "pid_${h}/start.lock.${h}"'; then
            return 0
        fi
        sleep 1
    done
    echo "Timed out waiting for bin/start to finish" >&2
    return 1
}

restart_boinc_daemons() {
    echo "Restarting BOINC daemons..." >&2
    boinc_exec 'bin/stop' >/dev/null 2>&1 || true
    sleep 2
    wait_for_start_idle || true

    local attempt output
    for ((attempt=1; attempt<=30; attempt++)); do
        if output=$(boinc_exec 'bin/start -v --enable' 2>&1); then
            [[ -n "$output" ]] && printf '%s\n' "$output" >&2
            wait_for_feeder
            return 0
        fi
        if [[ "$output" == *"start is currently running"* ]]; then
            sleep 2
            continue
        fi
        printf '%s\n' "$output" >&2
        return 1
    done
    echo "Could not start BOINC daemons: bin/start lock still held" >&2
    boinc_exec 'bin/status -v' >&2 || true
    return 1
}

ensure_app_downloadable() {
    local platform app_file
    case "$(compose exec -T apache uname -m 2>/dev/null | tr -d '\r')" in
        x86_64) platform=x86_64-pc-linux-gnu ;;
        aarch64|arm64) platform=aarch64-unknown-linux-gnu ;;
        *) platform=aarch64-unknown-linux-gnu ;;
    esac
    app_file="hybrid_synthetic_1.0_${platform}"

    boinc_exec 'bin/update_versions --noconfirm' >/dev/null
    boinc_exec "test -f apps/hybrid_synthetic/1.0/${platform}/${app_file}" \
        || { echo "App source missing: ${app_file}" >&2; return 1; }
    boinc_exec "test -f download/${app_file} || cp apps/hybrid_synthetic/1.0/${platform}/${app_file} download/${app_file}"
    boinc_exec "chmod a+r download/${app_file}"

    if ! boinc_exec "test -f download/${app_file}"; then
        echo "App binary missing from download/: ${app_file}" >&2
        boinc_exec 'ls -la download/ | head -20' >&2 || true
        return 1
    fi
    if ! curl -fsS -o /dev/null "http://127.0.0.1/${PROJECT}/download/${app_file}"; then
        echo "App binary not reachable at http://127.0.0.1/${PROJECT}/download/${app_file}" >&2
        return 1
    fi
    echo "App download OK: ${app_file}" >&2
}

count_experiment_results() {
    local mode=$1
    local sql=
    case "$mode" in
        validated)
            sql="SELECT COUNT(DISTINCT w.id) FROM result r JOIN workunit w ON w.id=r.workunitid WHERE w.name LIKE 'exp_${RUN_ID}_%' AND r.received_time>0 AND r.outcome=1 AND r.exit_status=0;"
            ;;
        received)
            sql="SELECT COUNT(DISTINCT w.id) FROM result r JOIN workunit w ON w.id=r.workunitid WHERE w.name LIKE 'exp_${RUN_ID}_%' AND r.received_time>0;"
            ;;
        *)
            return 1
            ;;
    esac
    mysql_query "$sql" | tr -d '\r'
}

set_up_account() {
    local email=$1
    local password=experiment
    local password_hash
    password_hash=$(python3 - "$password" "$email" <<'PY'
import hashlib
import sys
print(hashlib.md5((sys.argv[1] + sys.argv[2]).encode()).hexdigest())
PY
)
    curl -fsS --get \
        --data-urlencode "user_name=Experiment ${PAIR_ID}" \
        --data-urlencode "email_addr=$email" \
        --data-urlencode "passwd_hash=$password_hash" \
        "http://127.0.0.1/${PROJECT:-boincserver}/create_account.php" \
        | python3 -c \
            'import sys, xml.etree.ElementTree as ET; print(ET.parse(sys.stdin).getroot().findtext("authenticator") or "")'
}

sample_container_stats() {
    while [[ -f "$RUN_DIR/.sampling" ]]; do
        printf '{"sample_time":%s,"containers":[' "$(epoch_now)" \
            >> "$RUN_DIR/raw/container_stats.jsonl"
        local stats_pid waited=0
        (
            docker stats --no-stream --format '{{json .}}' 2>/dev/null \
                | paste -sd, -
        ) >> "$RUN_DIR/raw/container_stats.jsonl" &
        stats_pid=$!
        while kill -0 "$stats_pid" 2>/dev/null && (( waited < 15 )); do
            sleep 1
            waited=$((waited + 1))
        done
        kill "$stats_pid" 2>/dev/null || true
        wait "$stats_pid" 2>/dev/null || true
        printf ']}\n' >> "$RUN_DIR/raw/container_stats.jsonl"
        sleep 5
    done
}

stop_sampler() {
    rm -f "$RUN_DIR/.sampling"
    [[ -n "${SAMPLER_PID:-}" ]] || return 0
    local waited=0
    while kill -0 "$SAMPLER_PID" 2>/dev/null && (( waited < 15 )); do
        sleep 1
        waited=$((waited + 1))
    done
    kill "$SAMPLER_PID" 2>/dev/null || true
    wait "$SAMPLER_PID" 2>/dev/null || true
}

CHURN_CLIENT_SERVICES=(
    client-cluster
    client-cluster-2
    client-desktop
    client-low-power
    client-phone
    client-phone-2
)
CHURN_CLIENT_NODES=(
    cluster-01
    cluster-02
    desktop-01
    low-power-01
    phone-01
    phone-02
)

churn_should_stop() {
    [[ -f "${RUN_DIR}/.churn_stop" ]]
}

churn_sleep() {
    local remaining=$1
    while (( remaining > 0 )); do
        if churn_should_stop; then
            return 1
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
    return 0
}

churn_single_client() {
    local service=$1
    local node=$2
    local cycles=$3
    local initial_delay=$4
    local cycle

    if (( initial_delay > 0 )); then
        churn_sleep "$initial_delay" || return 0
    fi

    for ((cycle=1; cycle<=cycles; cycle++)); do
        churn_should_stop && return 0
        churn_sleep "$CHURN_ONLINE_SECONDS" || return 0
        churn_should_stop && return 0
        compose --profile experiment pause "$service" >/dev/null
        record_event "$node" stop
        churn_sleep "$CHURN_OFFLINE_SECONDS" || {
            compose --profile experiment unpause "$service" >/dev/null 2>&1 || true
            return 0
        }
        compose --profile experiment unpause "$service" >/dev/null
        record_event "$node" restart
    done
}

stop_churn() {
    if [[ "$CHURN_PROFILE" == stable ]]; then
        return 0
    fi

    touch "$RUN_DIR/.churn_stop"

    if [[ -f "$RUN_DIR/churn.pids" ]]; then
        local pid
        while read -r pid; do
            if [[ -n "$pid" ]]; then
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
            fi
        done < "$RUN_DIR/churn.pids"
    fi

    if [[ -n "${CHURN_PID:-}" ]]; then
        kill "$CHURN_PID" 2>/dev/null || true
        wait "$CHURN_PID" 2>/dev/null || true
    fi

    local index
    for index in "${!CHURN_CLIENT_SERVICES[@]}"; do
        compose --profile experiment unpause "${CHURN_CLIENT_SERVICES[$index]}" \
            >/dev/null 2>&1 || true
    done
}

run_churn() {
    local index cycles pids=()

    case "$CHURN_PROFILE" in
        stable)
            return
            ;;
        moderate)
            cycles=1
            ;;
        heavy)
            cycles=$CHURN_CYCLES
            ;;
    esac

    rm -f "$RUN_DIR/.churn_stop"
    : > "$RUN_DIR/churn.pids"

    for index in "${!CHURN_CLIENT_SERVICES[@]}"; do
        local worker_pid
        churn_single_client \
            "${CHURN_CLIENT_SERVICES[$index]}" \
            "${CHURN_CLIENT_NODES[$index]}" \
            "$cycles" \
            $(( index * CHURN_STAGGER_SECONDS )) &
        worker_pid=$!
        pids+=("$worker_pid")
        echo "$worker_pid" >> "$RUN_DIR/churn.pids"
    done

    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

export PROJECT=${PROJECT:-boincserver}
export BOINC_USER=${BOINC_USER:-boincadm}
export PROJECT_ROOT=${PROJECT_ROOT:-/home/boincadm/project}
export URL_BASE=${URL_BASE:-http://boincserver.local}
export PROJECT_URL=${PROJECT_URL:-http://boincserver.local/${PROJECT}/}

if [[ ${SKIP_BUILD:-0} != 1 ]]; then
    compose --profile experiment build \
        mysql makeproject apache client-cluster
fi

for POLICY in "${POLICIES[@]}"; do
    RUN_ID="${PAIR_ID}_${POLICY}"
    RUN_DIR="$ROOT_DIR/results/${RUN_ID}"
    export RUN_ID RUN_DIR
    export RESULT_DIR="$RUN_DIR"
    EVENTS_FILE="$RUN_DIR/events.csv"
    mkdir -p "$RUN_DIR"/{raw,config,analysis,clients}
    printf 'timestamp,node,action\n' > "$EVENTS_FILE"

    echo "=== [$PAIR_ID] policy=$POLICY ===" >&2
    stop_churn
    compose --profile experiment down -v --remove-orphans >/dev/null 2>&1 || true
    STARTED_AT=$(epoch_now)

    echo "[$POLICY] starting mysql/apache..." >&2
    compose up -d mysql makeproject apache
    wait_for_project
    if ! mysql_query "SELECT 1;" >/dev/null; then
        echo "Cannot query MySQL using credentials from config.xml." >&2
        show_db_password_hint
        exit 5
    fi

    echo "[$POLICY] setup_project (may take 1-3 min)..." >&2
    ship_experiment | compose run --rm -T --no-deps \
        -e MAX_WUS_TO_SEND="$MAX_WUS_TO_SEND" \
        -e MAX_WUS_IN_PROGRESS="$MAX_WUS_IN_PROGRESS" \
        makeproject \
        bash -c "$UNPACK_EXPERIMENT && bash /tmp/experiment/server/setup_project.sh"
    wait_for_project
    ensure_app_downloadable
    echo "[$POLICY] applying scheduler policy..." >&2
    ship_experiment | compose exec -T apache \
        bash -c "$UNPACK_EXPERIMENT && bash /tmp/experiment/server/set_policy.sh $POLICY"
    restart_boinc_daemons

    EMAIL="experiment-${RUN_ID}@example.invalid"
    EXPERIMENT_AUTHENTICATOR=$(set_up_account "$EMAIL")
    if [[ -z "$EXPERIMENT_AUTHENTICATOR" ]]; then
        echo "Could not create BOINC experiment account" >&2
        exit 4
    fi
    export EXPERIMENT_AUTHENTICATOR

    ship_experiment | compose exec -T \
        -e RUN_ID="$RUN_ID" \
        -e SHORT_JOBS="$SHORT_JOBS" \
        -e MEDIUM_JOBS="$MEDIUM_JOBS" \
        -e LONG_JOBS="$LONG_JOBS" \
        -e ESTIMATE_PROFILE="$ESTIMATE_PROFILE" \
        apache \
        bash -c "$UNPACK_EXPERIMENT && bash /tmp/experiment/server/create_workload.sh"
    boinc_exec 'touch reread_db' >/dev/null 2>&1 || true

    rm -rf "$RUN_DIR/clients"
    mkdir -p "$RUN_DIR/clients"
    echo "[$POLICY] starting clients..." >&2
    compose --profile experiment up -d --force-recreate \
        client-cluster client-cluster-2 client-desktop client-low-power \
        client-phone client-phone-2
    for node in cluster-01 cluster-02 desktop-01 low-power-01 phone-01 phone-02; do
        record_event "$node" start
    done

    touch "$RUN_DIR/.sampling"
    sample_container_stats &
    SAMPLER_PID=$!

    sleep 10

    run_churn &
    CHURN_PID=$!

    TOTAL_JOBS=$((SHORT_JOBS + MEDIUM_JOBS + LONG_JOBS))
    DEADLINE=$(( $(date +%s) + RUN_TIMEOUT_SECONDS ))
    RECEIVED=0
    VALIDATED=0
    WAIT_STARTED=$(date +%s)
    while (( $(date +%s) < DEADLINE )); do
        RECEIVED=$(count_experiment_results received || echo 0)
        VALIDATED=$(count_experiment_results validated || echo 0)
        RECEIVED=${RECEIVED:-0}
        VALIDATED=${VALIDATED:-0}
        ELAPSED=$(( $(date +%s) - WAIT_STARTED ))
        printf 'run=%s received=%s validated=%s/%s elapsed=%ss\n' \
            "$RUN_ID" "$RECEIVED" "$VALIDATED" "$TOTAL_JOBS" "$ELAPSED"
        (( VALIDATED >= TOTAL_JOBS )) && break
        sleep 5
    done
    COMPLETED=$VALIDATED

    stop_churn
    FINISHED_AT=$(epoch_now)
    stop_sampler

    echo "[$POLICY] exporting results..." >&2
    mysql_query_batch "
            SELECT
                r.id AS result_id,
                r.name AS result_name,
                w.name AS workunit_name,
                CASE
                    WHEN LOCATE('_short_', w.name)>0 THEN 'short'
                    WHEN LOCATE('_medium_', w.name)>0 THEN 'medium'
                    WHEN LOCATE('_long_', w.name)>0 THEN 'long'
                    ELSE 'unknown'
                END AS work_class,
                w.create_time AS wu_create_time,
                w.rsc_fpops_est,
                w.delay_bound,
                r.sent_time,
                r.received_time,
                r.report_deadline,
                r.cpu_time,
                r.elapsed_time,
                r.flops_estimate,
                r.outcome,
                r.exit_status,
                r.hostid AS host_id,
                h.domain_name,
                h.p_ncpus,
                h.p_fpops,
                h.on_frac,
                h.active_frac
            FROM result r
            JOIN workunit w ON w.id=r.workunitid
            LEFT JOIN host h ON h.id=r.hostid
            WHERE w.name LIKE 'exp_${RUN_ID}_%'
            ORDER BY w.id, r.id;" \
        > "$RUN_DIR/raw/tasks.tsv"

    mysql_query_batch "
            SELECT id, domain_name, p_ncpus, p_fpops, m_nbytes,
                   on_frac, connected_frac, active_frac, cpu_efficiency,
                   avg_turnaround, error_rate
            FROM host ORDER BY id;" \
        > "$RUN_DIR/raw/hosts.tsv"

    compose exec -T apache sh -c \
        'cat "$PROJECT_ROOT"/log_* 2>/dev/null || true' \
        > "$RUN_DIR/raw/scheduler.log"
    compose --profile experiment logs --no-color --tail=2000 \
        > "$RUN_DIR/raw/compose.log" 2>&1
    compose logs --no-color apache 2>&1 \
        >> "$RUN_DIR/raw/scheduler.log"
    compose exec -T apache cat \
        "/home/boincadm/project/config.xml" > "$RUN_DIR/config/config.xml"

    for service in mysql makeproject apache client-cluster client-cluster-2 client-desktop client-low-power client-phone client-phone-2; do
        container_id=$(compose --profile experiment ps -aq "$service" | tr -d '\r')
        if [[ -n "$container_id" ]]; then
            docker inspect "$container_id" > "$RUN_DIR/raw/${service}-inspect.json"
        fi
    done

    POLICY="$POLICY" STARTED_AT="$STARTED_AT" FINISHED_AT="$FINISHED_AT" \
    CHURN_PROFILE="$CHURN_PROFILE" TOTAL_JOBS="$TOTAL_JOBS" \
    ESTIMATE_PROFILE="$ESTIMATE_PROFILE" \
    CHURN_ONLINE_SECONDS="$CHURN_ONLINE_SECONDS" \
    CHURN_OFFLINE_SECONDS="$CHURN_OFFLINE_SECONDS" \
    CHURN_CYCLES="$CHURN_CYCLES" \
    CHURN_STAGGER_SECONDS="$CHURN_STAGGER_SECONDS" \
    MAX_WUS_TO_SEND="$MAX_WUS_TO_SEND" \
    MAX_WUS_IN_PROGRESS="$MAX_WUS_IN_PROGRESS" \
    PAIR_ID="$PAIR_ID" python3 - "$RUN_DIR/manifest.json" <<'PY'
import json
import os
import platform
import re
import subprocess
import sys

def command(*args):
    try:
        return subprocess.check_output(
            args, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return None

def docker_compose_version():
    short = command("docker", "compose", "version", "--short")
    if short:
        return short
    full = command("docker", "compose", "version")
    if not full:
        return None
    match = re.search(r"v?\d+\.\d+\.\d+", full)
    return match.group(0) if match else full.splitlines()[0]

manifest = {
    "pair_id": os.environ["PAIR_ID"],
    "policy": os.environ["POLICY"],
    "churn_profile": os.environ["CHURN_PROFILE"],
    "churn_online_seconds": int(os.environ["CHURN_ONLINE_SECONDS"]),
    "churn_offline_seconds": int(os.environ["CHURN_OFFLINE_SECONDS"]),
    "churn_cycles": int(os.environ["CHURN_CYCLES"]),
    "churn_stagger_seconds": int(os.environ["CHURN_STAGGER_SECONDS"]),
    "estimate_profile": os.environ["ESTIMATE_PROFILE"],
    "max_wus_to_send": int(os.environ["MAX_WUS_TO_SEND"]),
    "max_wus_in_progress": int(os.environ["MAX_WUS_IN_PROGRESS"]),
    "started_at_epoch": float(os.environ["STARTED_AT"]),
    "finished_at_epoch": float(os.environ["FINISHED_AT"]),
    "total_jobs": int(os.environ["TOTAL_JOBS"]),
    "git_commit": command("git", "rev-parse", "HEAD"),
    "git_dirty": bool(command("git", "status", "--porcelain")),
    "docker_version": command("docker", "version", "--format", "{{.Server.Version}}"),
    "docker_compose_version": docker_compose_version(),
    "host_platform": platform.platform(),
    "node_profiles": {
        "cluster-01": {"cpu_quota": 4.0, "ncpus": 4, "memory": "4g"},
        "cluster-02": {"cpu_quota": 4.0, "ncpus": 4, "memory": "4g"},
        "desktop-01": {"cpu_quota": 2.0, "ncpus": 2, "memory": "2g"},
        "low-power-01": {"cpu_quota": 1.0, "ncpus": 1, "memory": "1g"},
        "phone-01": {"cpu_quota": 0.5, "ncpus": 1, "memory": "512m"},
        "phone-02": {"cpu_quota": 0.5, "ncpus": 1, "memory": "512m"},
    },
}
with open(sys.argv[1], "w") as target:
    json.dump(manifest, target, indent=2, sort_keys=True)
    target.write("\n")
PY

    python3 experiments/analyze_metrics.py \
        --tasks "$RUN_DIR/raw/tasks.tsv" \
        --events "$EVENTS_FILE" \
        --scheduler-log "$RUN_DIR/raw/scheduler.log" \
        --output-dir "$RUN_DIR/analysis" \
        --started-at "$STARTED_AT" \
        --finished-at "$FINISHED_AT" \
        --policy "$POLICY"

    (
        cd "$RUN_DIR"
        find . -type f ! -name checksums.sha256 -print0 \
            | sort -z \
            | xargs -0 shasum -a 256 > checksums.sha256
    )

    if (( COMPLETED < TOTAL_JOBS )); then
        echo "Run $RUN_ID timed out with $COMPLETED/$TOTAL_JOBS completed" >&2
    else
        echo "Run $RUN_ID completed; results: $RUN_DIR"
    fi

    if [[ "$KEEP_STACK" != 1 ]]; then
        compose --profile experiment down -v --remove-orphans >/dev/null
    fi
done

if [[ "$REQUESTED_POLICY" == both ]]; then
    python3 - \
        "$ROOT_DIR/results/${PAIR_ID}_baseline/analysis/metrics.json" \
        "$ROOT_DIR/results/${PAIR_ID}_hybrid/analysis/metrics.json" \
        "$ROOT_DIR/results/${PAIR_ID}_comparison.json" <<'PY'
import json
import sys

baseline_path, hybrid_path, output_path = sys.argv[1:]
with open(baseline_path) as source:
    baseline = json.load(source)
with open(hybrid_path) as source:
    hybrid = json.load(source)

paths = {
    "throughput_tasks_per_second": ("throughput_tasks_per_second",),
    "response_time_mean_seconds": ("response_time_seconds", "mean"),
    "response_time_p95_seconds": ("response_time_seconds", "p95"),
    "makespan_seconds": ("makespan_seconds",),
    "deadline_miss_rate": ("deadline_miss_rate",),
    "load_utilization_cv": ("load_utilization_cv",),
    "jain_fairness_completed_tasks": ("jain_fairness_completed_tasks",),
    "scheduler_decision_p95_ms": ("scheduler_decision_time_ms", "p95"),
    "scheduler_overhead_percent": ("scheduler_overhead_percent",),
}

def get(document, path):
    value = document
    for part in path:
        value = value.get(part) if isinstance(value, dict) else None
    return value

comparison = {"pair_id": output_path.rsplit("/", 1)[-1].replace("_comparison.json", ""), "metrics": {}}
for name, path in paths.items():
    before = get(baseline, path)
    after = get(hybrid, path)
    absolute = after - before if before is not None and after is not None else None
    relative = absolute / before if absolute is not None and before not in (None, 0) else None
    comparison["metrics"][name] = {
        "baseline": before,
        "hybrid": after,
        "absolute_difference": absolute,
        "relative_difference": relative,
    }

with open(output_path, "w") as target:
    json.dump(comparison, target, indent=2, sort_keys=True)
    target.write("\n")
print("A/B comparison:", output_path)
PY
fi

if [[ "$REQUESTED_POLICY" == all ]]; then
    PAIR_ID="$PAIR_ID" ROOT_DIR="$ROOT_DIR" python3 - <<'PY'
import csv
import json
import os
from pathlib import Path

root = Path(os.environ["ROOT_DIR"]) / "results"
pair_id = os.environ["PAIR_ID"]
rows = []
for policy in ("baseline", "random", "lpt", "sjf", "hybrid"):
    with (root / f"{pair_id}_{policy}" / "analysis" / "metrics.json").open() as source:
        metrics = json.load(source)
    rows.append({
        "policy": policy,
        "throughput_tasks_per_second": metrics["throughput_tasks_per_second"],
        "response_mean_seconds": metrics["response_time_seconds"]["mean"],
        "response_p95_seconds": metrics["response_time_seconds"]["p95"],
        "makespan_seconds": metrics["makespan_seconds"],
        "deadline_miss_rate": metrics["deadline_miss_rate"],
        "load_utilization_cv": metrics["load_utilization_cv"],
        "jain_fairness": metrics["jain_fairness_completed_tasks"],
        "scheduler_p95_ms": metrics["scheduler_decision_time_ms"]["p95"],
    })

output = root / f"{pair_id}_policy_summary.csv"
with output.open("w", newline="") as target:
    writer = csv.DictWriter(target, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)
print("Policy summary:", output)
PY
fi
