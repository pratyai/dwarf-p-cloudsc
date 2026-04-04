#!/bin/bash
#SBATCH --job-name=cloudsc-runs
#SBATCH --account=g34
#SBATCH --constraint=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:30:00
#SBATCH --output=run_all_%j.log

set -euo pipefail

# Run CLOUDSC GPU SCC k-caching at multiple precisions and timestep counts.
# Produces HDF5 output files in build/ for later comparison.
#
# Usage: sbatch run_all.sh [NSTEPS] [NPROMA] [TPHYS]
# Defaults: NSTEPS=10, NPROMA=128, TPHYS=120.0
# Runs at 1x, 2x, 4x of base grid (163840 columns)

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

NSTEPS=${1:-10}
NPROMA=${2:-128}
TPHYS=${3:-120.0}

# Grid sizes: 1x, 2x, 4x of the base column count
# 4x at FP64 ≈ 50 GB, fits in 96 GB GH200 HBM3
NGPTOTG_BASE=163840
GRID_MULTIPLIERS=(1 2 4)

# Derived step counts
NSTEPS_FINE=$((NSTEPS * 2))

BINARY=bin/dwarf-cloudsc-gpu-scc-k-caching-multistep

echo "============================================"
echo "  CLOUDSC multi-run comparison"
echo "  Base NGPTOTG=${NGPTOTG_BASE}  multipliers=${GRID_MULTIPLIERS[*]}"
echo "  NPROMA=${NPROMA}  TPHYS=${TPHYS}"
echo "  Substeps: ${NSTEPS}, ${NSTEPS_FINE} (FP64)"
echo "            ${NSTEPS} (FP32, FP16)"
echo "============================================"

cd ${SCRIPT_DIR}/build

# Check required binaries (fp64 and fp32 mandatory, fp16 optional)
for ext in fp64 fp32; do
  if [ ! -f ${BINARY}.${ext} ]; then
    echo "FATAL: ${BINARY}.${ext} not found. Run build_all.sh first." >&2
    exit 1
  fi
done
HAVE_FP16=0
if [ -f ${BINARY}.fp16 ]; then
  HAVE_FP16=1
else
  echo "NOTE: ${BINARY}.fp16 not found — skipping FP16 runs"
fi

# Check data
for f in input.h5 reference.h5; do
  if [ ! -f ${f} ]; then
    echo "FATAL: ${f} not found in build/. Create symlinks." >&2
    exit 1
  fi
done

# --- Run all configurations ---

run_config() {
  local LABEL=$1
  local BIN_EXT=$2
  local STEPS=$3

  echo ""
  echo ">>> Running ${LABEL}..."
  ${BINARY}.${BIN_EXT} 1 ${NGPTOTG} ${NPROMA} ${STEPS} ${TPHYS}

  # Precision tag matches the binary extension (fp64/fp32/fp16)
  local OUTFILE="cloudsc_output_${BIN_EXT}_${STEPS}steps_${NGPTOTG}col.h5"

  if [ ! -f ${OUTFILE} ]; then
    echo "FATAL: ${OUTFILE} not produced" >&2
    exit 1
  fi
  echo ">>> ${LABEL} output: ${OUTFILE}"
}

for MULT in "${GRID_MULTIPLIERS[@]}"; do
  NGPTOTG=$((NGPTOTG_BASE * MULT))
  echo ""
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
  echo "  Grid ${MULT}x: NGPTOTG=${NGPTOTG}"
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"

  run_config "FP64 baseline (${NSTEPS} steps, ${MULT}x)" fp64 ${NSTEPS}
  run_config "FP64 fine (${NSTEPS_FINE} steps, ${MULT}x)" fp64 ${NSTEPS_FINE}
  run_config "FP32 (${NSTEPS} steps, ${MULT}x)" fp32 ${NSTEPS}

  if [ ${HAVE_FP16} -eq 1 ]; then
    run_config "FP16 (${NSTEPS} steps, ${MULT}x)" fp16 ${NSTEPS}
  fi
done

echo ""
echo "============================================"
echo "  All runs complete. Output files in build/"
echo "============================================"
ls -lh ${SCRIPT_DIR}/build/cloudsc_output_*.h5
