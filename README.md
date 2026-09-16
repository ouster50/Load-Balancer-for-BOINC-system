# Load-Balancer-for-BOINC
Coursework at Higher School of Economics on "Load balancing in hybrid distributed systems"

The BOINC server is built from forked repository in `boinc/`. Scheduler, test environment, workload generator, metrics scripts and A/B runner are documented in [`docs/HYBRID_LOAD_BALANCER.md`](docs/HYBRID_LOAD_BALANCER.md).

Quick experiment run:

```bash
SHORT_JOBS=4 MEDIUM_JOBS=2 LONG_JOBS=1 \
RUN_TIMEOUT_SECONDS=600 \
bash experiments/run_experiment.sh both
```

With `both` argument script runs and compares `baseline` and `custom` policies
Also there's `random`, `lpt` (Longest Processing Time first) and `sjf` (Shortest Job First) policies for example
