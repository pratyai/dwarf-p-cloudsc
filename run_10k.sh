#!/bin/bash
#SBATCH --job-name=cloudsc-10k
#SBATCH --account=g34
#SBATCH --uenv=icon/25.2:v1@santis
#SBATCH --view=default
#SBATCH --constraint=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=run_10k_%j.log

set -euo pipefail
export CUDA_VISIBLE_DEVICES=0

# Long-horizon CLOUDSC run for the SNR-evolution figure (Figure 6(b)): a single
# 10000-step trajectory from the spun-up state, serialized at a logspaced set of
# substeps, comparing FP32 against FP64 and against the temporal and spatial
# discretization floors. Distinct from run_all.sh, which sweeps many short runs.
#
# Produces cloudsc_results_10k.db with four comparisons:
#   precision_fp64v32  FP32 vs FP64 at 16384 columns
#   temporal_n1v2      FP64 nsub=1 vs nsub=2 (temporal floor)
#   spatial_411_n1     coarse KLEV=137 vs KLEV=411 restricted (spatial floor)
#   spatial_411_n3     coarse KLEV=137 vs KLEV=411 nsub=3 restricted

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PY="${SCRIPT_DIR}/venv/bin/python"
BINARY=bin/dwarf-cloudsc-gpu-scc-k-caching-multistep
CFG="${SCRIPT_DIR}/config-files"

NSTEPS=10000
TPHYS=120.0
NPROMA=128
SPINUP=3
export CLOUDSC_OUT_STEPS=1,2,3,4,7,11,18,30,48,78,127,207,336,546,886,1438,2336,3793,6158,10000

source "${SCRIPT_DIR}/venv/bin/activate"
cd "${SCRIPT_DIR}/build"

# --- Spun-up inputs (generated once) ---
# input_spunup.h5:   3 FP64 steps off the IFS analysis, extracted as a new input.
# input_spunup_3x.h5: that state refined to 3x the vertical resolution (KLEV=411).
if [ ! -f "${CFG}/input_spunup.h5" ]; then
  ${BINARY}.fp64 1 16384 ${NPROMA} ${SPINUP} ${TPHYS} 1
  "${PY}" "${SCRIPT_DIR}/make_spunup_input.py" \
    --input "${CFG}/input.h5" \
    --output "cloudsc_output_fp64_${SPINUP}steps_16384col_137lev.h5" \
    --step "${SPINUP}" \
    --out "${CFG}/input_spunup.h5"
fi
if [ ! -f "${CFG}/input_spunup_3x.h5" ]; then
  "${PY}" "${SCRIPT_DIR}/vertical_refine.py" refine \
    "${CFG}/input_spunup.h5" "${CFG}/input_spunup_3x.h5" --factor 3
fi
ln -sf "${CFG}/input_spunup.h5" input_spunup.h5
ln -sf "${CFG}/input_spunup_3x.h5" input_spunup_3x.h5

# --- Runs (16384 columns: precision + temporal; 4096 columns: spatial) ---
CLOUDSC_INPUT=input_spunup ${BINARY}.fp64 1 16384 ${NPROMA} ${NSTEPS} ${TPHYS} 1
CLOUDSC_INPUT=input_spunup ${BINARY}.fp32 1 16384 ${NPROMA} ${NSTEPS} ${TPHYS} 1
CLOUDSC_INPUT=input_spunup ${BINARY}.fp64 1 16384 ${NPROMA} ${NSTEPS} ${TPHYS} 2

CLOUDSC_INPUT=input_spunup ${BINARY}.fp64 1 4096 ${NPROMA} ${NSTEPS} ${TPHYS} 1
NV_ACC_CUDA_STACKSIZE=262144 CLOUDSC_INPUT=input_spunup_3x ${BINARY}.fp64 1 4096 ${NPROMA} ${NSTEPS} ${TPHYS} 1
NV_ACC_CUDA_STACKSIZE=262144 CLOUDSC_INPUT=input_spunup_3x ${BINARY}.fp64 1 4096 ${NPROMA} ${NSTEPS} ${TPHYS} 3

# --- Restrict the KLEV=411 fine runs back to 137 for spatial comparison ---
"${PY}" "${SCRIPT_DIR}/vertical_refine.py" restrict \
  cloudsc_output_fp64_${NSTEPS}steps_4096col_411lev.h5 rest_411_n1.h5 --klev-coarse 137 --factor 3
"${PY}" "${SCRIPT_DIR}/vertical_refine.py" restrict \
  cloudsc_output_fp64_${NSTEPS}steps_4096col_411lev_nsub3.h5 rest_411_n3.h5 --klev-coarse 137 --factor 3

# --- Comparisons into cloudsc_results_10k.db ---
DB="${SCRIPT_DIR}/cloudsc_results_10k.db"
rm -f "${DB}"
C16=cloudsc_output_fp64_${NSTEPS}steps_16384col_137lev.h5
"${PY}" "${SCRIPT_DIR}/compare_precision.py" \
  "${C16}" cloudsc_output_fp32_${NSTEPS}steps_16384col_137lev.h5 \
  --label precision_fp64v32 --ref-precision fp64 --test-precision fp32 \
  --ref-nsteps ${NSTEPS} --test-nsteps ${NSTEPS} --ngptotg 16384 --nproma ${NPROMA} --db "${DB}"
"${PY}" "${SCRIPT_DIR}/compare_precision.py" \
  "${C16}" cloudsc_output_fp64_${NSTEPS}steps_16384col_137lev_nsub2.h5 \
  --label temporal_n1v2 --ref-precision fp64 --test-precision fp64 \
  --ref-nsteps ${NSTEPS} --test-nsteps ${NSTEPS} --ngptotg 16384 --nproma ${NPROMA} --db "${DB}"
C4=cloudsc_output_fp64_${NSTEPS}steps_4096col_137lev.h5
"${PY}" "${SCRIPT_DIR}/compare_precision.py" \
  "${C4}" rest_411_n1.h5 --label spatial_411_n1 --ref-precision fp64 \
  --ref-nsteps ${NSTEPS} --ngptotg 4096 --nproma ${NPROMA} --db "${DB}"
"${PY}" "${SCRIPT_DIR}/compare_precision.py" \
  "${C4}" rest_411_n3.h5 --label spatial_411_n3 --ref-precision fp64 \
  --ref-nsteps ${NSTEPS} --ngptotg 4096 --nproma ${NPROMA} --db "${DB}"

echo "run_10k complete -> ${DB}"
