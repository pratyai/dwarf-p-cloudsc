#!/bin/bash
set -euo pipefail

# Run CLOUDSC GPU SCC k-caching at multiple precisions and timestep counts.
# Produces HDF5 output files in build/ for later comparison.
#
# Configurations:
#   1. FP64 with NSTEPS substeps (reference baseline)
#   2. FP64 with NSTEPS*2 substeps (temporal refinement)
#   3. FP64 with NSTEPS/2 substeps (coarser temporal)
#   4. FP32 with NSTEPS substeps (precision comparison)
#
# Usage: ./run_all.sh [NSTEPS] [NGPTOTG] [NPROMA]
# Defaults: NSTEPS=10, NGPTOTG=163840, NPROMA=128

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NSTEPS=${1:-10}
NGPTOTG=${2:-163840}
NPROMA=${3:-128}

# Derived step counts
NSTEPS_FINE=$((NSTEPS * 2))
NSTEPS_COARSE=$(( (NSTEPS + 1) / 2 ))
if [ ${NSTEPS_COARSE} -lt 2 ]; then
  NSTEPS_COARSE=2
fi

BINARY=bin/dwarf-cloudsc-gpu-scc-k-caching-multistep
SRUN="srun -A g34 --constraint=gpu --gres=gpu:1 -n1 -t 5"

echo "============================================"
echo "  CLOUDSC multi-run comparison"
echo "  NGPTOTG=${NGPTOTG}  NPROMA=${NPROMA}"
echo "  Substeps: ${NSTEPS_COARSE}, ${NSTEPS}, ${NSTEPS_FINE} (FP64)"
echo "            ${NSTEPS} (FP32)"
echo "============================================"

cd ${SCRIPT_DIR}/build

# Check binaries
for ext in fp64 fp32; do
  if [ ! -f ${BINARY}.${ext} ]; then
    echo "FATAL: ${BINARY}.${ext} not found. Run build_both.sh first." >&2
    exit 1
  fi
done

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
  ${SRUN} ${BINARY}.${BIN_EXT} 1 ${NGPTOTG} ${NPROMA} ${STEPS}

  local PREC
  if [ "${BIN_EXT}" = "fp64" ]; then PREC="fp64"; else PREC="fp32"; fi
  local OUTFILE="cloudsc_output_${PREC}_${STEPS}steps.h5"

  if [ ! -f ${OUTFILE} ]; then
    echo "FATAL: ${OUTFILE} not produced" >&2
    exit 1
  fi
  echo ">>> ${LABEL} output: ${OUTFILE}"
}

run_config "FP64 baseline (${NSTEPS} steps)" fp64 ${NSTEPS}
run_config "FP64 fine (${NSTEPS_FINE} steps)" fp64 ${NSTEPS_FINE}
run_config "FP64 coarse (${NSTEPS_COARSE} steps)" fp64 ${NSTEPS_COARSE}
run_config "FP32 (${NSTEPS} steps)" fp32 ${NSTEPS}

echo ""
echo "============================================"
echo "  All runs complete. Output files in build/"
echo "============================================"
ls -lh ${SCRIPT_DIR}/build/cloudsc_output_*.h5
