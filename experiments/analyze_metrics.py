#!/usr/bin/env python3
"""Compute reproducible BOINC load-balancing metrics using only stdlib."""

import argparse
import csv
import json
import math
import re
from collections import defaultdict
from pathlib import Path


def as_float(row, key):
    try:
        return float(row.get(key, 0) or 0)
    except (TypeError, ValueError):
        return 0.0


def percentile(values, quantile):
    values = sorted(values)
    if not values:
        return None
    position = (len(values) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return values[lower]
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


def distribution(values):
    values = list(values)
    if not values:
        return {"count": 0, "mean": None, "median": None, "p95": None, "p99": None}
    return {
        "count": len(values),
        "mean": sum(values) / len(values),
        "median": percentile(values, 0.5),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
    }


def coefficient_of_variation(values):
    values = list(values)
    if not values:
        return None
    mean = sum(values) / len(values)
    if mean == 0:
        return 0.0
    variance = sum((value - mean) ** 2 for value in values) / len(values)
    return math.sqrt(variance) / mean


def jain_index(values):
    values = list(values)
    square_sum = sum(value * value for value in values)
    if not values or square_sum == 0:
        return None
    return sum(values) ** 2 / (len(values) * square_sum)


def online_seconds(events_path, started_at, finished_at):
    if not events_path.exists():
        return {}
    events = defaultdict(list)
    with events_path.open(newline="") as source:
        for row in csv.DictReader(source):
            events[row["node"]].append((float(row["timestamp"]), row["action"]))

    durations = {}
    for node, node_events in events.items():
        online_since = None
        total = 0.0
        for timestamp, action in sorted(node_events):
            if action in {"start", "restart"} and online_since is None:
                online_since = max(timestamp, started_at)
            elif action == "stop" and online_since is not None:
                total += max(0.0, min(timestamp, finished_at) - online_since)
                online_since = None
        if online_since is not None:
            total += max(0.0, finished_at - online_since)
        durations[node] = total
    return durations


def scheduler_latencies(log_path):
    if not log_path.exists():
        return []
    pattern = re.compile(r"\[scheduler_metrics\].* elapsed_us=(\d+)")
    values = []
    for line in log_path.read_text(errors="replace").splitlines():
        match = pattern.search(line)
        if match:
            values.append(float(match.group(1)) / 1000.0)
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tasks", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--scheduler-log", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--started-at", type=float, required=True)
    parser.add_argument("--finished-at", type=float, required=True)
    parser.add_argument("--policy", required=True)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    with args.tasks.open(newline="") as source:
        tasks = list(csv.DictReader(source, delimiter="\t"))

    completed = [
        row for row in tasks
        if as_float(row, "received_time") > 0
        and int(as_float(row, "outcome")) == 1
        and int(as_float(row, "exit_status")) == 0
    ]
    response = [
        as_float(row, "received_time") - as_float(row, "wu_create_time")
        for row in completed
    ]
    service = [
        as_float(row, "received_time") - as_float(row, "sent_time")
        for row in completed
    ]
    queueing = [
        as_float(row, "sent_time") - as_float(row, "wu_create_time")
        for row in completed
    ]
    observation = max(0.001, args.finished_at - args.started_at)
    node_online = online_seconds(args.events, args.started_at, args.finished_at)

    by_host = defaultdict(list)
    for row in completed:
        by_host[row.get("domain_name") or f"host-{row.get('host_id', 'unknown')}"].append(row)

    node_rows = []
    utilizations = []
    completion_counts = []
    for host, rows in sorted(by_host.items()):
        cpu_time = sum(as_float(row, "cpu_time") for row in rows)
        elapsed_time = sum(as_float(row, "elapsed_time") for row in rows)
        ncpus = max(1.0, as_float(rows[0], "p_ncpus"))
        online = node_online.get(host, observation)
        utilization = cpu_time / max(0.001, online * ncpus)
        utilizations.append(utilization)
        completion_counts.append(len(rows))
        class_counts = {
            name: sum(row.get("work_class") == name for row in rows)
            for name in ("short", "medium", "long")
        }
        node_rows.append({
            "host": host,
            "host_id": rows[0].get("host_id"),
            "p_ncpus": ncpus,
            "p_fpops": as_float(rows[0], "p_fpops"),
            "completed": len(rows),
            "short_completed": class_counts["short"],
            "medium_completed": class_counts["medium"],
            "long_completed": class_counts["long"],
            "cpu_time_seconds": cpu_time,
            "elapsed_time_seconds": elapsed_time,
            "online_seconds": online,
            "cpu_utilization": utilization,
        })

    decision_ms = scheduler_latencies(args.scheduler_log)
    received_times = [as_float(row, "received_time") for row in completed]
    arrival_times = [as_float(row, "wu_create_time") for row in completed]
    deadline_misses = sum(
        as_float(row, "received_time") > as_float(row, "report_deadline")
        for row in completed
    )
    by_class = {}
    for work_class in sorted({row.get("work_class", "unknown") for row in completed}):
        class_rows = [row for row in completed if row.get("work_class", "unknown") == work_class]
        by_class[work_class] = {
            "completed": len(class_rows),
            "response_time_seconds": distribution(
                as_float(row, "received_time") - as_float(row, "wu_create_time")
                for row in class_rows
            ),
            "service_time_seconds": distribution(
                as_float(row, "received_time") - as_float(row, "sent_time")
                for row in class_rows
            ),
        }
    estimate_relative_errors = []
    for row in completed:
        elapsed = as_float(row, "elapsed_time")
        flops = as_float(row, "flops_estimate")
        fpops_est = as_float(row, "rsc_fpops_est")
        if elapsed > 0 and flops > 0 and fpops_est > 0:
            predicted = fpops_est / flops
            estimate_relative_errors.append(abs(predicted - elapsed) / elapsed)

    metrics = {
        "policy": args.policy,
        "observation_seconds": observation,
        "tasks_total": len(tasks),
        "tasks_completed": len(completed),
        "tasks_failed_or_incomplete": len(tasks) - len(completed),
        "throughput_tasks_per_second": len(completed) / observation,
        "response_time_seconds": distribution(response),
        "service_time_seconds": distribution(service),
        "queueing_delay_seconds": distribution(queueing),
        "makespan_seconds": (
            max(received_times) - min(arrival_times)
            if received_times and arrival_times else None
        ),
        "deadline_misses": deadline_misses,
        "deadline_miss_rate": (
            deadline_misses / len(completed) if completed else None
        ),
        "load_utilization_cv": coefficient_of_variation(utilizations),
        "jain_fairness_completed_tasks": jain_index(completion_counts),
        "jain_fairness_by_work_class": {
            work_class: jain_index([
                sum(row.get("work_class") == work_class for row in rows)
                for rows in by_host.values()
            ])
            for work_class in ("short", "medium", "long")
        },
        "runtime_estimate_relative_error": distribution(estimate_relative_errors),
        "cpu_efficiency": (
            sum(as_float(row, "cpu_time") for row in completed)
            / max(0.001, sum(as_float(row, "elapsed_time") for row in completed))
        ),
        "scheduler_decision_time_ms": distribution(decision_ms),
        "scheduler_overhead_percent": (
            sum(decision_ms) / 1000.0 / observation * 100.0
            if decision_ms else 0.0
        ),
        "by_work_class": by_class,
    }

    (args.output_dir / "metrics.json").write_text(
        json.dumps(metrics, indent=2, sort_keys=True) + "\n"
    )
    with (args.output_dir / "per_node.csv").open("w", newline="") as target:
        writer = csv.DictWriter(target, fieldnames=[
            "host", "host_id", "p_ncpus", "p_fpops", "completed",
            "short_completed", "medium_completed", "long_completed",
            "cpu_time_seconds", "elapsed_time_seconds", "online_seconds",
            "cpu_utilization",
        ])
        writer.writeheader()
        writer.writerows(node_rows)
    with (args.output_dir / "summary.csv").open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(["metric", "value"])
        for key, value in metrics.items():
            if not isinstance(value, dict):
                writer.writerow([key, value])


if __name__ == "__main__":
    main()
