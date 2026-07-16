# CLOUDSC GPU (SCC k-caching) on CSCS Alps/Daint (GH200)

Build and run the `dwarf-cloudsc-gpu-scc-k-caching` variant with NVHPC 25.1.

## Prerequisites

- Daint account with SLURM allocation (e.g. `-A g34`).
- Access to the `icon/25.2:v1@santis` uenv view (provides CUDA, NVHPC, GCC,
  HDF5 hashes referenced by the spack externals in this dir's `spack.yaml`).
- Spack and its packages repo cloned somewhere on scratch.

## 1. Spack setup (one-time)

Spack proper and its package definitions live in two separate repositories.
Choose any location — `$SPACK_TREE` below is an example. `$SCRATCH` on
CSCS Alps is `/capstor/scratch/cscs/$USER` (purge-eligible fast tier;
fine for spack, don't keep anything unique there).

```bash
export SPACK_TREE=$SCRATCH/spack-tree
mkdir -p $SPACK_TREE && cd $SPACK_TREE

git clone --depth=1 https://github.com/spack/spack.git
git clone --depth=1 https://github.com/spack/spack-packages.git

source $SPACK_TREE/spack/share/spack/setup-env.sh
spack repo remove builtin 2>/dev/null || true   # drop any stale user-scoped entry
spack repo add $SPACK_TREE/spack-packages/repos/spack_repo/builtin
```

Add the two `source` and `repo add` lines to your shell rc for future
sessions.

## 2. Clone the repository

```bash
git clone <this-repo> dwarf-p-cloudsc
cd dwarf-p-cloudsc
```

## 3. Create the spack environment

```bash
spack env create cloudsc-gpu ./arch/cscs/daint/nvhpc/25.1/spack.yaml
spack -e cloudsc-gpu concretize
spack -e cloudsc-gpu install
```

First install: ~30 min (HDF5 with nvfortran).

The externals in `spack.yaml` bind to uenv paths, so all `spack install`
commands must run inside a shell where the uenv is active — either
`uenv run --view=default icon/25.2:v1@santis <cmd>`, or from an `sbatch`
script with `#SBATCH --uenv=icon/25.2:v1@santis` + `#SBATCH --view=default`
headers.

## 4. Build CLOUDSC

### FP64 (default)

```bash
spack env activate cloudsc-gpu
source ./arch/cscs/daint/nvhpc/25.1/env.sh
./cloudsc-bundle create
./cloudsc-bundle build --clean --with-gpu \
    --arch=./arch/cscs/daint/nvhpc/25.1 \
    --cloudsc-prototype1=OFF
```

### FP32

Add `--single-precision` to the `cloudsc-bundle build` line. Everything
else identical.

`build_all.sh` in the repo root builds FP16/FP32/FP64 in one shot.

## 5. Run

```
dwarf-cloudsc-gpu-scc-k-caching  NUMOMP  NGPTOTG  NPROMA
```

| Arg | Meaning | Typical |
|---|---|---|
| `NUMOMP` | OpenMP threads (0 = auto) | 1 |
| `NGPTOTG` | Total columns | 16384–655360 |
| `NPROMA` | Block size | 128 |

### Interactive

```bash
cd build
srun -A g34 --uenv=icon/25.2:v1@santis --view=default \
     --constraint=gpu --gres=gpu:1 -n1 -t 5 \
     bin/dwarf-cloudsc-gpu-scc-k-caching 1 163840 128
```

`sbatch` submitted from an already-active uenv shell is blocked
(`libslurm-uenv-mount rc=-3000`). Submit from a plain login shell with
`#SBATCH --uenv=` / `#SBATCH --view=` headers in the script.

Run from `build/` — the binary expects `input.h5` / `reference.h5` there.

## 6. Validation

The binary auto-validates against `reference.h5` and prints per-variable
error stats. FP32 build validates against the same FP64 reference — that's
how you read precision loss.

For multi-step, external-comparison workflows (Zenodo A2 artifact), see
`SC2026_HOWTO.daint.md` in the repo root.

## Troubleshooting

| Problem | Fix |
|---|---|
| `OpenMP not found` | `env.sh` not sourced — it wires the NVHPC lib paths CMake needs. |
| `Corrupt or Old Module file hdf5.mod` | HDF5 was built with a non-nvhpc compiler. Recreate spack env; `spack.yaml` pins `%nvhpc@25.1`. |
| `nvhpc external prefix does not exist` | uenv not active. Wrap the command in `uenv run --view=default icon/25.2:v1@santis ...`. |
| `Requested time limit is invalid` on srun | Debug partition caps at 30 min; use `--time=00:30:00` or a longer partition. |
