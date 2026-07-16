# (C) Copyright 1988- ECMWF.
#
# This software is licensed under the terms of the Apache Licence Version 2.0
# which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
# In applying this licence, ECMWF does not waive the privileges and immunities
# granted to it by virtue of its status as an intergovernmental organisation
# nor does it submit to any jurisdiction.

# Source me to get the correct configure/build/run environment.
# Spack-based setup for CSCS ault (A100 nodes, NVHPC 21.3).

{ tracing_=${-//[^x]/}; set +x; } 2>/dev/null

if [ -x "$HOME/.local/bin/uv" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

if [[ -z "${SPACK_ROOT}" ]]; then
  echo "ERROR: SPACK_ROOT is not set. Please source your spack setup first."
  echo "  e.g.: source /path/to/spack/share/spack/setup-env.sh"
  return 1 2>/dev/null || exit 1
fi

spack env activate cloudsc-gpu 2>/dev/null || {
  echo "Spack environment 'cloudsc-gpu' not found."
  echo "Create it with: spack env create cloudsc-gpu spack.yaml"
  return 1 2>/dev/null || exit 1
}

spack load nvhpc
spack load cmake
spack load hdf5

export CC=nvc
export CXX=nvc++
export F77=nvfortran
export FC=nvfortran
export F90=nvfortran

NVHPC_ROOT=$(spack location -i nvhpc)
NVHPC_LIB=$(find ${NVHPC_ROOT} -name "libacchost.so" -o -name "libacchost.a" 2>/dev/null | head -1 | xargs dirname)
if [[ -n "${NVHPC_LIB}" ]]; then
  export CMAKE_PREFIX_PATH="${NVHPC_LIB}/..:${CMAKE_PREFIX_PATH}"
  export LIBRARY_PATH="${NVHPC_LIB}:${LIBRARY_PATH}"
  export LD_LIBRARY_PATH="${NVHPC_LIB}:${LD_LIBRARY_PATH}"
  echo "NVHPC libs found at: ${NVHPC_LIB}"
else
  echo "WARNING: Could not find libacchost in NVHPC installation"
fi

ulimit -S -s unlimited

{ if [[ -n "$tracing_" ]]; then set -x; else set +x; fi } 2>/dev/null

export ECBUILD_TOOLCHAIN="./toolchain.cmake"
