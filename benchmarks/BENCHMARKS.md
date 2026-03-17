# IsoBench Isolation Benchmark Suite

This work is part of a research project of the [Institute for Control Engineering of Machine Tools and Manufacturing Units (ISW) of the University of Stuttgart](https://www.isw.uni-stuttgart.de/).

Automated benchmark suite that measures the impact of Linux isolation mechanisms
on real-time application performance using the existing cyclic and ping-pong benchmarks.

These are **whitebox tests**: isolation mechanisms are applied individually and in controlled combinations, allowing precise attribution of latency overhead to specific kernel subsystems rather than treating the container runtime as a black box.

## What it tests

| #   | Scenario              | What it isolates                                    | Why it matters for RT                               |
| --- | --------------------- | --------------------------------------------------- | --------------------------------------------------- |
| 01  | **baseline**          | Network namespaces only                             | Reference measurement                               |
| 02  | **cgroup_cpuset**     | CPU pinning via cgroup                              | cpuset accounting on scheduler path                 |
| 03  | **cgroup_mem**        | Memory limits (512 MB)                              | Memory accounting on every alloc/page fault         |
| 04  | **cgroup_cpuset_mem** | cpuset + memory combined                            | Cumulative overhead of multiple controllers         |
| 05  | **cgroup_cpu_quota**  | CFS bandwidth (95%)                                 | Period-boundary throttling can cause latency spikes |
| 06  | **seccomp_trivial**   | 2-instruction BPF filter                            | Baseline seccomp overhead (BPF interpreter entry)   |
| 07  | **seccomp_heavy**     | 204-instruction BPF filter                          | Simulates Docker's default seccomp profile          |
| 08  | **apparmor**          | AppArmor enforce mode                               | LSM hook overhead on every security-relevant op     |
| 09  | **netns_extra_hop**   | Additional bridge + netns                           | Extra network stack traversal                       |
| 10  | **all_light**         | cpuset + seccomp_trivial + AppArmor                 | Lightweight container-like isolation                |
| 11  | **all_heavy**         | cpuset + mem + cpu_quota + heavy seccomp + AppArmor | Full container-like stack                           |
| 12  | **pid_namespace**     | PID namespace                                       | Tsk struct overhead of PID translation              |
| 13  | **mount_namespace**   | Mount namespace (private)                           | VFS path resolution overhead                        |
| 14  | **user_namespace**    | User namespace (root→root)                          | UID/GID credential check overhead                   |
| 15  | **cgroup_io_latency** | cgroup io.latency controller                        | Block-I/O accounting overhead on cgroup switches    |
| 16  | **net_cls_cgroup**    | net_cls cgroup packet tagging                       | Per-packet cgroup classid lookup overhead           |
| 17  | **numa_membind**      | NUMA memory binding (remote node)                   | Cross-NUMA memory access latency penalty            |
| 18  | **cpu_stress**        | RT under heavy CPU contention                       | Shared resource contention (LLC, memory bandwidth)  |
| 19  | **uts_ipc_namespace** | UTS + IPC namespace                                 | nsproxy indirection overhead on relevant syscalls   |
| 20  | **full_docker_like**  | All namespaces + cgroups + seccomp                  | Cumulative overhead of full container stack         |

### What is NOT tested (by design)

- **Restricting RT priorities** — trivially breaks RT; not interesting to benchmark.
- **CPU affinity restrictions** — removing pinning obviously destroys RT; not tested.
- **SELinux** — orthogonal to AppArmor; add a profile if your system uses SELinux.

## Quick start

```bash
# 1. Build everything
cargo build --release -p testapps -p auswertung

# 2. Run all scenarios (takes ~30 min with defaults)
bash benchmarks/run_isolation_suite.sh

# 3. Run specific scenarios only
sudo bash benchmarks/run_isolation_suite.sh 01_baseline 07_seccomp_heavy

# 4. Analyze results
python3 benchmarks/analyze_results.py benchmarks/results/

# 5. Open report
xdg-open benchmarks/results/report.html
```

## Tuning parameters

Set environment variables before running:

```bash
# Reduce sample count for quick tests
export ISOBENCH_SAMPLES=10000
export ISOBENCH_ITERATIONS=15000

# Use different CPUs (default: sender=0, receiver=1)
export ISOBENCH_SENDER_CPU=2
export ISOBENCH_RECEIVER_CPU=3

# Different cycle time (default 1ms)
export ISOBENCH_CYCLE_US=500

# Less settling time between scenarios
export ISOBENCH_SETTLE=1

sudo -E bash benchmarks/run_isolation_suite.sh
```

## File structure

```
benchmarks/
├── run_isolation_suite.sh   # Main benchmark runner
├── analyze_results.py       # Results analysis + HTML report
├── seccomp_wrapper.c        # seccomp-bpf filter applier (compiled automatically)
├── isobench.apparmor        # AppArmor profile (all-allow, enforce mode)
├── BENCHMARKS.md            # This file
└── results/                 # Created by suite
    ├── system_info.txt      # Kernel, CPU, cgroup info
    ├── summary.csv          # Aggregate statistics
    ├── report.html          # Interactive Plotly report
    ├── 01_baseline/
    │   ├── 01_baseline_cyclic_data.csv
    │   ├── 01_baseline_ping_data.csv
    │   ├── 01_baseline_cyclic_timestamps.html
    │   └── ...
    ├── 02_cgroup_cpuset/
    └── ...
```

## How it works

1. **Network setup**: Uses the existing `bridge_network.sh` to create ns1/ns2 with a bridge.
2. **Per-scenario isolation**: Each scenario applies its isolation mechanism (cgroup, seccomp, AppArmor, extra namespaces, or combinations) before launching the RT apps.
3. **Both benchmarks run**: Cyclic (scheduling jitter) and ping-pong (network RTT) run under each scenario.
4. **CSV + HTML output**: Auswertung apps produce both CSV (for analysis) and HTML plots (per-scenario).
5. **Cross-scenario analysis**: `analyze_results.py` reads all CSVs and generates comparison box-plots and a summary table.

## Interpreting results

- **Wakeup latency (cyclic)** — measures scheduling jitter. Overhead here means the isolation mechanism interferes with the scheduler or `clock_nanosleep`.
- **Message latency (cyclic)** — measures network send→recv time. Overhead here means the mechanism adds network stack overhead.
- **RTT (ping-pong)** — full round-trip through both namespaces. Most comprehensive network overhead metric.

Values highlighted in **red** in the HTML report are >2× worse than baseline.

Key things to look for:

- **p99 vs baseline**: Consistent overhead added by the mechanism
- **max vs baseline**: Worst-case tail latency spikes
- **cpu_quota**: Often the biggest offender — CFS bandwidth throttling is known to cause periodic latency spikes
- **seccomp_heavy vs trivial**: Shows the BPF program length impact (scales with syscall rate)
- **all_heavy**: Shows whether overheads are additive or masked by the worst component

## Prerequisites

- Linux kernel ≥ 5.8 with cgroup v2 unified hierarchy
- Root access
- `gcc` (for seccomp_wrapper)
- `apparmor_parser` and `aa-exec` (for AppArmor tests; gracefully skipped if missing)
- Python 3.8+ (for analysis script; no pip dependencies needed)
