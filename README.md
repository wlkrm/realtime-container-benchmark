# IsoBench

Cite this project: [![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.19072487.svg)](https://doi.org/10.5281/zenodo.19072487)

This work is part of a research project of the [Institute for Control Engineering of Machine Tools and Manufacturing Units (ISW) of the University of Stuttgart](https://www.isw.uni-stuttgart.de/).

**Isolation Benchmark Suite** for measuring the impact of Linux isolation mechanisms, that are used in container runtimes, on real-time application performance.

This project benchmarks how various container-like isolation techniques (cgroups, namespaces, seccomp-bpf, AppArmor) affect scheduling jitter and network latency. It runs cyclic timing tests and ping-pong latency measurements under different isolation scenarios to quantify overhead.

These are **whitebox tests**: isolation mechanisms are applied individually and in controlled combinations, allowing precise attribution of latency overhead to specific kernel subsystems rather than treating the container runtime as a black box.

See [ARCHITECTURE.md](ARCHITECURE.md) for detailed description of the benchmarks and message formats.

# Run All Benchmarks (Isolation Suite)

Build the project and run the full benchmark suite:

```bash
# Build everything
cargo build --release -p testapps -p auswertung

# Run all benchmark scenarios (takes ~30 min)
bash benchmarks/run_isolation_suite.sh

# Or run specific scenarios only
bash benchmarks/run_isolation_suite.sh 01_baseline 07_seccomp_heavy

# Or run specific benchmarks (cyclic, ping, uds)
bash benchmarks/run_isolation_suite.sh --bench cyclic,ping
```

## Tuning Parameters

Set environment variables before running to adjust benchmark settings:

```bash
# Reduce iterations for quick tests (default: 60000, ~60s at 1ms cycle)
export ISOBENCH_ITERATIONS=10000

# Change cycle time in microseconds (default: 1000 = 1ms)
export ISOBENCH_CYCLE_US=500

# Use different CPUs (default: sender=0, receiver=1)
export ISOBENCH_SENDER_CPU=2
export ISOBENCH_RECEIVER_CPU=3

# Run with custom settings
bash benchmarks/run_isolation_suite.sh
```

Results are saved to `benchmarks/results/`. To analyze and generate the HTML report:

```bash
python3 benchmarks/analyze_results.py benchmarks/results/
```

## View Results

Start a local web server and open the results in your browser:

```bash
python3 -m http.server
```

Then open http://your-dev-machines.ip:8000/benchmarks/results/report.html in your browser.

---

# Individual Tests

(All commands equivalent for bridge network like docker setup. Just use the scripts with \_bridge\_)

## Run Ping-Pong Test

In one terminal

```bash
bash run_pong.sh
```

In a second terminal

```bash
bash run_pong_auswertung.sh
```

This produces two plots:

- lo_ping_inter_packet.html
- lo_ping_latency.html

## Run Cyclic Test

In one terminal

```bash
bash run_cyclic.sh
```

In a second terminal

```bash
bash run_cyclic_auswertung.sh
```

This produces two plots:

- lo_cyclic_inter_packet_latency.html
- lo_cyclic_timestamps.html

## Access the plots

```bash
python3 -m http.server
```

Open http://localhost:8000 in your browser to view the HTML plots.

---

# Contributing

Contributions from fellow researchers are welcome! Whether you want to add new isolation scenarios, improve measurement methodology, or extend the analysis tools, we'd love to hear from you.

- **New scenarios**: Add isolation techniques to `benchmarks/run_isolation_suite.sh`
- **Bug reports & ideas**: Open an issue describing your findings or suggestions
- **Pull requests**: Fork the repo, make your changes, and submit a PR

If you use IsoBench in your research, please consider citing this work or reaching out to discuss collaboration opportunities.
