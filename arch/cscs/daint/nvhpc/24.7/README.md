# CLOUDSC GPU (SCC k-caching) on CSCS Alps/Daint (GH200)

From-scratch guide to build and run the `dwarf-cloudsc-gpu-scc-k-caching` variant.

## Prerequisites

- Access to Daint with SLURM account (e.g. `-A g34`)
- Spack installed and available (i.e. `source /path/to/spack/share/spack/setup-env.sh` in your shell)

## 1. Clone the repository

```bash
git clone https://github.com/ecmwf-ifs/dwarf-p-cloudsc.git
cd dwarf-p-cloudsc
```

## 2. Set up the spack environment

This installs NVHPC 24.7, CMake, and HDF5 (built with nvfortran so `.mod` files are compatible).

```bash
spack env create cloudsc-gpu ./arch/cscs/daint/nvhpc/24.7/spack.yaml
spack env activate cloudsc-gpu
spack concretize
spack install
```

> **Note:** `spack install` can take a while (30+ min) the first time, especially for NVHPC and HDF5.
> If you hit a stale patch error (e.g. `berkeley-db`), run:
> ```bash
> spack concretize --force
> spack install
> ```

## 3. Build CLOUDSC

### FP64 (default)

```bash
spack env activate cloudsc-gpu
source ./arch/cscs/daint/nvhpc/24.7/env.sh
./cloudsc-bundle create
./cloudsc-bundle build --clean --with-gpu \
    --arch=./arch/cscs/daint/nvhpc/24.7 \
    --cloudsc-prototype1=OFF
```

### FP32 (single precision)

```bash
spack env activate cloudsc-gpu
source ./arch/cscs/daint/nvhpc/24.7/env.sh
./cloudsc-bundle create
./cloudsc-bundle build --clean --with-gpu --single-precision \
    --arch=./arch/cscs/daint/nvhpc/24.7 \
    --cloudsc-prototype1=OFF
```

> **How precision works:** All physics variables use `REAL(KIND=JPRB)` where `JPRB` is
> controlled by the `SINGLE` preprocessor macro. FP64 uses `SELECTED_REAL_KIND(13,300)`,
> FP32 uses `SELECTED_REAL_KIND(6,37)`. The `--single-precision` flag sets this globally.
> Physical constants, thermodynamic functions, and the kernel itself all follow `JPRB` —
> there are no hardcoded precisions in the compute path.
> FP16 (half precision) is **not supported** — Fortran has no native half-precision kind,
> and the physics (pressure, temperature ranges) would overflow/underflow IEEE FP16.

## 4. Run

The binary takes three positional arguments:

```
dwarf-cloudsc-gpu-scc-k-caching  NUMOMP  NGPTOTG  NPROMA
```

| Argument | Description | Default |
|---|---|---|
| `NUMOMP` | Number of OpenMP threads (0 = auto-detect) | 1 |
| `NGPTOTG` | Total number of columns (grid points) globally | 16384 |
| `NPROMA` | Block size for array blocking | 64 (GPU) |

### Interactive (quick test)

```bash
cd build
srun -A g34 --constraint=gpu --gres=gpu:1 -n1 -t 5 \
    bin/dwarf-cloudsc-gpu-scc-k-caching 1 163840 128
```

### Batch job

```bash
cd build
sbatch <<'EOF'
#!/bin/bash
#SBATCH --job-name=cloudsc-kcache
#SBATCH --account=g34
#SBATCH --constraint=gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:05:00

srun bin/dwarf-cloudsc-gpu-scc-k-caching 1 163840 128
EOF
```

> **Important:** Run from the `build/` directory — the binary expects `input.h5` and
> `reference.h5` there (symlinked from `config-files/`). If missing:
> ```bash
> ln -sf $(pwd)/../config-files/input.h5 input.h5
> ln -sf $(pwd)/../config-files/reference.h5 reference.h5
> ```

## 5. Validation and comparing versions

After the kernel runs, the binary automatically validates computed results against
pre-stored reference data (`reference.h5`). For each output variable it reports:

- Min/max of the computed field
- Maximum absolute error vs. reference
- Average absolute error per grid point
- Relative error percentage
- A `!!!!` warning if relative error exceeds `10 * machine_epsilon`

This is how you compare FP64 vs FP32: build both, run with the same arguments, and
compare the validation error output. Both builds validate against the **same FP64
reference data** in `reference.h5`.

### Limitations

- **No runtime output serialization.** The code does not write computed results to
  disk. It only reads input data and reference data, then prints validation statistics
  to stdout. There is no flag to dump intermediate fields.
- **No Serialbox write support** in the GPU variants. The prototype1 code had
  `fs_write_field` calls for generating the input/reference data from the full IFS,
  but this is not exposed in any of the modern dwarf variants.
- To actually serialize output for external comparison (e.g. bit-for-bit checks between
  GPU variants), you would need to add HDF5 or binary write calls to the driver code.

## 6. Controlling problem size

### What you CAN control (runtime)

- **Number of columns (`NGPTOTG`)**: Second CLI argument. Can be any value — the code
  replicates the 100-column input data cyclically via `expand_mod.F90`. Use this to
  scale the workload (e.g. 1000, 163840, 1000000).
- **Block size (`NPROMA`)**: Third CLI argument. Controls the inner blocking dimension.
  Typical GPU values: 32, 64, 128.
- **OpenMP threads (`NUMOMP`)**: First CLI argument.
- **MPI ranks**: Build with `--with-mpi`, then use `mpirun -np N`. Columns are
  distributed across ranks.

### What you CANNOT control (baked into input data)

- **Vertical levels (`KLEV`)**: Fixed at **137 levels**, read from `input.h5`.
  Changing this requires regenerating the input data from the full IFS.
- **Physics timestep (`PTSPHY`)**: Read from `input.h5`, not configurable at runtime.
  Changing it requires modifying the input data.
- **Number of timesteps**: The dwarf runs **exactly one timestep**. There is no time
  loop — the kernel is called once. This is by design (it's a computational dwarf/kernel
  extract, not a full model).
- **Horizontal resolution / grid spacing**: Does not exist in the dwarf. Columns are
  independent; there is no spatial coupling. `NGPTOTG` controls the number of columns
  but they are all replicas of the same 100-column input dataset.

### Summary

| Parameter | Controllable? | How |
|---|---|---|
| Number of columns | Yes | CLI arg 2 (`NGPTOTG`) |
| Block size | Yes | CLI arg 3 (`NPROMA`) |
| OpenMP threads | Yes | CLI arg 1 (`NUMOMP`) |
| MPI parallelism | Yes | Build `--with-mpi`, use `mpirun` |
| Precision (FP64/FP32) | Yes | Build flag `--single-precision` |
| Vertical levels (137) | No | Baked into `input.h5` |
| Physics timestep | No | Baked into `input.h5` |
| Number of timesteps | No | Hardcoded to 1 |
| Horizontal resolution | N/A | No spatial grid, columns are independent |

## Troubleshooting

| Problem | Fix |
|---|---|
| `OpenMP not found` | The toolchain sets `OpenMP_acchost_LIBRARY` via `find_library`. Make sure `env.sh` was sourced (it adds NVHPC lib paths). |
| `Corrupt or Old Module file hdf5.mod` | HDF5 was built with gcc, not nvhpc. Recreate spack env — `spack.yaml` forces `%nvhpc@24.7` on HDF5. |
| `NVFORTRAN-F-0000 Internal compiler error` in prototype1 | Known NVHPC 24.7 bug. Pass `--cloudsc-prototype1=OFF` to the build. |
| `No such file or directory: input.h5` | Run from the `build/` directory, or create symlinks (see above). |

## Other GPU variants

`--with-gpu` enables all SCC variants. After building, you'll also have:

```
bin/dwarf-cloudsc-gpu-scc              # basic SCC
bin/dwarf-cloudsc-gpu-scc-hoist        # SCC with hoisted temporaries
bin/dwarf-cloudsc-gpu-scc-stack        # SCC with pool allocator
bin/dwarf-cloudsc-gpu-scc-k-caching    # SCC with loop fusion + k-caching (this guide)
bin/dwarf-cloudsc-gpu-omp-scc          # OpenMP target offload variants
bin/dwarf-cloudsc-gpu-omp-scc-hoist
bin/dwarf-cloudsc-gpu-omp-scc-stack
bin/dwarf-cloudsc-gpu-omp-scc-k-caching
```
