#!/bin/bash
#SBATCH --job-name=cloudsc-runs
#SBATCH --account=g34
#SBATCH --uenv=icon/25.2:v1@santis
#SBATCH --view=default
#SBATCH --constraint=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=run_all_%j.log

set -euo pipefail

export CUDA_VISIBLE_DEVICES=0

# Run CLOUDSC GPU SCC k-caching at multiple precisions and timestep counts.
# Produces HDF5 output files in build/ for later comparison.
#
# Usage: sbatch run_all.sh [--skip-existing] [--spinup N] [NSTEPS] [NPROMA] [TPHYS] [NSUB_COARSE] [NSUB_FINE]
# Defaults: NSTEPS=10, NPROMA=128, TPHYS=900.0, NSUB_COARSE=1, NSUB_FINE=2
# Runs at 1x, 2x, 4x of base grid (163840 columns)
# Temporal refinement: NSUB_COARSE vs NSUB_FINE, same NSTEPS
# Pass --skip-existing to skip runs whose output files already exist.
# Pass --spinup N to run N FP64 spinup steps and use the spun-up state
# as initial condition for all grid-loop runs (eliminates IFS spinup transient).

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

SKIP_EXISTING=0
SPINUP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-existing) SKIP_EXISTING=1; shift ;;
    --spinup) SPINUP=$2; shift 2 ;;
    *) break ;;
  esac
done

NSTEPS=${1:-10}
NPROMA=${2:-128}
TPHYS=${3:-900.0}
NSUB_COARSE=${4:-1}
NSUB_FINE=${5:-2}

# Grid sizes: 1x, 2x, 4x of the base column count
# 4x at FP64 ≈ 50 GB, fits in 96 GB GH200 HBM3
NGPTOTG_BASE=163840
GRID_MULTIPLIERS=(1 2 4)

BINARY=bin/dwarf-cloudsc-gpu-scc-k-caching-multistep

echo "============================================"
echo "  CLOUDSC multi-run comparison"
echo "  Base NGPTOTG=${NGPTOTG_BASE}  multipliers=${GRID_MULTIPLIERS[*]}"
echo "  NPROMA=${NPROMA}  TPHYS=${TPHYS}"
echo "  NSTEPS=${NSTEPS}  NSUB=${NSUB_COARSE} vs ${NSUB_FINE}"
echo "  Temporal refinement: NSUB=${NSUB_COARSE} vs NSUB=${NSUB_FINE}"
if [ ${SPINUP} -gt 0 ]; then
  echo "  Spinup: ${SPINUP} FP64 steps before measurement"
fi
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

# Activate venv (needed for make_spunup_input.py and vertical_refine.py)
source "${SCRIPT_DIR}/venv/bin/activate"

# --- Spinup phase ---
# Run a short FP64 simulation to move the state off the IFS analysis onto
# the forward-Euler attractor.  All grid-loop runs then start from this
# spun-up state, eliminating the step-1 transient.
CLOUDSC_INPUT_ENV=""
if [ ${SPINUP} -gt 0 ]; then
  SPUNUP_INPUT="${SCRIPT_DIR}/config-files/input_spunup.h5"

  if [ ${SKIP_EXISTING} -eq 1 ] && [ -f "${SPUNUP_INPUT}" ]; then
    echo ""
    echo ">>> Skipping spinup (${SPUNUP_INPUT} exists)"
  else
    echo ""
    echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    echo "  Spinup: ${SPINUP} FP64 steps (nsub=${NSUB_COARSE})"
    echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    ${BINARY}.fp64 1 ${NGPTOTG_BASE} ${NPROMA} ${SPINUP} ${TPHYS} ${NSUB_COARSE}

    # Find the spinup output file
    SPINUP_OUT="cloudsc_output_fp64_${SPINUP}steps_${NGPTOTG_BASE}col_137lev"
    if [ ${NSUB_COARSE} -gt 1 ]; then
      SPINUP_OUT="${SPINUP_OUT}_nsub${NSUB_COARSE}"
    fi
    SPINUP_OUT="${SPINUP_OUT}.h5"

    if [ ! -f "${SPINUP_OUT}" ]; then
      echo "FATAL: spinup output ${SPINUP_OUT} not produced" >&2
      exit 1
    fi

    echo ">>> Extracting spun-up state from step ${SPINUP}..."
    python "${SCRIPT_DIR}/make_spunup_input.py" \
      --input "${SCRIPT_DIR}/config-files/input.h5" \
      --output "${SPINUP_OUT}" \
      --step "${SPINUP}" \
      --out "${SPUNUP_INPUT}"
  fi

  # Symlink into build/ so CLOUDSC_INPUT works
  if [ ! -f input_spunup.h5 ]; then
    ln -sf "${SPUNUP_INPUT}" input_spunup.h5
  fi
  CLOUDSC_INPUT_ENV="CLOUDSC_INPUT=input_spunup"
  echo ">>> All grid-loop runs will use spun-up input"
fi

# --- Run all configurations ---

run_config() {
  local LABEL=$1
  local BIN_EXT=$2
  local STEPS=$3
  local NSUB=${4:-1}

  # Predict output filename to check if already computed
  local BASE="cloudsc_output_${BIN_EXT}_${STEPS}steps_${NGPTOTG}col"
  local OUTFILE
  if [ "${NSUB}" -gt 1 ]; then
    OUTFILE="${BASE}_137lev_nsub${NSUB}.h5"
    [ -f "${OUTFILE}" ] || OUTFILE="${BASE}_nsub${NSUB}.h5"
  else
    OUTFILE="${BASE}_137lev.h5"
    [ -f "${OUTFILE}" ] || OUTFILE="${BASE}.h5"
  fi

  if [ ${SKIP_EXISTING} -eq 1 ] && [ -f "${OUTFILE}" ]; then
    echo ""
    echo ">>> Skipping ${LABEL} (${OUTFILE} exists)"
    return 0
  fi

  echo ""
  echo ">>> Running ${LABEL}..."
  if [ -n "${CLOUDSC_INPUT_ENV}" ]; then
    env ${CLOUDSC_INPUT_ENV} ${BINARY}.${BIN_EXT} 1 ${NGPTOTG} ${NPROMA} ${STEPS} ${TPHYS} ${NSUB}
  else
    ${BINARY}.${BIN_EXT} 1 ${NGPTOTG} ${NPROMA} ${STEPS} ${TPHYS} ${NSUB}
  fi

  # Re-check after run
  if [ "${NSUB}" -gt 1 ]; then
    OUTFILE="${BASE}_137lev_nsub${NSUB}.h5"
    [ -f "${OUTFILE}" ] || OUTFILE="${BASE}_nsub${NSUB}.h5"
  else
    OUTFILE="${BASE}_137lev.h5"
    [ -f "${OUTFILE}" ] || OUTFILE="${BASE}.h5"
  fi

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

  run_config "FP64 coarse (${NSTEPS} steps, nsub=${NSUB_COARSE}, ${MULT}x)" fp64 ${NSTEPS} ${NSUB_COARSE}
  run_config "FP64 fine (${NSTEPS} steps, nsub=${NSUB_FINE}, ${MULT}x)" fp64 ${NSTEPS} ${NSUB_FINE}
  run_config "FP32 (${NSTEPS} steps, nsub=${NSUB_COARSE}, ${MULT}x)" fp32 ${NSTEPS} ${NSUB_COARSE}

  if [ ${HAVE_FP16} -eq 1 ]; then
    run_config "FP16 (${NSTEPS} steps, nsub=${NSUB_COARSE}, ${MULT}x)" fp16 ${NSTEPS} ${NSUB_COARSE}
  fi
done

# --- Spatial refinement runs (KLEV=137 vs KLEV=274) ---
echo ""
echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo "  Spatial refinement: KLEV=137 vs KLEV=274"
echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"

SPATIAL_NGPTOTG=40960
SPATIAL_TPHYS=120.0
export NV_ACC_CUDA_STACKSIZE=131072

# Generate refined input if needed
INPUT_2X="${SCRIPT_DIR}/config-files/input_2xklev.h5"
if [ ! -f "${INPUT_2X}" ]; then
  echo ">>> Generating 2xKLEV input..."
  python "${SCRIPT_DIR}/vertical_refine.py" refine "${SCRIPT_DIR}/config-files/input.h5" "${INPUT_2X}"
fi
if [ ! -f input_2xklev.h5 ]; then
  ln -sf "${INPUT_2X}" input_2xklev.h5
fi

SPATIAL_COARSE="cloudsc_output_fp64_${NSTEPS}steps_${SPATIAL_NGPTOTG}col_137lev.h5"
SPATIAL_FINE="cloudsc_output_fp64_${NSTEPS}steps_${SPATIAL_NGPTOTG}col_274lev.h5"
SPATIAL_FINE_NSUB2="cloudsc_output_fp64_${NSTEPS}steps_${SPATIAL_NGPTOTG}col_274lev_nsub2.h5"

if [ ${SKIP_EXISTING} -eq 1 ] && [ -f "${SPATIAL_COARSE}" ]; then
  echo ">>> Skipping spatial coarse (${SPATIAL_COARSE} exists)"
else
  echo ""
  echo ">>> Running spatial coarse (KLEV=137, nsub=1, TPHYS=${SPATIAL_TPHYS}, ${SPATIAL_NGPTOTG} cols)..."
  ${BINARY}.fp64 1 ${SPATIAL_NGPTOTG} ${NPROMA} ${NSTEPS} ${SPATIAL_TPHYS} 1
fi

if [ ${SKIP_EXISTING} -eq 1 ] && [ -f "${SPATIAL_FINE}" ]; then
  echo ">>> Skipping spatial fine (${SPATIAL_FINE} exists)"
else
  echo ""
  echo ">>> Running spatial fine (KLEV=274, nsub=1, TPHYS=${SPATIAL_TPHYS}, ${SPATIAL_NGPTOTG} cols)..."
  CLOUDSC_INPUT=input_2xklev ${BINARY}.fp64 1 ${SPATIAL_NGPTOTG} ${NPROMA} ${NSTEPS} ${SPATIAL_TPHYS} 1
fi

if [ ${SKIP_EXISTING} -eq 1 ] && [ -f "${SPATIAL_FINE_NSUB2}" ]; then
  echo ">>> Skipping spatial fine+temporal (${SPATIAL_FINE_NSUB2} exists)"
else
  echo ""
  echo ">>> Running spatial fine + temporal fine (KLEV=274, nsub=2, TPHYS=${SPATIAL_TPHYS}, ${SPATIAL_NGPTOTG} cols)..."
  CLOUDSC_INPUT=input_2xklev ${BINARY}.fp64 1 ${SPATIAL_NGPTOTG} ${NPROMA} ${NSTEPS} ${SPATIAL_TPHYS} 2
fi

echo ""
echo "============================================"
echo "  All runs complete. Output files in build/"
echo "============================================"
ls -lh ${SCRIPT_DIR}/build/cloudsc_output_*.h5
