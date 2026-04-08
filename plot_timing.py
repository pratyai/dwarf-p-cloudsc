#!/usr/bin/env python3
"""
Plot per-step kernel timing for CLOUDSC precision variants.

Usage:
  python plot_timing.py [--db cloudsc_results.db] [--out figs/]
"""

import argparse
import sqlite3
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

PRECISIONS = ["fp64", "fp32", "fp16"]
COLORS = {"fp64": "#1f77b4", "fp32": "#ff7f0e", "fp16": "#2ca02c"}
LABELS = {"fp64": "FP64", "fp32": "FP32", "fp16": "FP16"}


def load_timing(conn, ngptotg, nsteps, precisions):
    """Load per-step kernel timing, averaged over duplicate runs."""
    data = {}
    for prec in precisions:
        rows = conn.execute(
            """SELECT CAST(step AS INTEGER) as step,
                      AVG(kernel_ms) as kernel_ms,
                      AVG(wall_ms) as wall_ms,
                      AVG(update_ms) as update_ms,
                      AVG(d2h_ms) as d2h_ms
               FROM timing
               WHERE precision=? AND nsteps=? AND ngptotg=?
                 AND step NOT IN ('total', 'h2d')
               GROUP BY CAST(step AS INTEGER)
               ORDER BY CAST(step AS INTEGER)""",
            (prec, nsteps, ngptotg),
        ).fetchall()
        if rows:
            data[prec] = {
                "step": np.array([r[0] for r in rows]),
                "kernel_ms": np.array([r[1] for r in rows]),
                "wall_ms": np.array([r[2] for r in rows]),
                "update_ms": np.array([r[3] for r in rows]),
                "d2h_ms": np.array([r[4] for r in rows]),
            }
    return data


def plot_kernel_time(data, ngptotg, outdir):
    """Per-step kernel time for each precision."""
    fig, ax = plt.subplots(figsize=(5, 3.2))
    for prec in PRECISIONS:
        if prec not in data:
            continue
        d = data[prec]
        ax.plot(d["step"], d["kernel_ms"], "o-", color=COLORS[prec],
                label=LABELS[prec], markersize=4)
    ax.set_xlabel("Substep")
    ax.set_ylabel("Kernel time [ms]")
    ax.set_title(f"CLOUDSC kernel time per substep ({ngptotg // 1000}k columns)")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    p = Path(outdir) / f"kernel_time_{ngptotg}col.pdf"
    fig.savefig(p)
    print(f"  {p}")
    plt.close(fig)


def plot_wall_breakdown(data, ngptotg, outdir):
    """Stacked bar: kernel + update + d2h per precision (mean across steps)."""
    fig, ax = plt.subplots(figsize=(4, 3.2))
    precs = [p for p in PRECISIONS if p in data]
    kernel = [data[p]["kernel_ms"].mean() for p in precs]
    update = [data[p]["update_ms"].mean() for p in precs]
    d2h = [data[p]["d2h_ms"].mean() for p in precs]

    x = np.arange(len(precs))
    w = 0.5
    ax.bar(x, kernel, w, label="kernel", color="#1f77b4")
    ax.bar(x, update, w, bottom=kernel, label="update", color="#ff7f0e")
    ax.bar(x, d2h, w, bottom=np.array(kernel) + np.array(update),
           label="d2h", color="#2ca02c")
    ax.set_xticks(x)
    ax.set_xticklabels([LABELS[p] for p in precs])
    ax.set_ylabel("Time per substep [ms]")
    ax.set_title(f"Wall time breakdown ({ngptotg // 1000}k columns)")
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3, axis="y")
    fig.tight_layout()
    p = Path(outdir) / f"wall_breakdown_{ngptotg}col.pdf"
    fig.savefig(p)
    print(f"  {p}")
    plt.close(fig)


def plot_kernel_vs_grid(conn, nsteps, outdir):
    """Mean kernel time vs grid size for each precision."""
    grids = [r[0] for r in conn.execute(
        "SELECT DISTINCT ngptotg FROM timing WHERE step='total' "
        "AND nsteps=? AND precision IN ('fp64','fp32','fp16') "
        "ORDER BY ngptotg", (nsteps,)
    ).fetchall()]
    if len(grids) < 2:
        return

    fig, ax = plt.subplots(figsize=(5, 3.2))
    for prec in PRECISIONS:
        means = []
        valid_grids = []
        for g in grids:
            rows = conn.execute(
                """SELECT AVG(kernel_ms) FROM timing
                   WHERE precision=? AND nsteps=? AND ngptotg=?
                     AND step NOT IN ('total', 'h2d')""",
                (prec, nsteps, g),
            ).fetchone()
            if rows and rows[0] is not None:
                means.append(rows[0])
                valid_grids.append(g)
        if valid_grids:
            ax.plot([g / 1000 for g in valid_grids], means, "o-",
                    color=COLORS[prec], label=LABELS[prec], markersize=5)
    ax.set_xlabel("Columns [thousands]")
    ax.set_ylabel("Mean kernel time [ms]")
    ax.set_title("Kernel time scaling with grid size")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    p = Path(outdir) / "kernel_vs_grid.pdf"
    fig.savefig(p)
    print(f"  {p}")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="cloudsc_results.db")
    parser.add_argument("--out", default="figs", help="Output directory")
    parser.add_argument("--nsteps", type=int, default=10)
    args = parser.parse_args()

    Path(args.out).mkdir(exist_ok=True)
    conn = sqlite3.connect(args.db)

    grids = [r[0] for r in conn.execute(
        "SELECT DISTINCT ngptotg FROM timing WHERE step='total' "
        "AND nsteps=? ORDER BY ngptotg", (args.nsteps,)
    ).fetchall()]

    print(f"Grid sizes: {grids}")
    for ngptotg in grids:
        data = load_timing(conn, ngptotg, args.nsteps, PRECISIONS)
        if not data:
            continue
        print(f"\n{ngptotg} columns:")
        plot_kernel_time(data, ngptotg, args.out)
        plot_wall_breakdown(data, ngptotg, args.out)

    plot_kernel_vs_grid(conn, args.nsteps, args.out)

    conn.close()
    print("\nDone.")


if __name__ == "__main__":
    main()
