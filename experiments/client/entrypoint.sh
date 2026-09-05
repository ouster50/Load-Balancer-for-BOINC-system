#!/bin/sh
set -eu

DATA_DIR=/var/lib/boinc-client
PROJECT_URL=${PROJECT_URL:-http://apache/boincserver/}
PROFILE_NAME=${PROFILE_NAME:-generic}
NCPUS=${NCPUS:-1}
MAX_NCPUS_PCT=${MAX_NCPUS_PCT:-100}
WORK_BUF_MIN_DAYS=${WORK_BUF_MIN_DAYS:-0.0007}
WORK_BUF_ADDITIONAL_DAYS=${WORK_BUF_ADDITIONAL_DAYS:-0.0007}

if [ -z "${AUTHENTICATOR:-}" ]; then
    echo "AUTHENTICATOR is required" >&2
    exit 2
fi

mkdir -p "$DATA_DIR"
cat > "$DATA_DIR/global_prefs_override.xml" <<EOF
<global_preferences>
    <run_on_batteries>1</run_on_batteries>
    <run_if_user_active>1</run_if_user_active>
    <max_ncpus_pct>${MAX_NCPUS_PCT}</max_ncpus_pct>
    <cpu_usage_limit>100</cpu_usage_limit>
    <work_buf_min_days>${WORK_BUF_MIN_DAYS}</work_buf_min_days>
    <work_buf_additional_days>${WORK_BUF_ADDITIONAL_DAYS}</work_buf_additional_days>
    <disk_max_used_gb>2</disk_max_used_gb>
    <ram_max_used_busy_pct>90</ram_max_used_busy_pct>
    <ram_max_used_idle_pct>90</ram_max_used_idle_pct>
</global_preferences>
EOF

cat > "$DATA_DIR/cc_config.xml" <<EOF
<cc_config>
    <log_flags>
        <task>1</task>
        <sched_ops>1</sched_ops>
    </log_flags>
    <options>
        <ncpus>${NCPUS}</ncpus>
        <report_results_immediately>1</report_results_immediately>
    </options>
</cc_config>
EOF

echo "$PROFILE_NAME" > "$DATA_DIR/experiment_profile"

attempt=0
until curl -fsS "${PROJECT_URL}get_project_config.php" >/dev/null 2>&1; do
    attempt=$((attempt+1))
    if [ "$attempt" -ge 120 ]; then
        echo "BOINC project did not become ready: $PROJECT_URL" >&2
        exit 3
    fi
    sleep 2
done

cd "$DATA_DIR"
boinc --dir "$DATA_DIR" --allow_remote_gui_rpc &
boinc_pid=$!

cleanup() {
    kill -INT "$boinc_pid" 2>/dev/null || true
    wait "$boinc_pid" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

attempt=0
until boinccmd --host localhost --get_state >/dev/null 2>&1; do
    attempt=$((attempt+1))
    if [ "$attempt" -ge 60 ]; then
        echo "BOINC client RPC did not become ready" >&2
        exit 4
    fi
    sleep 1
done

if ! boinccmd --host localhost --get_project_status 2>/dev/null \
    | tr -d '\r' | grep -Fq "$PROJECT_URL"; then
    boinccmd --host localhost --project_attach "$PROJECT_URL" "$AUTHENTICATOR"
fi

boinccmd --host localhost --read_global_prefs_override
boinccmd --host localhost --network_available
wait "$boinc_pid"
