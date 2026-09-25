#!/usr/bin/env python3
"""Combine osdperf-leg.sh rounds: mean and min..max per leg and workload.

Usage: osdperf-summary.py <ab-dir>      (contains r1/<leg>/<wl>.summary, r2/..., ...)
"""
import glob
import os
import re
import statistics
import sys

root = sys.argv[1]
KEYS = [
    ("iops", r"^Average IOPS:\s+([\d.]+)"),
    ("lat_ms", r"^Average Latency\(s\):\s+([\d.]+)"),
    ("cpu_us_op", r"^osd_cpu_us_per_op_net\s+([\d.]+)"),
    ("ctxsw_op", r"^ctxsw_per_op\s+([\d.]+)"),
    ("txc_op", r"^bluestore_txc_per_op\s+([\d.]+)"),
    ("obc_hit", r"^obc_hit_rate\s+([\d.]+)"),
    ("op_w_us", r"^osd\.op_w_latency\s+([\d.]+)"),
    ("op_r_us", r"^osd\.op_r_latency\s+([\d.]+)"),
    ("rd_iops", r"^reads: Average IOPS:\s+([\d.]+)"),
]

data = {}  # (wl, leg) -> key -> [values]
for f in glob.glob(os.path.join(root, "r*", "*", "*.summary")):
    leg = os.path.basename(os.path.dirname(f))
    wl = os.path.basename(f)[: -len(".summary")]
    text = open(f).read().splitlines()
    for key, rx in KEYS:
        for line in text:
            m = re.match(rx, line)
            if m:
                v = float(m.group(1))
                if key == "lat_ms":
                    v *= 1000
                data.setdefault((wl, leg), {}).setdefault(key, []).append(v)

legs = sorted({leg for _, leg in data}, key=lambda x: (x != "none", x))
for wl in ("rw4k", "rr4k", "ec4k", "qd1", "orr", "mixw"):
    have = [leg for leg in legs if (wl, leg) in data]
    if not have:
        continue
    n = {leg: len(data[(wl, leg)].get("iops", [])) for leg in have}
    print(f"\n== {wl}   rounds: " + ", ".join(f"{leg}={n[leg]}" for leg in have))
    print(f"{'metric':10}" + "".join(f"{leg:>30}" for leg in have))
    base = data.get((wl, "none"), {})
    for key, _ in KEYS:
        if not any(key in data[(wl, leg)] for leg in have):
            continue
        cells = []
        for leg in have:
            v = data[(wl, leg)].get(key, [])
            if not v:
                cells.append(f"{'-':>30}")
                continue
            m = statistics.mean(v)
            delta = ""
            if leg != "none" and base.get(key) and statistics.mean(base[key]):
                delta = f"({100 * (m - statistics.mean(base[key])) / statistics.mean(base[key]):+.1f}%)"
            cells.append(f"{m:.4g} {delta} [{min(v):.4g}..{max(v):.4g}]".rjust(30))
        print(f"{key:10}" + "".join(cells))
