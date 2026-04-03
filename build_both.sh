#!/bin/bash
set -euo pipefail

# Build CLOUDSC GPU SCC k-caching in both FP64 and FP32
# Usage: ./build_both.sh
# Requires: spack env 'cloudsc-gpu' already installed

ARCH=./arch/cscs/daint/nvhpc/24.7
BINARY=bin/dwarf-cloudsc-gpu-scc-k-caching-multistep
STASH_DIR=./build_stash

echo "============================================"
echo "  CLOUDSC dual-precision build script"
echo "============================================"

# Clean stash
rm -rf ${STASH_DIR}
mkdir -p ${STASH_DIR}

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

# --- FP64 build ---
echo ""
echo "============================================"
echo "  Building FP64 (double precision)"
echo "============================================"
./cloudsc-bundle build --clean --with-gpu \
    --arch=${ARCH} \
    --cloudsc-prototype1=OFF

if [ ! -f build/${BINARY} ]; then
  echo "FATAL: FP64 binary not found at build/${BINARY}" >&2
  exit 1
fi

# Stash FP64 binary and data symlinks BEFORE the clean build wipes them
cp build/${BINARY} ${STASH_DIR}/dwarf-cloudsc-gpu-scc-k-caching-multistep.fp64
echo ">>> FP64 binary stashed"

# --- FP32 build ---
echo ""
echo "============================================"
echo "  Building FP32 (single precision)"
echo "============================================"
./cloudsc-bundle build --clean --with-gpu --single-precision \
    --arch=${ARCH} \
    --cloudsc-prototype1=OFF

if [ ! -f build/${BINARY} ]; then
  echo "FATAL: FP32 binary not found at build/${BINARY}" >&2
  exit 1
fi

cp build/${BINARY} build/${BINARY}.fp32
echo ">>> FP32 binary saved"

# Move FP64 binary back into build/bin/
cp ${STASH_DIR}/dwarf-cloudsc-gpu-scc-k-caching-multistep.fp64 build/${BINARY}.fp64
echo ">>> FP64 binary restored"

# Clean up stash
rm -rf ${STASH_DIR}

# Verify both exist
echo ""
echo "============================================"
echo "  Verifying binaries..."
echo "============================================"
for ext in fp64 fp32; do
  if [ ! -f build/${BINARY}.${ext} ]; then
    echo "FATAL: build/${BINARY}.${ext} is missing!" >&2
    exit 1
  fi
  echo "  OK: build/${BINARY}.${ext} ($(stat --printf='%s' build/${BINARY}.${ext}) bytes)"
done

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
echo "    build/${BINARY}.fp64"
echo "    build/${BINARY}.fp32"
echo "============================================"
echo ""
echo "Run example (10 substeps, from build/ dir):"
echo "  cd build"
echo "  srun -A g34 --constraint=gpu --gres=gpu:1 -n1 -t 5 ${BINARY}.fp64 1 163840 128 10"
echo "  srun -A g34 --constraint=gpu --gres=gpu:1 -n1 -t 5 ${BINARY}.fp32 1 163840 128 10"
