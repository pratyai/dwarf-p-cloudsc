# (C) Copyright 1988- ECMWF.
#
# This software is licensed under the terms of the Apache Licence Version 2.0
# which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
# In applying this licence, ECMWF does not waive the privileges and immunities
# granted to it by virtue of its status as an intergovernmental organisation
# nor does it submit to any jurisdiction.

####################################################################
# COMPILER
####################################################################

set( ECBUILD_FIND_MPI ON )

####################################################################
# OpenMP FLAGS
####################################################################

get_filename_component( _nvhpc_bin "${CMAKE_Fortran_COMPILER}" DIRECTORY )
set( _nvhpc_lib "${_nvhpc_bin}/../lib" )
get_filename_component( _nvhpc_lib "${_nvhpc_lib}" ABSOLUTE )

set( OpenMP_Fortran_FLAGS     "-mp -mp=gpu,bind,allcores,numa" CACHE STRING "" )
set( OpenMP_Fortran_LIB_NAMES "acchost" CACHE STRING "" )
find_library( OpenMP_acchost_LIBRARY NAMES acchost HINTS ${_nvhpc_lib} )

set( OpenMP_C_FLAGS           "-mp -mp=bind,allcores,numa" CACHE STRING "" )
set( OpenMP_C_LIB_NAMES       "acchost" CACHE STRING "")

####################################################################
# OpenAcc FLAGS
####################################################################

# A100: cc80
set( OpenACC_Fortran_FLAGS "-acc=gpu -mp=gpu -gpu=cc80,lineinfo,fastmath" CACHE STRING "" )

####################################################################
# COMMON FLAGS
####################################################################

set(ECBUILD_Fortran_FLAGS "-fpic")
set(ECBUILD_Fortran_FLAGS "${ECBUILD_Fortran_FLAGS} -Mframe")
set(ECBUILD_Fortran_FLAGS "${ECBUILD_Fortran_FLAGS} -Mbyteswapio")
set(ECBUILD_Fortran_FLAGS "${ECBUILD_Fortran_FLAGS} -Mstack_arrays")
set(ECBUILD_Fortran_FLAGS "${ECBUILD_Fortran_FLAGS} -Mrecursive")
set(ECBUILD_Fortran_FLAGS "${ECBUILD_Fortran_FLAGS} -Mfprelaxed -Mfprelaxed=intrinsic")
set(ECBUILD_Fortran_FLAGS "${ECBUILD_Fortran_FLAGS} -Mdaz")

set( ECBUILD_Fortran_FLAGS_BIT "-O2 -gopt" )

set( ECBUILD_C_FLAGS "-O2 -gopt -traceback" )

set( ECBUILD_CXX_FLAGS "-O2 -gopt" )
