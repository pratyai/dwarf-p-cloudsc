#!/usr/bin/env python3
"""
Create a spun-up input file by extracting the final-step state from a
CLOUDSC FP64 output and patching it into a copy of the original input.

The output HDF5 stores prognostics in blocked layout (NPROMA, KLEV, NBLOCKS).
The input HDF5 stores them as (KLEV, KLON) with KLON=100 columns that get
tiled at runtime.  We extract the first KLON columns from the output and
reshape back to input layout.

Usage:
  python make_spunup_input.py [--step N] [--input input.h5] [--output output.h5] [--out input_spunup.h5]

  --step    : which step to extract (default: last step in the file)
  --input   : original input file to copy non-prognostic fields from
  --output  : CLOUDSC output file containing the spun-up state
  --out     : output path for the new input file
"""

import argparse
import re
import shutil
from pathlib import Path

import h5py
import numpy as np


PROGNOSTIC_2D = ["PT", "PQ", "PA"]  # (NPROMA, KLEV, NBLOCKS) -> (KLEV, KLON)
PROGNOSTIC_3D = ["PCLV"]            # (NPROMA, KLEV, NCLV, NBLOCKS) -> (NCLV, KLEV, KLON)


def find_last_step(f):
    """Find the highest step number in the output file."""
    steps = [k for k in f.keys() if re.match(r"step_\d+", k)]
    if not steps:
        raise ValueError("No step_NNNN groups found in output file")
    return max(steps, key=lambda s: int(s.split("_")[1]))


def unblock_2d(data, klon):
    """Convert Fortran (NPROMA, KLEV, NBLOCKS) stored as C-order (NBLOCKS, KLEV, NPROMA)
    in HDF5 -> (KLEV, KLON) taking first KLON columns."""
    nblocks, klev, nproma = data.shape
    # Flatten blocks: (NBLOCKS*NPROMA, KLEV), take first KLON
    flat = data.reshape(nblocks * nproma, klev)  # block-major is already correct: block0 cols, block1 cols...
    # Actually blocks are outermost, nproma innermost, so (NBLOCKS, KLEV, NPROMA)
    # -> swap to (NBLOCKS, NPROMA, KLEV) -> reshape (NGPTOT, KLEV)
    flat = data.transpose(0, 2, 1).reshape(nblocks * nproma, klev)
    return flat[:klon, :].T  # (KLEV, KLON)


def unblock_3d(data, klon):
    """Convert Fortran (NPROMA, KLEV, NCLV, NBLOCKS) stored as C-order (NBLOCKS, NCLV, KLEV, NPROMA)
    in HDF5 -> (NCLV, KLEV, KLON) taking first KLON columns."""
    nblocks, nclv, klev, nproma = data.shape
    # -> (NBLOCKS, NPROMA, KLEV, NCLV) -> (NGPTOT, KLEV, NCLV)
    flat = data.transpose(0, 3, 2, 1).reshape(nblocks * nproma, klev, nclv)
    return flat[:klon, :, :].transpose(2, 1, 0)  # (NCLV, KLEV, KLON)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--step", type=int, default=None,
                        help="Step to extract (default: last)")
    parser.add_argument("--input", default="config-files/input.h5",
                        help="Original input file")
    parser.add_argument("--output", required=True,
                        help="CLOUDSC output file with spun-up state")
    parser.add_argument("--out", default="config-files/input_spunup.h5",
                        help="Output path for spun-up input")
    args = parser.parse_args()

    # Copy original input as base
    src = Path(args.input)
    dst = Path(args.out)
    if not src.exists():
        raise FileNotFoundError(f"Input file not found: {src}")

    print(f"Copying {src} -> {dst}")
    shutil.copy2(src, dst)

    # Open output and extract state
    with h5py.File(args.output, "r") as fout:
        if args.step is not None:
            step_key = f"step_{args.step:04d}"
        else:
            step_key = find_last_step(fout)
        print(f"Extracting state from {step_key}")

        grp = fout[step_key]

        # Get KLON from original input
        with h5py.File(dst, "r") as fin:
            klon = fin["PT"].shape[1]  # (KLEV, KLON)
            print(f"  KLON = {klon}")

        # Patch prognostic fields
        with h5py.File(dst, "a") as fpatch:
            for var in PROGNOSTIC_2D:
                data = grp[var][:]  # (NPROMA, KLEV, NBLOCKS)
                patched = unblock_2d(data, klon)
                print(f"  {var}: {grp[var].shape} -> {patched.shape}")
                del fpatch[var]
                fpatch.create_dataset(var, data=patched)

            for var in PROGNOSTIC_3D:
                data = grp[var][:]  # (NPROMA, KLEV, NCLV, NBLOCKS)
                patched = unblock_3d(data, klon)
                print(f"  {var}: {grp[var].shape} -> {patched.shape}")
                del fpatch[var]
                fpatch.create_dataset(var, data=patched)

    print(f"\nSpun-up input written to: {dst}")
    print("Usage: CLOUDSC_INPUT=input_spunup <binary> ...")


if __name__ == "__main__":
    main()
