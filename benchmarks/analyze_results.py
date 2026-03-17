#!/usr/bin/env python3
"""
IsoBench Isolation Benchmark Suite — Results Analyzer

Key metrics
-----------
  Cyclic benchmark:
    • Wakeup Latency   = effective_wakeup_ns − planned_wakeup_ns
    • Message Latency   = effective_recv_ns   − effective_send_ns

  Ping / Pong benchmark:
    • Outbound Latency  = pong_recv_ns − ping_send_ns
    • Inbound Latency   = ping_recv_ns − pong_send_ns
    • Round-Trip Time   = ping_recv_ns − ping_send_ns

Outputs:
  1. Summary table (stdout + CSV) with mean / median / p99 / p999 / max
  2. Interactive HTML report (Plotly) with box-plots and bar-charts

Usage:
    python3 benchmarks/analyze_results.py benchmarks/results/
    python3 benchmarks/analyze_results.py benchmarks/results/ --html report.html
"""

import argparse
import csv
import math
import sys
from pathlib import Path

# ── CSV parsing ─────────────────────────────────────────────────────


def _col_index(header: list[str]) -> dict[str, int]:
    """Map column names to indices."""
    return {name: idx for idx, name in enumerate(header)}


# ── Statistics helpers ──────────────────────────────────────────────


def calc_stats(values: list[int]) -> dict:
    """Calculate summary statistics for a list of values (in ns).

    Single sort + one-pass mean/variance for speed on 300 k+ rows.
    """
    if not values:
        return {"n": 0, "mean": 0, "median": 0, "std": 0,
                "min": 0, "max": 0, "p99": 0, "p999": 0}

    s = sorted(values)
    n = len(s)
    p99_idx = min(int(n * 0.99), n - 1)
    p999_idx = min(int(n * 0.999), n - 1)

    total = 0
    sq_total = 0
    for v in s:
        total += v
        sq_total += v * v
    mean = total / n
    variance = sq_total / n - mean * mean
    std = math.sqrt(max(variance, 0))
    mid = n // 2
    median = s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2

    return {
        "n": n,
        "mean": mean,
        "median": median,
        "std": std,
        "min": s[0],
        "max": s[-1],
        "p99": s[p99_idx],
        "p999": s[p999_idx],
    }


# ── Metric computation (fused read + compute) ──────────────────────


def compute_cyclic(path: Path) -> dict | None:
    """Read cyclic CSV and compute stats in one pass (no intermediate row list)."""
    wakeups: list[int] = []
    messages: list[int] = []
    w_app = wakeups.append      # avoid repeated attr lookup
    m_app = messages.append
    with open(path, "r") as f:
        reader = csv.reader(f)
        ci = _col_index(next(reader))
        ip = ci["planned_wakeup_ns"]
        iw = ci["effective_wakeup_ns"]
        is_ = ci["effective_send_ns"]
        ir = ci["effective_recv_ns"]
        for row in reader:
            w_app(int(row[iw]) - int(row[ip]))
            m_app(int(row[ir]) - int(row[is_]))
    if not wakeups:
        return None
    return {
        "wakeup_latency": calc_stats(wakeups),
        "message_latency": calc_stats(messages),
    }


def compute_ping(path: Path) -> dict | None:
    """Read ping/pong (or UDS) CSV and compute stats in one pass."""
    outbounds: list[int] = []
    inbounds: list[int] = []
    rtts: list[int] = []
    o_app = outbounds.append
    i_app = inbounds.append
    r_app = rtts.append
    with open(path, "r") as f:
        reader = csv.reader(f)
        ci = _col_index(next(reader))
        ips = ci["ping_send_ns"]
        ipr = ci["pong_recv_ns"]
        ipo = ci["pong_send_ns"]
        ipi = ci["ping_recv_ns"]
        for row in reader:
            ps = int(row[ips])
            pir = int(row[ipi])
            o_app(int(row[ipr]) - ps)
            i_app(pir - int(row[ipo]))
            r_app(pir - ps)
    if not outbounds:
        return None
    return {
        "outbound": calc_stats(outbounds),
        "inbound": calc_stats(inbounds),
        "rtt": calc_stats(rtts),
    }


# ── Discovery ──────────────────────────────────────────────────────


def discover_scenarios(results_dir: Path) -> list[str]:
    """Find all scenario directories that contain CSV data."""
    scenarios = []
    for d in sorted(results_dir.iterdir()):
        if d.is_dir():
            csvs = list(d.glob("*_data.csv"))
            if csvs:
                scenarios.append(d.name)
    return scenarios


def load_scenario(results_dir: Path, name: str) -> dict:
    """Load all benchmark data for a scenario."""
    d = results_dir / name
    result = {"name": name, "cyclic": None, "ping": None, "uds": None}

    cyclic_csvs = list(d.glob("*_cyclic_data.csv"))
    if cyclic_csvs:
        result["cyclic"] = compute_cyclic(cyclic_csvs[0])

    ping_csvs = list(d.glob("*_ping_data.csv"))
    if ping_csvs:
        result["ping"] = compute_ping(ping_csvs[0])

    uds_csvs = list(d.glob("*_uds_data.csv"))
    if uds_csvs:
        result["uds"] = compute_ping(uds_csvs[0])  # same CSV format

    return result


# ── Formatting helpers ─────────────────────────────────────────────


def fmt_us(ns: float) -> str:
    """Format nanoseconds as microseconds with 2 decimal places."""
    return f"{ns / 1000:.2f}"


def _stat_cell(stats: dict | None, key: str) -> str:
    """Return formatted µs value or dash if data is missing."""
    if stats is None:
        return "—"
    return fmt_us(stats[key])


# ── Text output ────────────────────────────────────────────────────


def print_summary_table(scenarios: list[dict]):
    """Print a summary table to stdout covering all key metrics."""

    # ── Header ──
    print()
    print("IsoBench Isolation Results — all values in µs")
    print()
    print("  Cyclic metrics:      Wakeup Latency = effective_wakeup − planned_wakeup")
    print("                       Message Latency = effective_recv − effective_send")
    print("  Ping/Pong metrics:   Outbound        = pong_recv − ping_send")
    print("                       Inbound         = ping_recv − pong_send")
    print("                       RTT             = ping_recv − ping_send")
    print("  UDS IPC metrics:     (same as Ping/Pong but over Unix domain sockets)")
    print()

    col = (
        f"{'Scenario':<30} │ "
        f"{'Wk mean':>8} {'Wk p99':>8} {'Wk max':>8} │ "
        f"{'Msg mean':>8} {'Msg p99':>8} {'Msg max':>8} │ "
        f"{'Out p99':>8} {'In p99':>8} {'RTT p99':>8} {'RTT max':>8} │ "
        f"{'UDS p99':>8} {'UDS max':>8}"
    )
    sep = "─" * len(col)

    print(sep)
    print(col)
    print(sep)

    for s in scenarios:
        name = s["name"]
        c = s["cyclic"]
        p = s["ping"]
        u = s.get("uds")

        wk = c["wakeup_latency"] if c else None
        msg = c["message_latency"] if c else None
        outb = p["outbound"] if p else None
        inb = p["inbound"] if p else None
        rtt = p["rtt"] if p else None
        uds_rtt = u["rtt"] if u else None

        print(
            f"{name:<30} │ "
            f"{_stat_cell(wk, 'mean'):>8} {_stat_cell(wk, 'p99'):>8} {_stat_cell(wk, 'max'):>8} │ "
            f"{_stat_cell(msg, 'mean'):>8} {_stat_cell(msg, 'p99'):>8} {_stat_cell(msg, 'max'):>8} │ "
            f"{_stat_cell(outb, 'p99'):>8} {_stat_cell(inb, 'p99'):>8} "
            f"{_stat_cell(rtt, 'p99'):>8} {_stat_cell(rtt, 'max'):>8} │ "
            f"{_stat_cell(uds_rtt, 'p99'):>8} {_stat_cell(uds_rtt, 'max'):>8}"
        )

    print(sep)
    print()


# ── CSV output ─────────────────────────────────────────────────────

# Column groups for the summary CSV (csv_prefix, dict_key, source)
_CYCLIC_COLS = [
    ("cyclic_wakeup", "wakeup_latency"),
    ("cyclic_msg", "message_latency"),
]
_PING_COLS = [
    ("ping_outbound", "outbound"),
    ("ping_inbound", "inbound"),
    ("ping_rtt", "rtt"),
]
_UDS_COLS = [
    ("uds_outbound", "outbound"),
    ("uds_inbound", "inbound"),
    ("uds_rtt", "rtt"),
]
_STAT_KEYS = ["mean", "median", "p99", "p999", "max", "std"]


def write_summary_csv(scenarios: list[dict], path: Path):
    """Write a summary CSV for further processing."""
    header = ["scenario"]
    for prefix, _ in _CYCLIC_COLS:
        for sk in _STAT_KEYS:
            header.append(f"{prefix}_{sk}_ns")
    for prefix, _ in _PING_COLS:
        for sk in _STAT_KEYS:
            header.append(f"{prefix}_{sk}_ns")
    for prefix, _ in _UDS_COLS:
        for sk in _STAT_KEYS:
            header.append(f"{prefix}_{sk}_ns")

    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for s in scenarios:
            row = [s["name"]]
            # Cyclic columns
            for _, key in _CYCLIC_COLS:
                if s["cyclic"]:
                    st = s["cyclic"][key]
                    row.extend(f"{st[sk]:.0f}" if sk != "max" else str(st[sk])
                               for sk in _STAT_KEYS)
                else:
                    row.extend([""] * len(_STAT_KEYS))
            # Ping columns
            for _, key in _PING_COLS:
                if s["ping"]:
                    st = s["ping"][key]
                    row.extend(f"{st[sk]:.0f}" if sk != "max" else str(st[sk])
                               for sk in _STAT_KEYS)
                else:
                    row.extend([""] * len(_STAT_KEYS))
            # UDS columns
            for _, key in _UDS_COLS:
                if s.get("uds"):
                    st = s["uds"][key]
                    row.extend(f"{st[sk]:.0f}" if sk != "max" else str(st[sk])
                               for sk in _STAT_KEYS)
                else:
                    row.extend([""] * len(_STAT_KEYS))
            w.writerow(row)

    print(f"Summary CSV written to {path}")


# ── HTML report (pure HTML/CSS, no JS library) ────────────────────

# (metric_key, label, source)
_METRIC_DEFS = [
    ("wakeup_latency",  "Cyclic — Wakeup Latency",       "cyclic"),
    ("message_latency", "Cyclic — Message Latency",       "cyclic"),
    ("outbound",        "Ping/Pong — Outbound Latency",   "ping"),
    ("inbound",         "Ping/Pong — Inbound Latency",    "ping"),
    ("rtt",             "Ping/Pong — Round-Trip Time",     "ping"),
    ("outbound",        "UDS IPC — Outbound Latency",     "uds"),
    ("inbound",         "UDS IPC — Inbound Latency",      "uds"),
    ("rtt",             "UDS IPC — Round-Trip Time",       "uds"),
]


def _css_bar(value_us: float, max_us: float, color: str) -> str:
    """Return an inline CSS bar <div> proportional to max_us."""
    pct = (value_us / max_us * 100) if max_us > 0 else 0
    pct = min(pct, 100)
    return (
        f'<div style="display:flex;align-items:center;gap:4px">'
        f'<div style="height:14px;width:{pct:.1f}%;background:{color};'
        f'border-radius:2px;min-width:1px"></div>'
        f'<span style="white-space:nowrap;font-size:0.82em">{value_us:.2f}</span>'
        f'</div>'
    )


def generate_html_report(scenarios: list[dict], path: Path):
    """Generate a lightweight HTML report — no JS libraries, pure HTML/CSS."""

    # Find baseline p99 for highlighting
    baseline: dict[str, float] = {}
    for s in scenarios:
        if "baseline" in s["name"]:
            if s["cyclic"]:
                baseline[("cyclic", "wakeup_latency")] = s["cyclic"]["wakeup_latency"]["p99"]
                baseline[("cyclic", "message_latency")] = s["cyclic"]["message_latency"]["p99"]
            if s["ping"]:
                baseline[("ping", "outbound")] = s["ping"]["outbound"]["p99"]
                baseline[("ping", "inbound")] = s["ping"]["inbound"]["p99"]
                baseline[("ping", "rtt")] = s["ping"]["rtt"]["p99"]
            if s.get("uds"):
                baseline[("uds", "outbound")] = s["uds"]["outbound"]["p99"]
                baseline[("uds", "inbound")] = s["uds"]["inbound"]["p99"]
                baseline[("uds", "rtt")] = s["uds"]["rtt"]["p99"]
            break

    # ── Build per-metric sections ──
    metric_sections = ""

    for metric_key, label, src in _METRIC_DEFS:
        # Collect stats for scenarios that have this metric
        entries = []
        for s in scenarios:
            if s.get(src):
                entries.append((s["name"], s[src][metric_key]))

        if not entries:
            continue

        # Determine max p99 for bar scaling
        max_p99_us = max(e[1]["p99"] / 1000 for e in entries) or 1

        # Build stats table rows
        rows_html = ""
        for name, st in entries:
            p99_us = st["p99"] / 1000
            hl = ""
            bp = baseline.get((src, metric_key))
            if bp and st["p99"] > bp * 2:
                hl = ' class="highlight"'

            rows_html += (
                f"<tr>"
                f"<td>{name}</td>"
                f"<td>{st['n']}</td>"
                f"<td>{st['mean']/1000:.2f}</td>"
                f"<td>{st['median']/1000:.2f}</td>"
                f"<td{hl}>{p99_us:.2f}</td>"
                f"<td>{st['p999']/1000:.2f}</td>"
                f"<td{hl}>{st['max']/1000:.2f}</td>"
                f"<td>{st['std']/1000:.2f}</td>"
                f"</tr>\n"
            )

        # Build visual bar chart rows (p99 bars)
        bar_rows_p99 = ""
        for name, st in entries:
            p99_us = st["p99"] / 1000
            bar_rows_p99 += (
                f"<tr>"
                f"<td style='width:200px;font-size:0.82em'>{name}</td>"
                f"<td>{_css_bar(p99_us, max_p99_us, '#3498db')}</td>"
                f"</tr>\n"
            )

        # Build visual bar chart rows (max bars)
        max_max_us = max(e[1]["max"] / 1000 for e in entries) or 1
        bar_rows_max = ""
        for name, st in entries:
            max_us = st["max"] / 1000
            bar_rows_max += (
                f"<tr>"
                f"<td style='width:200px;font-size:0.82em'>{name}</td>"
                f"<td>{_css_bar(max_us, max_max_us, '#e74c3c')}</td>"
                f"</tr>\n"
            )

        metric_sections += f"""
<h2>{label} (µs)</h2>
<div class="chart-box">
  <h3>P99 Comparison</h3>
  <table class="bar-table">
    {bar_rows_p99}
  </table>
</div>
<div class="chart-box">
  <h3>Max Latency Comparison</h3>
  <table class="bar-table">
    {bar_rows_max}
  </table>
</div>
<table>
  <tr>
    <th>Scenario</th><th>N</th>
    <th>Mean</th><th>Median</th><th>P99</th>
    <th>P999</th><th>Max</th><th>Std</th>
  </tr>
  {rows_html}
</table>
"""

    # ── Overview: side-by-side P99 of all 5 metrics ──
    overview_header = "<tr><th>Scenario</th>"
    for _, label, _ in _METRIC_DEFS:
        overview_header += f"<th>{label} P99</th>"
        overview_header += f"<th>{label} Max</th>"
    overview_header += "</tr>\n"

    overview_rows = ""
    for s in scenarios:
        overview_rows += f"<tr><td>{s['name']}</td>"
        for metric_key, _, src in _METRIC_DEFS:
            if s.get(src):
                st = s[src][metric_key]
                p99_val = st["p99"] / 1000
                max_val = st["max"] / 1000
                bp = baseline.get((src, metric_key))
                hl_p99 = ""
                hl_max = ""
                if bp:
                    if st["p99"] > bp * 2:
                        hl_p99 = ' class="highlight"'
                    if st["max"] > bp * 2:
                        hl_max = ' class="highlight"'
                overview_rows += f"<td{hl_p99}>{p99_val:.2f}</td>"
                overview_rows += f"<td{hl_max}>{max_val:.2f}</td>"
            else:
                overview_rows += "<td>—</td><td>—</td>"
        overview_rows += "</tr>\n"

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>IsoBench — Isolation Benchmark Results</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         margin: 20px; background: #f8f9fa; color: #2c3e50; }}
  h1 {{ color: #2c3e50; border-bottom: 2px solid #2c3e50; padding-bottom: 8px; }}
  h2 {{ color: #34495e; margin-top: 40px; }}
  h3 {{ color: #555; margin: 6px 0; }}
  table {{ border-collapse: collapse; width: 100%; margin: 10px 0 30px 0;
           font-size: 0.9em; }}
  th, td {{ border: 1px solid #ddd; padding: 6px 10px; text-align: right; }}
  th {{ background: #2c3e50; color: white; }}
  tr:nth-child(even) {{ background: #f2f2f2; }}
  td:first-child, th:first-child {{ text-align: left; }}
  .highlight {{ background: #ffe0e0 !important; font-weight: bold; }}
  .chart-box {{ background: white; border-radius: 8px; padding: 12px 16px;
                box-shadow: 0 2px 8px rgba(0,0,0,0.08); margin: 14px 0; }}
  .bar-table {{ border: none; }}
  .bar-table td {{ border: none; padding: 3px 6px; }}
  .legend {{ background: #fff; padding: 14px 18px; border-radius: 8px;
             box-shadow: 0 1px 4px rgba(0,0,0,0.08); margin: 20px 0;
             font-size: 0.92em; line-height: 1.7; }}
  .legend code {{ background: #eef; padding: 1px 4px; border-radius: 3px; }}
</style>
</head>
<body>
<h1>IsoBench — Isolation Benchmark Results</h1>
<div class="legend">
  <strong>Key Metrics</strong><br>
  <em>Cyclic benchmark:</em><br>
  &nbsp;&nbsp;Wakeup Latency &nbsp;= <code>effective_wakeup_ns − planned_wakeup_ns</code><br>
  &nbsp;&nbsp;Message Latency = <code>effective_recv_ns − effective_send_ns</code><br>
  <em>Ping / Pong benchmark:</em><br>
  &nbsp;&nbsp;Outbound Latency = <code>pong_recv_ns − ping_send_ns</code> &nbsp;(ping → pong)<br>
  &nbsp;&nbsp;Inbound Latency &nbsp;= <code>ping_recv_ns − pong_send_ns</code> &nbsp;(pong → ping)<br>
  &nbsp;&nbsp;Round-Trip Time &nbsp;= <code>ping_recv_ns − ping_send_ns</code> &nbsp;(full loop)<br>
  <em>UDS IPC benchmark (Unix domain sockets):</em><br>
  &nbsp;&nbsp;Same metrics as Ping/Pong but measured over <code>AF_UNIX SOCK_DGRAM</code><br>
  &nbsp;&nbsp;(no network stack — pure kernel IPC path)<br>
  <br>
  Cells highlighted in <span style="background:#ffe0e0;padding:2px 6px;">red</span>
  have P99 &gt; 2× baseline.
</div>

<h2>Overview — All P99 Values (µs)</h2>
<table>
  {overview_header}
  {overview_rows}
</table>

{metric_sections}

</body>
</html>
"""

    with open(path, "w") as f:
        f.write(html)
    print(f"HTML report written to {path}")


# ── Main ───────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Analyze IsoBench isolation benchmark results"
    )
    parser.add_argument(
        "results_dir", type=Path,
        help="Directory containing benchmark results (e.g. benchmarks/results/)"
    )
    parser.add_argument(
        "--html", type=Path, default=None,
        help="Path for HTML report output (default: <results_dir>/report.html)"
    )
    parser.add_argument(
        "--csv", type=Path, default=None,
        help="Path for summary CSV output (default: <results_dir>/summary.csv)"
    )
    args = parser.parse_args()

    results_dir = args.results_dir
    if not results_dir.is_dir():
        print(f"Error: {results_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    scenario_names = discover_scenarios(results_dir)
    if not scenario_names:
        print(f"Error: no scenario data found in {results_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(scenario_names)} scenarios: {', '.join(scenario_names)}")

    scenarios = [load_scenario(results_dir, name) for name in scenario_names]

    print_summary_table(scenarios)

    csv_path = args.csv or (results_dir / "summary.csv")
    write_summary_csv(scenarios, csv_path)

    html_path = args.html or (results_dir / "report.html")
    generate_html_report(scenarios, html_path)


if __name__ == "__main__":
    main()
