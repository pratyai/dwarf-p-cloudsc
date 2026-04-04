#!/bin/bash
set -euo pipefail

# Build CLOUDSC GPU SCC k-caching multistep in FP16, FP32, and FP64
# Starts with FP16 (most likely to break) so we fail fast.
# Usage: ./build_all.sh
# Requires: spack env 'cloudsc-gpu' already installed

ARCH=./arch/cscs/daint/nvhpc/24.7
BINARY=bin/dwarf-cloudsc-gpu-scc-k-caching-multistep
STASH_DIR=./build_stash

# --with-gpu-k-caching-only: builds only the k-caching GPU variant we need.
# Other GPU variants (hoist, stack, SCC, OMP) ICE under NVHPC at FP16.
# CPU variants (fortran, C, prototype1) also disabled — not needed.
COMMON_OPTS="--with-gpu-k-caching-only --arch=${ARCH} --cloudsc-prototype1=OFF --cloudsc-fortran=OFF --cloudsc-c=OFF"

echo "============================================"
echo "  CLOUDSC multi-precision build script"
echo "============================================"

# Clean stash and PTX collection
rm -rf ${STASH_DIR}
mkdir -p ${STASH_DIR}
PTX_DIR=./ptx
mkdir -p ${PTX_DIR}

# Activate spack environment
echo ""
echo ">>> Activating spack environment..."
spack env activate cloudsc-gpu
source ${ARCH}/env.sh

# Checkout dependencies if needed
if [ ! -d source/ecbuild ]; then
  echo ""
  echo ">>> Running cloudsc-bundle create..."
  ./cloudsc-bundle create
fi

# --- Helper: build one precision, stash the binary ---
build_precision() {
  local LABEL=$1    # e.g. "FP64"
  local EXT=$2      # e.g. "fp64"
  local EXTRA=$3    # extra bundle flags, e.g. "--single-precision"

  echo ""
  echo "============================================"
  echo "  Building ${LABEL}"
  echo "============================================"
  ./cloudsc-bundle build --clean ${COMMON_OPTS} ${EXTRA}

  if [ ! -f build/${BINARY} ]; then
    echo "FATAL: ${LABEL} binary not found at build/${BINARY}" >&2
    exit 1
  fi

  cp build/${BINARY} ${STASH_DIR}/${EXT}
  echo ">>> ${LABEL} binary stashed"

  # Extract SASS (native GPU assembly) from compiled binary
  local SASS_DIR="${PTX_DIR}/${EXT}"
  mkdir -p "${SASS_DIR}"
  cuobjdump --dump-sass "build/${BINARY}" > "${SASS_DIR}/cloudsc.sass" 2>/dev/null || true
  if [ -s "${SASS_DIR}/cloudsc.sass" ]; then
    echo ">>> ${LABEL}: SASS extracted to ${SASS_DIR}/cloudsc.sass"
    # Instruction mix summary
    echo "    FP64: $(grep -cE 'DADD|DMUL|DFMA' "${SASS_DIR}/cloudsc.sass" || echo 0) insns"
    echo "    FP32: $(grep -cE 'FADD|FMUL|FFMA' "${SASS_DIR}/cloudsc.sass" || echo 0) insns"
    echo "    FP16: $(grep -cE 'HADD2|HMUL2|HFMA2' "${SASS_DIR}/cloudsc.sass" || echo 0) insns"
  else
    echo ">>> ${LABEL}: no SASS extracted (cuobjdump not available?)"
    rm -f "${SASS_DIR}/cloudsc.sass"
  fi
}

# --- Build all three precisions (FP16 first — most fragile, fail fast) ---
build_precision "FP16 (half precision)"    fp16  "--half-precision"
build_precision "FP32 (single precision)"  fp32  "--single-precision"
build_precision "FP64 (double precision)"  fp64  ""

# --- Restore all binaries into build/bin/ ---
echo ""
echo "============================================"
echo "  Restoring binaries to build/bin/"
echo "============================================"
mkdir -p build/bin
for ext in fp64 fp32 fp16; do
  if [ -f ${STASH_DIR}/${ext} ]; then
    cp ${STASH_DIR}/${ext} build/${BINARY}.${ext}
    echo "  OK: build/${BINARY}.${ext}"
  fi
done

# Clean up stash
rm -rf ${STASH_DIR}

# Verify data files
for f in input.h5 reference.h5; do
  if [ ! -f build/${f} ]; then
    echo "WARNING: build/${f} missing — creating symlink"
    ln -sf $(pwd)/config-files/${f} build/${f}
  fi
done

echo ""
echo "============================================"
echo "  Done. Binaries:"
for ext in fp64 fp32 fp16; do
  if [ -f build/${BINARY}.${ext} ]; then
    echo "    build/${BINARY}.${ext}"
  fi
done
echo ""
echo "  SASS dumps:"
for ext in fp64 fp32 fp16; do
  if [ -f ${PTX_DIR}/${ext}/cloudsc.sass ]; then
    sz=$(wc -c < ${PTX_DIR}/${ext}/cloudsc.sass | tr -d ' ')
    echo "    ${PTX_DIR}/${ext}/cloudsc.sass  (${sz} bytes)"
  else
    echo "    ${PTX_DIR}/${ext}/  (none)"
  fi
done
echo "============================================"
