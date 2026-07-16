#!/usr/bin/env python3
"""
Compare two CLOUDSC HDF5 output files and store aggregated stats in SQLite.

Computes per-variable, per-step error statistics:
  - Max/mean absolute error (L_inf / L_1)
  - Max/mean relative error (L_inf / L_1)
  - Power SNR (dB): 10 * log10( sum(ref^2) / sum((ref - test)^2) )
  - Variance SNR (dB): 10 * log10( var(ref) / var(ref - test) )

Usage:
  python compare_precision.py --db results.db \\
      --label "fp64_vs_fp32" \\
      --ref-precision fp64 --ref-nsteps 10 \\
      --test-precision fp32 --test-nsteps 10 \\
      --ngptotg 163840 --nproma 128 \\
      cloudsc_output_fp64_10steps.h5 cloudsc_output_fp32_10steps.h5
"""

import argparse
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

import h5py
import numpy as np


PROGNOSTIC_VARS = ["PT", "PQ", "PA", "PCLV"]
DEFAULT_DB = "cloudsc_results.db"


# ---------- SQLite schema ----------

SCHEMA = """
CREATE TABLE IF NOT EXISTS comparisons (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp     TEXT    NOT NULL,
    label         TEXT,
    ref_file      TEXT    NOT NULL,
    test_file     TEXT    NOT NULL,
    ref_precision TEXT,
    test_precision TEXT,
    ref_nsteps    INTEGER,
    test_nsteps   INTEGER,
    ngptotg       INTEGER,
    nproma        INTEGER,
    notes         TEXT
);

CREATE TABLE IF NOT EXISTS step_stats (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    comparison_id   INTEGER NOT NULL REFERENCES comparisons(id),
    step            INTEGER NOT NULL,
    variable        TEXT    NOT NULL,
    max_abs_err     REAL,
    mean_abs_err    REAL,
    max_rel_err     REAL,
    mean_rel_err    REAL,
    power_snr_db    REAL,
    var_snr_db      REAL,
    ref_min         REAL,
    ref_max         REAL,
    ref_mean        REAL,
    test_min        REAL,
    test_max        REAL,
    test_mean       REAL
);

CREATE INDEX IF NOT EXISTS idx_step_stats_comparison ON step_stats(comparison_id);
CREATE INDEX IF NOT EXISTS idx_step_stats_var ON step_stats(variable);
"""


def init_db(db_path: str) -> sqlite3.Connection:
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA)
    return conn


# ---------- Stats computation ----------

def load_step(h5file: h5py.File, step: int, var: str) -> np.ndarray:
    group = f"step_{step:08d}"
    return np.array(h5file[group][var], dtype=np.float64)


def compute_stats(ref: np.ndarray, test: np.ndarray) -> dict:
    diff = ref - test
    abs_diff = np.abs(diff)

    max_abs_err = float(np.max(abs_diff))
    mean_abs_err = float(np.mean(abs_diff))

    abs_ref = np.abs(ref)
    mask = abs_ref > 0.0
    if np.any(mask):
        rel_err = abs_diff[mask] / abs_ref[mask]
        max_rel_err = float(np.max(rel_err))
        mean_rel_err = float(np.mean(rel_err))
    else:
        max_rel_err = 0.0
        mean_rel_err = 0.0

    power_ref = np.sum(ref**2)
    power_err = np.sum(diff**2)
    power_snr_db = 10.0 * np.log10(power_ref / power_err) if power_err > 0.0 else float("inf")

    var_ref = np.var(ref)
    var_err = np.var(diff)
    var_snr_db = 10.0 * np.log10(var_ref / var_err) if var_err > 0.0 else float("inf")

    return {
        "max_abs_err": max_abs_err,
        "mean_abs_err": mean_abs_err,
        "max_rel_err": max_rel_err,
        "mean_rel_err": mean_rel_err,
        "power_snr_db": power_snr_db,
        "var_snr_db": var_snr_db,
        "ref_min": float(np.min(ref)),
        "ref_max": float(np.max(ref)),
        "ref_mean": float(np.mean(ref)),
        "test_min": float(np.min(test)),
        "test_max": float(np.max(test)),
        "test_mean": float(np.mean(test)),
    }


def get_steps(h5file: h5py.File) -> list[int]:
    steps = []
    for key in h5file.keys():
        if key.startswith("step_"):
            steps.append(int(key.split("_")[1]))
    return sorted(steps)


def parse_filename_metadata(filename: str) -> dict:
    """Try to extract precision and nsteps from filename like cloudsc_output_fp64_10steps.h5"""
    meta = {}
    m = re.search(r"(fp32|fp64)", filename)
    if m:
        meta["precision"] = m.group(1)
    m = re.search(r"(\d+)steps", filename)
    if m:
        meta["nsteps"] = int(m.group(1))
    return meta


# ---------- Main ----------

def do_compare(args):
    ref_path = Path(args.ref_file)
    test_path = Path(args.test_file)

    for p in [ref_path, test_path]:
        if not p.exists():
            print(f"ERROR: {p} not found", file=sys.stderr)
            sys.exit(1)

    # Auto-detect metadata from filenames if not provided
    ref_meta = parse_filename_metadata(ref_path.name)
    test_meta = parse_filename_metadata(test_path.name)

    ref_prec = args.ref_precision or ref_meta.get("precision")
    test_prec = args.test_precision or test_meta.get("precision")
    ref_nsteps = args.ref_nsteps or ref_meta.get("nsteps")
    test_nsteps = args.test_nsteps or test_meta.get("nsteps")

    # Open HDF5 files
    ref_h5 = h5py.File(ref_path, "r")
    test_h5 = h5py.File(test_path, "r")

    # Determine common steps
    ref_steps = get_steps(ref_h5)
    test_steps = get_steps(test_h5)

    if args.final_only:
        # Only compare the last step from each (they represent the same total physical time)
        common = [(max(ref_steps), max(test_steps))]
    elif ref_nsteps and test_nsteps and ref_nsteps != test_nsteps:
        # Different step counts: match steps at the same physical time.
        # With fixed total physical time, ref step k and test step j correspond
        # to the same time when k/ref_nsteps == j/test_nsteps.
        # E.g. ref=10, test=20 → pairs (1,2),(2,4),...,(10,20)
        # E.g. ref=10, test=5  → pairs (2,1),(4,2),...,(10,5)
        from math import gcd
        g = gcd(ref_nsteps, test_nsteps)
        ref_stride = ref_nsteps // g    # step increment in ref per matched point
        test_stride = test_nsteps // g   # step increment in test per matched point
        ref_step_set = set(ref_steps)
        test_step_set = set(test_steps)
        common = []
        for i in range(1, g + 1):
            rs = i * ref_stride
            ts = i * test_stride
            if rs in ref_step_set and ts in test_step_set:
                common.append((rs, ts))
        if args.steps is not None:
            requested = {int(s) for s in args.steps.split(",")}
            common = [(r, t) for r, t in common if r in requested]
    else:
        # Same step counts: compare step-by-step
        common_set = sorted(set(ref_steps) & set(test_steps))
        if args.steps is not None:
            requested = [int(s) for s in args.steps.split(",")]
            common_set = [s for s in requested if s in common_set]
        common = [(s, s) for s in common_set]

    if not common:
        print("ERROR: No steps to compare", file=sys.stderr)
        sys.exit(1)

    # Auto-generate label
    if not args.label:
        args.label = f"{ref_prec or 'ref'}_{ref_nsteps or '?'}steps_vs_{test_prec or 'test'}_{test_nsteps or '?'}steps"

    print(f"Reference: {ref_path.name} ({ref_prec}, {ref_nsteps} steps)")
    print(f"Test:      {test_path.name} ({test_prec}, {test_nsteps} steps)")
    print(f"Label:     {args.label}")
    if any(r != t for r, t in common):
        print(f"Comparing: {len(common)} matched time points (ref→test: {', '.join(f'{r}→{t}' for r,t in common)})")
    else:
        print(f"Steps:     {[s[0] for s in common]}")
    print()

    # Compute stats
    rows = []
    for ref_step, test_step in common:
        ref_group = ref_h5[f"step_{ref_step:08d}"]
        vars_available = [v for v in PROGNOSTIC_VARS if v in ref_group]

        for var in vars_available:
            ref_data = load_step(ref_h5, ref_step, var)
            test_data = load_step(test_h5, test_step, var)

            if ref_data.shape != test_data.shape:
                print(f"WARNING: shape mismatch at step {ref_step}/{test_step}, {var}: "
                      f"{ref_data.shape} vs {test_data.shape}", file=sys.stderr)
                continue

            stats = compute_stats(ref_data, test_data)
            rows.append({
                "step": ref_step,
                "variable": var,
                **stats,
            })

    ref_h5.close()
    test_h5.close()

    # Store in SQLite
    db_path = args.db
    conn = init_db(db_path)

    comp_id = conn.execute(
        """INSERT INTO comparisons
           (timestamp, label, ref_file, test_file, ref_precision, test_precision,
            ref_nsteps, test_nsteps, ngptotg, nproma, notes)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            datetime.now(timezone.utc).isoformat(),
            args.label,
            str(ref_path),
            str(test_path),
            ref_prec,
            test_prec,
            ref_nsteps,
            test_nsteps,
            args.ngptotg,
            args.nproma,
            args.notes,
        ),
    ).lastrowid

    for row in rows:
        conn.execute(
            """INSERT INTO step_stats
               (comparison_id, step, variable, max_abs_err, mean_abs_err,
                max_rel_err, mean_rel_err, power_snr_db, var_snr_db,
                ref_min, ref_max, ref_mean, test_min, test_max, test_mean)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                comp_id,
                row["step"],
                row["variable"],
                row["max_abs_err"],
                row["mean_abs_err"],
                row["max_rel_err"],
                row["mean_rel_err"],
                row["power_snr_db"] if np.isfinite(row["power_snr_db"]) else None,
                row["var_snr_db"] if np.isfinite(row["var_snr_db"]) else None,
                row["ref_min"],
                row["ref_max"],
                row["ref_mean"],
                row["test_min"],
                row["test_max"],
                row["test_mean"],
            ),
        )

    conn.commit()
    conn.close()
    print(f"  -> Stored {len(rows)} stat rows (comparison_id={comp_id})")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ref_file", help="Reference HDF5 file")
    parser.add_argument("test_file", help="Test HDF5 file")
    parser.add_argument("--label", default=None, help="Label for this comparison")
    parser.add_argument("--ref-precision", default=None, help="Reference precision (fp32/fp64)")
    parser.add_argument("--test-precision", default=None, help="Test precision (fp32/fp64)")
    parser.add_argument("--ref-nsteps", type=int, default=None, help="Reference substep count")
    parser.add_argument("--test-nsteps", type=int, default=None, help="Test substep count")
    parser.add_argument("--ngptotg", type=int, default=None, help="Column count used")
    parser.add_argument("--nproma", type=int, default=None, help="Block size used")
    parser.add_argument("--notes", default=None, help="Free-text notes for this run")
    parser.add_argument("--steps", default=None, help="Comma-separated steps to compare")
    parser.add_argument("--final-only", action="store_true", help="Only compare the final step")
    parser.add_argument("--db", default=DEFAULT_DB, help=f"SQLite database path (default: {DEFAULT_DB})")

    args = parser.parse_args()
    do_compare(args)


if __name__ == "__main__":
    main()
