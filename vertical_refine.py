#!/usr/bin/env python3
"""
Vertical grid refinement and restriction for CLOUDSC HDF5 files.

Subcommands:
  refine   — Interpolate input.h5 from KLEV to 2·KLEV levels
  restrict — Map output.h5 from 2·KLEV back to KLEV levels

The refinement doubles the vertical resolution by inserting new half-levels
at the geometric mean (linear in log-p) of consecutive original half-levels,
then interpolating all level-dependent fields to the new grid.

The restriction maps a refined-grid output back to the original coarse grid
by interpolating in log-pressure coordinates, so that coarse-grid and
restricted-fine-grid outputs can be compared for spatial convergence.

Usage:
  python vertical_refine.py refine  config-files/input.h5 config-files/input_2xklev.h5
  python vertical_refine.py restrict output_fine.h5 output_restricted.h5 --klev-coarse 137

The restricted output is directly comparable to a coarse-grid run via
compare_precision.py.
"""

import argparse
import re
import sys
from pathlib import Path

import h5py
import numpy as np


# ---------------------------------------------------------------------------
#  Vertical interpolation helpers
# ---------------------------------------------------------------------------

def interp_in_logp(p_old: np.ndarray, f_old: np.ndarray,
                   p_new: np.ndarray, axis: int = 0) -> np.ndarray:
    """Interpolate field f_old from p_old levels to p_new levels.

    Uses linear interpolation in log(pressure) coordinates.
    Extrapolation is constant (nearest-neighbor clamp).

    Parameters
    ----------
    p_old : 1-D pressure coordinate of the source grid (monotonic)
    f_old : N-D field array; the ``axis`` dimension has len(p_old) entries
    p_new : 1-D pressure coordinate of the target grid
    axis  : which axis of f_old corresponds to the vertical
    """
    lp_old = np.log(np.maximum(p_old, 1e-10))
    lp_new = np.log(np.maximum(p_new, 1e-10))

    # Move the interpolation axis to position 0
    f_work = np.moveaxis(f_old, axis, 0)
    orig_shape = f_work.shape
    nlev_old = orig_shape[0]
    rest = int(np.prod(orig_shape[1:])) if len(orig_shape) > 1 else 1

    f_flat = f_work.reshape(nlev_old, rest)
    out = np.empty((len(lp_new), rest), dtype=f_flat.dtype)

    for j in range(rest):
        out[:, j] = np.interp(lp_new, lp_old, f_flat[:, j])

    result = out.reshape((len(lp_new),) + orig_shape[1:])
    return np.moveaxis(result, 0, axis)


# ---------------------------------------------------------------------------
#  Refine input.h5  (KLEV -> 2·KLEV)
# ---------------------------------------------------------------------------

def refine_input(src_path: str, dst_path: str, *, factor: int = 2):
    """Double the vertical resolution of a CLOUDSC input file."""

    src = h5py.File(src_path, "r")
    dst = h5py.File(dst_path, "w")

    klev = int(src["KLEV"][0])
    klon = int(src["KLON"][0])
    print(f"Source: KLEV={klev}  KLON={klon}")

    # --- Build new pressure grid ---
    # PAPH: half-level pressures, shape (KLEV+1, KLON)
    paph_old = src["PAPH"][:]  # (KLEV+1, KLON)
    assert paph_old.shape[0] == klev + 1

    # New half-levels: insert geometric mean between each consecutive pair
    # Original level k -> new level 2k; inserted level -> 2k+1
    klev_new = factor * klev
    paph_new = np.empty((klev_new + 1, klon), dtype=np.float64)
    for k in range(klev):
        paph_new[2 * k, :] = paph_old[k, :]
        # Geometric mean = exp(0.5*(log(a) + log(b))) for log-p linearity
        paph_new[2 * k + 1, :] = np.sqrt(
            np.maximum(paph_old[k, :], 1e-10) *
            np.maximum(paph_old[k + 1, :], 1e-10)
        )
    paph_new[2 * klev, :] = paph_old[klev, :]

    # PAP: full-level pressures, shape (KLEV, KLON)
    # Define as arithmetic mean of bounding half-levels
    pap_new = 0.5 * (paph_new[:-1, :] + paph_new[1:, :])

    # Reference pressure coordinates for interpolation (column-mean)
    p_half_old = paph_old.mean(axis=1)      # (KLEV+1,)
    p_half_new = paph_new.mean(axis=1)      # (2*KLEV+1,)
    p_full_old = src["PAP"][:].mean(axis=1)  # (KLEV,)
    p_full_new = pap_new.mean(axis=1)        # (2*KLEV,)

    print(f"Refined: KLEV={klev_new}  half-levels={klev_new + 1}")

    # --- Copy / interpolate every dataset ---
    for name in src:
        ds = src[name]
        data = ds[:]
        shape = data.shape

        if name == "KLEV":
            dst.create_dataset(name, data=np.array([klev_new], dtype=data.dtype))
            print(f"  {name:25s}  {shape} -> scalar updated to {klev_new}")

        elif name == "PAPH":
            dst.create_dataset(name, data=paph_new)
            print(f"  {name:25s}  {shape} -> {paph_new.shape}")

        elif name == "PAP":
            dst.create_dataset(name, data=pap_new)
            print(f"  {name:25s}  {shape} -> {pap_new.shape}")

        elif len(shape) >= 2 and shape[0] == klev:
            # Full-level 2D field (KLEV, KLON) — e.g., PT, PQ, ...
            new_data = interp_in_logp(p_full_old, data, p_full_new, axis=0)
            dst.create_dataset(name, data=new_data)
            print(f"  {name:25s}  {shape} -> {new_data.shape}  (full-level interp)")

        elif len(shape) == 2 and shape[0] == klev + 1:
            # Half-level 2D field (KLEV+1, KLON)
            new_data = interp_in_logp(p_half_old, data, p_half_new, axis=0)
            dst.create_dataset(name, data=new_data)
            print(f"  {name:25s}  {shape} -> {new_data.shape}  (half-level interp)")

        elif len(shape) == 3 and shape[1] == klev:
            # 3D field (NCLV, KLEV, KLON) — e.g., PCLV, TENDENCY_*_CLD
            new_data = interp_in_logp(p_full_old, data, p_full_new, axis=1)
            dst.create_dataset(name, data=new_data)
            print(f"  {name:25s}  {shape} -> {new_data.shape}  (3D full-level interp)")

        elif len(shape) == 3 and shape[1] == klev + 1:
            # 3D field on half levels
            new_data = interp_in_logp(p_half_old, data, p_half_new, axis=1)
            dst.create_dataset(name, data=new_data)
            print(f"  {name:25s}  {shape} -> {new_data.shape}  (3D half-level interp)")

        else:
            # Scalar, horizontal-only, or parameter — copy as-is
            dst.create_dataset(name, data=data)
            print(f"  {name:25s}  {shape}  (copied)")

    src.close()
    dst.close()
    print(f"\nWrote: {dst_path}")


# ---------------------------------------------------------------------------
#  Restrict output.h5  (2·KLEV -> KLEV)
# ---------------------------------------------------------------------------

def restrict_output(src_path: str, dst_path: str, klev_coarse: int):
    """Restrict a refined-grid CLOUDSC output back to the coarse grid.

    The output file contains step groups, each with PT, PQ, PA, PCLV
    in Fortran-order (NPROMA, NLEV, NBLOCKS) or (NPROMA, NLEV, NCLV, NBLOCKS).
    All stored as float64.

    Uses full-weighting restriction (multigrid convention):
      f_coarse[k] = 0.5 * (f_fine[2k] + f_fine[2k+1])

    This is the correct restriction operator because the refinement placed
    two sub-levels (2k and 2k+1) between each pair of original half-levels
    (k and k+1).  Averaging the two sub-levels gives the best estimate of
    the coarse-level value without needing pressure coordinates.
    """

    src = h5py.File(src_path, "r")
    dst = h5py.File(dst_path, "w")

    # Discover step groups
    step_groups = sorted([g for g in src if g.startswith("step_")])
    if not step_groups:
        print(f"ERROR: No step_* groups found in {src_path}", file=sys.stderr)
        sys.exit(1)

    # Peek at first step to get dimensions
    # HDF5 stores Fortran arrays reversed: PT(NPROMA,KLEV,NBLOCKS) -> (NBLOCKS,KLEV,NPROMA)
    first = src[step_groups[0]]
    pt_shape = first["PT"].shape
    # Find the KLEV axis: it's the one with 2*klev_coarse elements
    klev_fine = 2 * klev_coarse
    klev_axis = None
    for i, s in enumerate(pt_shape):
        if s == klev_fine:
            klev_axis = i
            break
    if klev_axis is None:
        print(f"ERROR: Cannot find axis with {klev_fine} levels in PT shape {pt_shape}",
              file=sys.stderr)
        sys.exit(1)

    print(f"Source: {src_path}")
    print(f"  PT shape={pt_shape}  KLEV axis={klev_axis}  KLEV_fine={klev_fine}")
    print(f"  Restricting to KLEV_coarse={klev_coarse}  ({len(step_groups)} steps)")

    def avg_restrict(data, ax):
        """Average even/odd slices along axis ax."""
        even = np.take(data, range(0, data.shape[ax], 2), axis=ax)
        odd = np.take(data, range(1, data.shape[ax], 2), axis=ax)
        return 0.5 * (even + odd)

    for gname in step_groups:
        grp_src = src[gname]
        grp_dst = dst.create_group(gname)

        for var in ["PT", "PQ", "PA"]:
            if var not in grp_src:
                continue
            data = grp_src[var][:]
            grp_dst.create_dataset(var, data=avg_restrict(data, klev_axis))

        if "PCLV" in grp_src:
            data = grp_src["PCLV"][:]
            # PCLV has an extra NCLV dimension; find KLEV axis by size
            pclv_ax = None
            for i, s in enumerate(data.shape):
                if s == klev_fine:
                    pclv_ax = i
                    break
            if pclv_ax is None:
                print(f"ERROR: Cannot find KLEV axis in PCLV shape {data.shape}", file=sys.stderr)
                sys.exit(1)
            grp_dst.create_dataset("PCLV", data=avg_restrict(data, pclv_ax))

    src.close()
    dst.close()
    print(f"Wrote: {dst_path}")


# ---------------------------------------------------------------------------
#  CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command")

    # --- refine ---
    p_ref = sub.add_parser("refine",
        help="Refine input.h5 from KLEV to 2·KLEV levels")
    p_ref.add_argument("src", help="Source input HDF5 file")
    p_ref.add_argument("dst", help="Destination refined HDF5 file")

    # --- restrict ---
    p_res = sub.add_parser("restrict",
        help="Restrict output.h5 from 2·KLEV back to KLEV levels")
    p_res.add_argument("src", help="Source (refined-grid) output HDF5 file")
    p_res.add_argument("dst", help="Destination (coarse-grid) output HDF5 file")
    p_res.add_argument("--klev-coarse", type=int, default=137,
        help="Original coarse KLEV (default: 137)")

    args = parser.parse_args()

    if args.command == "refine":
        refine_input(args.src, args.dst)
    elif args.command == "restrict":
        restrict_output(args.src, args.dst, args.klev_coarse)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
