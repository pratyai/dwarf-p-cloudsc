#!/bin/bash
#SBATCH --job-name=cloudsc-spatial
#SBATCH --account=g34
#SBATCH --constraint=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --output=spatial_refine_%j.log

set -euo pipefail

export CUDA_VISIBLE_DEVICES=0
export NV_ACC_CUDA_STACKSIZE=131072

# Spatial (vertical) refinement: run CLOUDSC at KLEV and 2*KLEV,
# restrict the fine output back to the coarse grid, then compare.
#
# Usage: sbatch run_spatial_refine.sh [NSTEPS] [NPROMA] [TPHYS] [NGPTOTG]
# Defaults: NSTEPS=10, NPROMA=128, TPHYS=900.0, NGPTOTG=163840

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BUILD="${SCRIPT_DIR}/build"

NSTEPS=${1:-10}
NPROMA=${2:-128}
TPHYS=${3:-900.0}
NGPTOTG=${4:-163840}

CONFIGDIR="${SCRIPT_DIR}/config-files"
INPUT_ORIG="${CONFIGDIR}/input.h5"
INPUT_2X="${CONFIGDIR}/input_2xklev.h5"

BIN="${BUILD}/bin/dwarf-cloudsc-gpu-scc-k-caching-multistep"

# --- Activate venv ---
source "${SCRIPT_DIR}/venv/bin/activate"

# --- Step 1: Generate refined input if needed ---
if [ ! -f "${INPUT_2X}" ]; then
  echo "=== Generating 2xKLEV input ==="
  python "${SCRIPT_DIR}/vertical_refine.py" refine "${INPUT_ORIG}" "${INPUT_2X}"
  echo ""
fi

# Ensure input_2xklev.h5 is accessible from build/
if [ ! -f "${BUILD}/input_2xklev.h5" ]; then
  ln -s "${INPUT_2X}" "${BUILD}/input_2xklev.h5"
fi

# --- Step 2: Run coarse-grid (KLEV=137) ---
echo "=== Running coarse-grid (KLEV=137) ==="
cd "${BUILD}"
srun "${BIN}" 1 "${NGPTOTG}" "${NPROMA}" "${NSTEPS}" "${TPHYS}"

COARSE_OUT="${BUILD}/cloudsc_output_fp64_${NSTEPS}steps_${NGPTOTG}col_137lev.h5"
if [ ! -f "${COARSE_OUT}" ]; then
  echo "FATAL: Coarse output not found: ${COARSE_OUT}" >&2
  exit 1
fi
echo "  Coarse output: ${COARSE_OUT}"
echo ""

# --- Step 3: Run fine-grid (KLEV=274) via env var ---
echo "=== Running fine-grid (KLEV=274) ==="
srun --export=ALL,CLOUDSC_INPUT=input_2xklev,NV_ACC_CUDA_STACKSIZE=131072 "${BIN}" 1 "${NGPTOTG}" "${NPROMA}" "${NSTEPS}" "${TPHYS}"

FINE_OUT="${BUILD}/cloudsc_output_fp64_${NSTEPS}steps_${NGPTOTG}col_274lev.h5"
if [ ! -f "${FINE_OUT}" ]; then
  echo "FATAL: Fine output not found: ${FINE_OUT}" >&2
  exit 1
fi
echo "  Fine output: ${FINE_OUT}"
echo ""

# --- Step 4: Restrict fine output to coarse grid ---
RESTRICTED="${BUILD}/cloudsc_output_fp64_2xklev_restricted_${NSTEPS}steps_${NGPTOTG}col.h5"
echo "=== Restricting fine output to coarse grid ==="
python "${SCRIPT_DIR}/vertical_refine.py" restrict "${FINE_OUT}" "${RESTRICTED}" --klev-coarse 137
echo "  Restricted output: ${RESTRICTED}"
echo ""

# --- Step 5: Compare coarse vs restricted-fine ---
echo "=== Comparing coarse vs restricted-fine ==="
python "${SCRIPT_DIR}/compare_precision.py" \
  --label "spatial_refine_klev137vs274_${NGPTOTG}col" \
  --ref-precision fp64 --ref-nsteps "${NSTEPS}" \
  --test-precision fp64 --test-nsteps "${NSTEPS}" \
  --db "${SCRIPT_DIR}/cloudsc_results.db" \
  --ngptotg "${NGPTOTG}" --nproma "${NPROMA}" \
  "${COARSE_OUT}" "${RESTRICTED}"

echo ""
echo "=== Done ==="
echo "Results appended to: ${SCRIPT_DIR}/cloudsc_results.db"
