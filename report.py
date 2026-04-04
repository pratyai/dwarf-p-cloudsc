#!/usr/bin/env python3
"""
Report generator for CLOUDSC comparison results.

Reads the SQLite database produced by compare_precision.py and generates
formatted text reports with per-comparison and per-variable summaries.

Usage:
  python report.py --db cloudsc_results.db
  python report.py --db cloudsc_results.db --comparison 2
  python report.py --db cloudsc_results.db --query "SELECT * FROM step_stats WHERE variable='PT'"
"""

import argparse
import sqlite3
import sys
from pathlib import Path

import polars as pl


DEFAULT_DB = "cloudsc_results.db"


def connect(db_path: str) -> sqlite3.Connection:
    if not Path(db_path).exists():
        print(f"FATAL: Database not found: {db_path}", file=sys.stderr)
        print("  Run compare.sh first.", file=sys.stderr)
        sys.exit(1)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def fmt_snr(val) -> str:
    if val is None:
        return "     inf"
    return f"{val:8.1f}"


def fmt_err(val) -> str:
    if val is None:
        return "           N/A"
    return f"{val:14.6e}"


# ---------- Timing report ----------

def report_timing(conn: sqlite3.Connection):
    """Print per-step wall times for each precision at the baseline step count."""
    try:
        # Find the baseline nsteps: the step count shared by the most precisions
        base = conn.execute(
            "SELECT nsteps, COUNT(DISTINCT precision) AS np FROM timing "
            "WHERE step='total' GROUP BY nsteps ORDER BY np DESC, nsteps ASC LIMIT 1"
        ).fetchone()
        if not base or base["nsteps"] is None:
            return
        nsteps = base["nsteps"]

        # Get all precisions that have this step count
        precs = [r["precision"] for r in conn.execute(
            "SELECT DISTINCT precision FROM timing WHERE nsteps=? AND step != 'total' "
            "ORDER BY precision", (nsteps,)
        ).fetchall()]
    except sqlite3.OperationalError:
        return

    if not precs:
        return

    # Build {precision: {step: wall_ms}}
    data = {}
    for p in precs:
        rows = conn.execute(
            "SELECT step, wall_ms FROM timing WHERE precision=? AND nsteps=? "
            "AND step != 'total' ORDER BY CAST(step AS INTEGER)", (p, nsteps)
        ).fetchall()
        data[p] = {int(r["step"]): r["wall_ms"] for r in rows}

    steps = sorted(data[precs[0]].keys())

    # Header
    meta = conn.execute(
        "SELECT ngptotg, nproma FROM timing WHERE nsteps=? AND step='total' LIMIT 1",
        (nsteps,)
    ).fetchone()
    print()
    print(f"  Timing — wall time per step [ms]  "
          f"({nsteps} steps, {meta['ngptotg']} columns, nproma={meta['nproma']})")
    hdr = f"  {'step':>5}"
    for p in precs:
        hdr += f"  {p:>10}"
    print("  " + "-" * (6 + 12 * len(precs)))
    print(hdr)
    print("  " + "-" * (6 + 12 * len(precs)))

    for s in steps:
        row = f"  {s:>5}"
        for p in precs:
            row += f"  {data[p].get(s, 0.0):>10.1f}"
        print(row)


# ---------- Overview report ----------

def report_overview(conn: sqlite3.Connection):
    comps = conn.execute(
        "SELECT * FROM comparisons ORDER BY id"
    ).fetchall()

    if not comps:
        print("Database is empty.")
        return

    print()
    print("=" * 100)
    print("  CLOUDSC Comparison Report")
    print("=" * 100)

    # Comparisons table
    print()
    print(f"  {'ID':>3}  {'Label':<45} {'Ref':>12} {'Test':>12} {'Steps':>11}")
    print(f"  {'':>3}  {'':>45} {'(prec)':>12} {'(prec)':>12} {'(ref/test)':>11}")
    print("  " + "-" * 88)

    for c in comps:
        ref_tag = c["ref_precision"] or "?"
        test_tag = c["test_precision"] or "?"
        ref_n = c["ref_nsteps"] or "?"
        test_n = c["test_nsteps"] or "?"
        print(f"  {c['id']:>3}  {(c['label'] or '')::<45} {ref_tag:>12} {test_tag:>12} {ref_n:>5}/{test_n:<5}")

    # Timing summary (if timing table exists)
    report_timing(conn)

    # Per-comparison detail
    for c in comps:
        report_comparison(conn, c)

    # Legend
    print()
    print("  Legend")
    print("  " + "-" * 88)
    print("  Prognostic variables:")
    print("    PT   — Temperature                                   [K]")
    print("    PQ   — Specific humidity                             [kg/kg]")
    print("    PA   — Pressure departure (from reference profile)   [Pa]")
    print("    PCLV — Cloud liquid/ice water content (all species)  [kg/kg]")
    print()
    print("  Error metrics:")
    print("    max_abs_err  — Worst-case absolute difference  (L_inf norm of |ref - test|)")
    print("    mean_abs_err — Average absolute difference     (L_1 norm of |ref - test|)")
    print("    max_rel_err  — Worst-case relative difference  (max |ref - test| / |ref|, where ref != 0)")
    print("    mean_rel_err — Average relative difference     (mean |ref - test| / |ref|, where ref != 0)")
    print("    pwr_SNR      — Power signal-to-noise ratio     10*log10( sum(ref^2) / sum((ref-test)^2) )  [dB]")
    print("    var_SNR      — Variance signal-to-noise ratio  10*log10( var(ref) / var(ref-test) )        [dB]")
    print("                   Higher SNR = closer match; inf = identical")

    print()
    print("=" * 100)


# ---------- Single comparison report ----------

def report_comparison(conn: sqlite3.Connection, comp):
    comp_id = comp["id"] if hasattr(comp, "keys") else comp

    if isinstance(comp_id, int):
        comp = conn.execute(
            "SELECT * FROM comparisons WHERE id=?", (comp_id,)
        ).fetchone()
        if not comp:
            print(f"Comparison {comp_id} not found.", file=sys.stderr)
            return

    stats = conn.execute(
        """SELECT * FROM step_stats
           WHERE comparison_id=?
           ORDER BY variable, step""",
        (comp["id"],),
    ).fetchall()

    if not stats:
        print(f"\n  Comparison {comp['id']}: {comp['label']} — no stats recorded")
        return

    print()
    print(f"  Comparison {comp['id']}: {comp['label']}")
    print(f"  ref={comp['ref_precision']} {comp['ref_nsteps']}steps  "
          f"test={comp['test_precision']} {comp['test_nsteps']}steps  "
          f"ngptotg={comp['ngptotg']}  nproma={comp['nproma']}")
    if comp["notes"]:
        print(f"  notes: {comp['notes']}")
    print()

    # Per-step detail table
    print(f"    {'step':>5} {'var':>6} {'max_abs_err':>14} {'mean_abs_err':>14} "
          f"{'max_rel_err':>14} {'mean_rel_err':>14} {'pwr_SNR':>8} {'var_SNR':>8}")
    print("    " + "-" * 90)

    for s in stats:
        print(f"    {s['step']:>5} {s['variable']:>6} "
              f"{fmt_err(s['max_abs_err'])} {fmt_err(s['mean_abs_err'])} "
              f"{fmt_err(s['max_rel_err'])} {fmt_err(s['mean_rel_err'])} "
              f"{fmt_snr(s['power_snr_db'])} {fmt_snr(s['var_snr_db'])}")

    # Per-variable summary (worst across steps)
    df = pl.DataFrame([dict(s) for s in stats])
    summary = df.group_by("variable").agg(
        pl.col("max_abs_err").max().alias("worst_abs"),
        pl.col("max_rel_err").max().alias("worst_rel"),
        pl.col("mean_abs_err").max().alias("worst_mean_abs"),
        pl.col("mean_rel_err").max().alias("worst_mean_rel"),
        pl.col("power_snr_db").min().alias("min_pwr_snr"),
        pl.col("var_snr_db").min().alias("min_var_snr"),
        pl.col("step").count().alias("n_steps"),
    ).sort("variable")

    print()
    print(f"    Summary (worst across {summary['n_steps'][0]} time points):")
    print(f"    {'var':>6} {'worst_abs':>14} {'worst_rel':>14} {'worst_mean_abs':>14} "
          f"{'worst_mean_rel':>14} {'min_pwr_SNR':>12} {'min_var_SNR':>12}")
    print("    " + "-" * 90)

    for row in summary.iter_rows(named=True):
        print(f"    {row['variable']:>6} "
              f"{fmt_err(row['worst_abs'])} {fmt_err(row['worst_rel'])} "
              f"{fmt_err(row['worst_mean_abs'])} {fmt_err(row['worst_mean_rel'])} "
              f"{fmt_snr(row['min_pwr_snr']):>12} {fmt_snr(row['min_var_snr']):>12}")


# ---------- SQL query ----------

def report_query(conn: sqlite3.Connection, query: str):
    try:
        cur = conn.execute(query)
    except sqlite3.OperationalError as e:
        print(f"SQL error: {e}", file=sys.stderr)
        sys.exit(1)

    results = cur.fetchall()
    if not results:
        print("No results.")
        return

    cols = results[0].keys()
    # Use polars for nice formatting
    data = [dict(r) for r in results]
    df = pl.DataFrame(data)
    print(df)


# ---------- Main ----------

def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--db", default=DEFAULT_DB, help=f"SQLite database (default: {DEFAULT_DB})")
    parser.add_argument("--comparison", "-c", type=int, default=None,
                        help="Show only this comparison ID")
    parser.add_argument("--query", "-q", default=None,
                        help="Run arbitrary SQL query and display results")

    args = parser.parse_args()
    conn = connect(args.db)

    if args.query:
        report_query(conn, args.query)
    elif args.comparison:
        report_comparison(conn, args.comparison)
    else:
        report_overview(conn)

    conn.close()


if __name__ == "__main__":
    main()
