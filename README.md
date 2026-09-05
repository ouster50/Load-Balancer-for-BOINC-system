# Load-Balancer-for-BOINC
Coursework at Higher School of Economics on "Load balancing in hybrid distributed systems"

The BOINC server is built from the coursework fork in `boinc/`. The
experimental scheduler, heterogeneous Docker testbed, workload generator,
metrics collector and A/B runner are documented in
[`docs/HYBRID_LOAD_BALANCER.md`](docs/HYBRID_LOAD_BALANCER.md).

Quick smoke experiment:

```bash
SHORT_JOBS=4 MEDIUM_JOBS=2 LONG_JOBS=1 \
RUN_TIMEOUT_SECONDS=600 \
bash experiments/run_experiment.sh both
```