#!/bin/bash
set -euo pipefail

PROJECT_ROOT=${PROJECT_ROOT:-/home/boincadm/project}
PROJECT_DIR=$PROJECT_ROOT
APP_NAME=hybrid_synthetic
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
SHORT_JOBS=${SHORT_JOBS:-12}
MEDIUM_JOBS=${MEDIUM_JOBS:-8}
LONG_JOBS=${LONG_JOBS:-4}
ESTIMATE_PROFILE=${ESTIMATE_PROFILE:-accurate}

cd "$PROJECT_DIR"
bin/stage_file --copy hybrid_synthetic_input.txt

estimate_for() {
    local class_name=$1
    local base=$2
    case "$ESTIMATE_PROFILE" in
        accurate) echo "$base" ;;
        underestimate) echo $((base * 3 / 10)) ;;
        overestimate) echo $((base * 3)) ;;
        mixed)
            case "$class_name" in
                short) echo $((base * 3)) ;;
                medium) echo "$base" ;;
                long) echo $((base * 3 / 10)) ;;
            esac
            ;;
        *) echo "Unknown ESTIMATE_PROFILE: $ESTIMATE_PROFILE" >&2; exit 2 ;;
    esac
}

create_class() {
    local class_name=$1
    local count=$2
    local cpu_seconds=$3
    local fpops_est=$4
    local fpops_bound=$5
    local deadline=$6
    local effective_fpops_est
    effective_fpops_est=$(estimate_for "$class_name" "$fpops_est")

    local i
    for ((i=1; i<=count; i++)); do
        bin/create_work \
            --appname "$APP_NAME" \
            --wu_name "exp_${RUN_ID}_${class_name}_${i}" \
            --wu_template templates/hybrid_synthetic_in \
            --result_template templates/hybrid_synthetic_out \
            --command_line "--cpu_time ${cpu_seconds}" \
            --rsc_fpops_est "$effective_fpops_est" \
            --rsc_fpops_bound "$fpops_bound" \
            --rsc_memory_bound 134217728 \
            --rsc_disk_bound 10485760 \
            --delay_bound "$deadline" \
            --min_quorum 1 \
            --target_nresults 1 \
            --max_error_results 3 \
            --max_total_results 3 \
            --max_success_results 1 \
            hybrid_synthetic_input.txt
    done
}

create_class short "$SHORT_JOBS" 5 5000000000 50000000000 600
create_class medium "$MEDIUM_JOBS" 30 30000000000 300000000000 1200
create_class long "$LONG_JOBS" 120 120000000000 1200000000000 3600

echo "Created workload run=$RUN_ID short=$SHORT_JOBS medium=$MEDIUM_JOBS long=$LONG_JOBS estimates=$ESTIMATE_PROFILE"
