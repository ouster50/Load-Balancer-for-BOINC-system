#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

REQUESTED_POLICY=${1:-both}
CHURN_PROFILE=${CHURN_PROFILE:-moderate}
CHURN_ONLINE_SECONDS=${CHURN_ONLINE_SECONDS:-20}
CHURN_OFFLINE_SECONDS=${CHURN_OFFLINE_SECONDS:-15}
CHURN_CYCLES=${CHURN_CYCLES:-3}
ESTIMATE_PROFILE=${ESTIMATE_PROFILE:-accurate}
MAX_WUS_TO_SEND=${MAX_WUS_TO_SEND:-1}
MAX_WUS_IN_PROGRESS=${MAX_WUS_IN_PROGRESS:-2}
RUN_TIMEOUT_SECONDS=${RUN_TIMEOUT_SECONDS:-1800}
SHORT_JOBS=${SHORT_JOBS:-12}
MEDIUM_JOBS=${MEDIUM_JOBS:-8}
LONG_JOBS=${LONG_JOBS:-4}
DB_PASSWD=${DB_PASSWD:-password}
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

# The server-side scripts are streamed into the containers as a tar archive on
# stdin instead of being bind-mounted: VM-backed Docker daemons do not always
# share the host directory, which leaves the mount point empty.
ship_experiment() {
    # macOS tar embeds xattr metadata that Linux tar warns about; harmless but noisy.
    COPYFILE_DISABLE=1 tar -cf - -C "$ROOT_DIR/experiments" .
}
UNPACK_EXPERIMENT='rm -rf /tmp/experiment && mkdir -p /tmp/experiment && tar -xf - -C /tmp/experiment'

record_event() {
    printf '%s,%s,%s\n' "$(epoch_now)" "$1" "$2" >> "$EVENTS_FILE"
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
        docker stats --no-stream --format '{{json .}}' 2>/dev/null \
            | paste -sd, - >> "$RUN_DIR/raw/container_stats.jsonl" || true
        printf ']}\n' >> "$RUN_DIR/raw/container_stats.jsonl"
        sleep 5
    done
}

run_churn() {
    case "$CHURN_PROFILE" in
        stable)
            return
            ;;
        moderate)
            sleep "$CHURN_ONLINE_SECONDS"
            compose --profile experiment stop client-phone >/dev/null
            record_event phone-01 stop
            sleep "$CHURN_OFFLINE_SECONDS"
            compose --profile experiment start client-phone >/dev/null
            record_event phone-01 restart
            ;;
        heavy)
            local cycle
            for ((cycle=1; cycle<=CHURN_CYCLES; cycle++)); do
                sleep "$CHURN_ONLINE_SECONDS"
                compose --profile experiment stop client-phone client-low-power >/dev/null
                record_event phone-01 stop
                record_event low-power-01 stop
                sleep "$CHURN_OFFLINE_SECONDS"
                compose --profile experiment start client-phone client-low-power >/dev/null
                record_event phone-01 restart
                record_event low-power-01 restart
            done
            ;;
    esac
}

export PROJECT=${PROJECT:-boincserver}
# Clients run inside the compose network and must follow scheduler/download URLs
# baked into config.xml during project creation. 127.0.0.1 only works for BOINC
# clients on the host machine, not for containers talking to the apache service.
export URL_BASE=${URL_BASE:-http://apache}
export PROJECT_URL=${PROJECT_URL:-http://apache/${PROJECT}/}

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

    compose --profile experiment down -v --remove-orphans >/dev/null 2>&1 || true
    STARTED_AT=$(epoch_now)

    compose up -d mysql makeproject apache
    wait_for_project

    ship_experiment | compose run --rm -T --no-deps \
        -e MAX_WUS_TO_SEND="$MAX_WUS_TO_SEND" \
        -e MAX_WUS_IN_PROGRESS="$MAX_WUS_IN_PROGRESS" \
        makeproject \
        bash -c "$UNPACK_EXPERIMENT && bash /tmp/experiment/server/setup_project.sh"
    compose restart apache >/dev/null
    wait_for_project
    ship_experiment | compose exec -T apache \
        bash -c "$UNPACK_EXPERIMENT && bash /tmp/experiment/server/set_policy.sh $POLICY"

    EMAIL="experiment-${RUN_ID}@example.invalid"
    EXPERIMENT_AUTHENTICATOR=$(set_up_account "$EMAIL")
    if [[ -z "$EXPERIMENT_AUTHENTICATOR" ]]; then
        echo "Could not create BOINC experiment account" >&2
        exit 4
    fi
    export EXPERIMENT_AUTHENTICATOR

    compose --profile experiment up -d --force-recreate \
        client-cluster client-desktop client-low-power client-phone
    for node in cluster-01 desktop-01 low-power-01 phone-01; do
        record_event "$node" start
    done

    touch "$RUN_DIR/.sampling"
    sample_container_stats &
    SAMPLER_PID=$!

    # All clients are online before publishing work, avoiding first-client
    # hoarding. Server-side per-RPC and in-progress limits provide a hard cap.
    sleep 10
    ship_experiment | compose exec -T \
        -e RUN_ID="$RUN_ID" \
        -e SHORT_JOBS="$SHORT_JOBS" \
        -e MEDIUM_JOBS="$MEDIUM_JOBS" \
        -e LONG_JOBS="$LONG_JOBS" \
        -e ESTIMATE_PROFILE="$ESTIMATE_PROFILE" \
        apache \
        bash -c "$UNPACK_EXPERIMENT && bash /tmp/experiment/server/create_workload.sh"

    run_churn &
    CHURN_PID=$!

    TOTAL_JOBS=$((SHORT_JOBS + MEDIUM_JOBS + LONG_JOBS))
    DEADLINE=$(( $(date +%s) + RUN_TIMEOUT_SECONDS ))
    COMPLETED=0
    WAIT_STARTED=$(date +%s)
    while (( $(date +%s) < DEADLINE )); do
        COMPLETED=0
        if completed_raw=$(compose exec -T mysql \
            mysql -N -uroot -p"$DB_PASSWD" "$PROJECT" -e "
                SELECT COUNT(*)
                FROM result r
                JOIN workunit w ON w.id=r.workunitid
                WHERE w.name LIKE 'exp_${RUN_ID}_%'
                  AND r.received_time>0
                  AND r.outcome=1
                  AND r.exit_status=0;" 2>/dev/null | tr -d '\r'); then
            COMPLETED=${completed_raw:-0}
        fi
        ELAPSED=$(( $(date +%s) - WAIT_STARTED ))
        printf 'run=%s completed=%s/%s elapsed=%ss\n' \
            "$RUN_ID" "$COMPLETED" "$TOTAL_JOBS" "$ELAPSED"
        (( COMPLETED >= TOTAL_JOBS )) && break
        sleep 5
    done

    wait "$CHURN_PID" || true
    FINISHED_AT=$(epoch_now)
    rm -f "$RUN_DIR/.sampling"
    wait "$SAMPLER_PID" || true

    compose exec -T mysql \
        mysql -B -uroot -p"$DB_PASSWD" "$PROJECT" -e "
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

    compose exec -T mysql \
        mysql -B -uroot -p"$DB_PASSWD" "$PROJECT" -e "
            SELECT id, domain_name, p_ncpus, p_fpops, m_nbytes,
                   on_frac, connected_frac, active_frac, cpu_efficiency,
                   avg_turnaround, error_rate
            FROM host ORDER BY id;" \
        > "$RUN_DIR/raw/hosts.tsv"

    compose exec -T apache sh -c \
        'cat "$PROJECT_ROOT"/log_* 2>/dev/null || true' \
        > "$RUN_DIR/raw/scheduler.log"
    compose --profile experiment logs --no-color \
        > "$RUN_DIR/raw/compose.log" 2>&1
    compose logs --no-color apache 2>&1 \
        >> "$RUN_DIR/raw/scheduler.log"
    compose exec -T apache cat \
        "/home/boincadm/project/config.xml" > "$RUN_DIR/config/config.xml"

    for service in mysql makeproject apache client-cluster client-desktop client-low-power client-phone; do
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
    MAX_WUS_TO_SEND="$MAX_WUS_TO_SEND" \
    MAX_WUS_IN_PROGRESS="$MAX_WUS_IN_PROGRESS" \
    PAIR_ID="$PAIR_ID" python3 - "$RUN_DIR/manifest.json" <<'PY'
import json
import os
import platform
import subprocess
import sys

def command(*args):
    try:
        return subprocess.check_output(args, text=True).strip()
    except Exception:
        return None

manifest = {
    "pair_id": os.environ["PAIR_ID"],
    "policy": os.environ["POLICY"],
    "churn_profile": os.environ["CHURN_PROFILE"],
    "churn_online_seconds": int(os.environ["CHURN_ONLINE_SECONDS"]),
    "churn_offline_seconds": int(os.environ["CHURN_OFFLINE_SECONDS"]),
    "churn_cycles": int(os.environ["CHURN_CYCLES"]),
    "estimate_profile": os.environ["ESTIMATE_PROFILE"],
    "max_wus_to_send": int(os.environ["MAX_WUS_TO_SEND"]),
    "max_wus_in_progress": int(os.environ["MAX_WUS_IN_PROGRESS"]),
    "started_at_epoch": float(os.environ["STARTED_AT"]),
    "finished_at_epoch": float(os.environ["FINISHED_AT"]),
    "total_jobs": int(os.environ["TOTAL_JOBS"]),
    "git_commit": command("git", "rev-parse", "HEAD"),
    "git_dirty": bool(command("git", "status", "--porcelain")),
    "docker_version": command("docker", "version", "--format", "{{.Server.Version}}"),
    "docker_compose_version": command("docker", "compose", "version", "--short"),
    "host_platform": platform.platform(),
    "node_profiles": {
        "cluster-01": {"cpu_quota": 4.0, "ncpus": 4, "memory": "4g"},
        "desktop-01": {"cpu_quota": 2.0, "ncpus": 2, "memory": "2g"},
        "low-power-01": {"cpu_quota": 1.0, "ncpus": 1, "memory": "1g"},
        "phone-01": {"cpu_quota": 0.5, "ncpus": 1, "memory": "512m"},
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
