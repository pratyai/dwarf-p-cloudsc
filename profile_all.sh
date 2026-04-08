#!/bin/bash
#SBATCH --job-name=cloudsc-profile
#SBATCH --account=g34
#SBATCH --constraint=gpu
#SBATCH --gres=gpu:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=profile_all_%j.log

set -euo pipefail

export CUDA_VISIBLE_DEVICES=0

# Profile CLOUDSC GPU kernel with ncu across 3 grid sizes and precisions.
# Usage: sbatch profile_all.sh [NSTEPS] [NPROMA] [TPHYS]

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

NSTEPS=${1:-2}
NPROMA=${2:-128}
TPHYS=${3:-120.0}

NGPTOTG_BASE=163840
GRID_MULTIPLIERS=(1 2 4)
PRECISIONS=(fp64 fp32 fp16)

BINARY=bin/dwarf-cloudsc-gpu-scc-k-caching-multistep

NCU_METRICS="smsp__sass_average_data_bytes_per_sector_mem_global_op_ld.pct"
NCU_METRICS="${NCU_METRICS},smsp__sass_average_data_bytes_per_sector_mem_global_op_st.pct"
NCU_METRICS="${NCU_METRICS},l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio"
NCU_METRICS="${NCU_METRICS},l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio"
NCU_METRICS="${NCU_METRICS},smsp__warps_launched.sum"

PROF_DIR="${SCRIPT_DIR}/profile"
mkdir -p "${PROF_DIR}"

echo "============================================"
echo "  CLOUDSC ncu profiling"
echo "  Grids: ${GRID_MULTIPLIERS[*]}x (base ${NGPTOTG_BASE})"
echo "  Precisions: ${PRECISIONS[*]}"
echo "  NSTEPS=${NSTEPS}  NPROMA=${NPROMA}  TPHYS=${TPHYS}"
echo "============================================"

cd "${SCRIPT_DIR}/build"

for PREC in "${PRECISIONS[@]}"; do
  if [ ! -f "${BINARY}.${PREC}" ]; then
    echo "NOTE: ${BINARY}.${PREC} not found — skipping"
    continue
  fi

  for MULT in "${GRID_MULTIPLIERS[@]}"; do
    NGPTOTG=$((NGPTOTG_BASE * MULT))
    LABEL="cloudsc.${PREC}.${MULT}x"

    echo ""
    echo ">>> ${LABEL} (${NGPTOTG} cols)..."
    srun -A g34 ncu --set full --import-source yes \
      --metrics ${NCU_METRICS} \
      -o "${PROF_DIR}/${LABEL}" -f \
      "${BINARY}.${PREC}" 1 ${NGPTOTG} ${NPROMA} ${NSTEPS} ${TPHYS}
  done
done

echo ""
echo "============================================"
echo "  Done. Reports in ${PROF_DIR}/"
echo "============================================"
ls -lh "${PROF_DIR}"/*.ncu-rep 2>/dev/null
