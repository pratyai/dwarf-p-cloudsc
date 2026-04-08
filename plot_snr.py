#!/usr/bin/env python3
"""
Plot per-substep variance SNR evolution for CLOUDSC precision variants.
One 2x2 panel per grid size, all in a single multi-page PDF.

Step 0 in the DB is the initial condition and is excluded from plots.
Steps 1..N correspond to physics substeps p=1..N.

Usage:
  python plot_snr.py [--db cloudsc_results.db] [--out figs/snr_evolution.pdf]
"""

import argparse
import sqlite3
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

PRECISIONS = ["fp32", "fp16"]
STYLES = {
    "fp32": {"color": "#ff7f0e", "marker": "o", "label": "FP32"},
    "fp16": {"color": "#2ca02c", "marker": "s", "label": "FP16"},
}
FIELDS = ["PT", "PQ", "PA", "PCLV"]
FIELD_LABELS = {
    "PT": "PT (temperature)",
    "PQ": "PQ (humidity)",
    "PA": "PA (pressure dep.)",
    "PCLV": "PCLV (cloud condensate)",
}


def load_snr(conn, ngptotg, nsteps):
    """Load per-step variance SNR for each precision and field (skip IC at step 0)."""
    data = {}
    for prec in PRECISIONS:
        rows = conn.execute(
            """SELECT s.step, s.variable, s.var_snr_db
               FROM step_stats s JOIN comparisons c ON s.comparison_id = c.id
               WHERE c.label LIKE ? AND c.ngptotg = ? AND s.step >= 1
               ORDER BY s.variable, s.step""",
            (f"precision_fp64vs{prec.replace('fp', '')}%{ngptotg}%", ngptotg),
        ).fetchall()
        if rows:
            data[prec] = {}
            for step, var, snr in rows:
                data[prec].setdefault(var, {"step": [], "snr": []})
                data[prec][var]["step"].append(step)
                data[prec][var]["snr"].append(snr if snr is not None else float("nan"))
    return data


def load_disc_ref(conn):
    """Load temporal and vertical discretization reference SNR per field per step.

    Uses the smallest-grid comparison for each kind to avoid duplicates.
    Skips step 0 (IC).
    """
    refs = {}
    for kind, pattern in [("temporal", "temporal_refine%"), ("vertical", "spatial_refine%")]:
        # Pick one comparison (smallest grid) to avoid duplicates
        comp = conn.execute(
            """SELECT id FROM comparisons
               WHERE label LIKE ?
               ORDER BY ngptotg ASC LIMIT 1""",
            (pattern,),
        ).fetchone()
        if not comp:
            continue
        rows = conn.execute(
            """SELECT step, variable, var_snr_db
               FROM step_stats
               WHERE comparison_id = ? AND step >= 1
               ORDER BY variable, step""",
            (comp[0],),
        ).fetchall()
        if rows:
            refs[kind] = {}
            for step, var, snr in rows:
                refs[kind].setdefault(var, {"step": [], "snr": []})
                refs[kind][var]["step"].append(step)
                refs[kind][var]["snr"].append(snr if snr is not None else float("nan"))
    return refs


def plot_grid(fig, axes, data, refs, ngptotg):
    """Draw one 2x2 panel for a single grid size."""
    for i, field in enumerate(FIELDS):
        ax = axes[i]
        for prec in PRECISIONS:
            if prec not in data or field not in data[prec]:
                continue
            d = data[prec][field]
            steps = np.array(d["step"])
            snr = np.array(d["snr"], dtype=float)
            valid = np.isfinite(snr)
            if valid.any():
                ax.plot(steps[valid], snr[valid], "-",
                        color=STYLES[prec]["color"],
                        marker=STYLES[prec]["marker"],
                        markersize=4, label=STYLES[prec]["label"])
            # Mark divergence point
            if not valid.all() and valid.any():
                first_nan = np.where(~valid)[0][0]
                ax.axvline(steps[first_nan], color=STYLES[prec]["color"],
                           ls=":", alpha=0.5)

        if "temporal" in refs and field in refs["temporal"]:
            d = refs["temporal"][field]
            ax.plot(d["step"], d["snr"], "--", color="gray", alpha=0.6,
                    label="Temporal disc.")
        if "vertical" in refs and field in refs["vertical"]:
            d = refs["vertical"][field]
            ax.plot(d["step"], d["snr"], ":", color="gray", alpha=0.6,
                    label="Vertical disc.")

        ax.set_title(FIELD_LABELS[field], fontsize=10)
        ax.set_ylabel("Variance SNR [dB]")
        ax.grid(True, alpha=0.3)
        if i >= 2:
            ax.set_xlabel("Substep $p$")
        if i == 0:
            ax.legend(fontsize=7, loc="best")

    fig.suptitle(f"CLOUDSC precision SNR evolution ({ngptotg // 1000}k columns)",
                 fontsize=11)
    fig.tight_layout()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="cloudsc_results.db")
    parser.add_argument("--out", default="figs/snr_evolution.pdf")
    parser.add_argument("--nsteps", type=int, default=10)
    args = parser.parse_args()

    Path(args.out).parent.mkdir(exist_ok=True)
    conn = sqlite3.connect(args.db)

    grids = [r[0] for r in conn.execute(
        """SELECT DISTINCT c.ngptotg FROM comparisons c
           WHERE c.label LIKE 'precision%'
           ORDER BY c.ngptotg"""
    ).fetchall()]

    if not grids:
        print("No precision comparisons found in DB.")
        conn.close()
        return

    refs = load_disc_ref(conn)

    with PdfPages(args.out) as pdf:
        for ngptotg in grids:
            data = load_snr(conn, ngptotg, args.nsteps)
            if not data:
                print(f"  Skipping {ngptotg} (no data)")
                continue
            fig, axes = plt.subplots(2, 2, figsize=(8, 6), sharex=True)
            plot_grid(fig, axes.flatten(), data, refs, ngptotg)
            pdf.savefig(fig)
            plt.close(fig)
            print(f"  Page: {ngptotg // 1000}k columns")

    conn.close()
    print(f"Wrote: {args.out}")


if __name__ == "__main__":
    main()
