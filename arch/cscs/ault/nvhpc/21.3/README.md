# CLOUDSC GPU (SCC k-caching) on CSCS ault (A100)

Build and run the `dwarf-cloudsc-gpu-scc-k-caching` variant on the ault
A100 node (ault25) with NVHPC 21.3.

## Prerequisites

- ault account with SLURM allocation (e.g. `-A g34`).
- Site-provided NVHPC install at `/opt/nvidia/hpc_sdk/Linux_x86_64/21.3/`
  (loaded via `module load nvhpc/21.3`, spack externals in this dir's
  `spack.yaml` bind to that path directly).

## 1. Spack setup (one-time)

Two clones, spack proper + packages repo. Pick any location; `$SCRATCH`
on ault resolves to `/scratch/$USER` and works fine.

```bash
export SPACK_TREE=$SCRATCH/spack-tree
mkdir -p $SPACK_TREE && cd $SPACK_TREE

git clone --depth=1 https://github.com/spack/spack.git
git clone --depth=1 https://github.com/spack/spack-packages.git

source $SPACK_TREE/spack/share/spack/setup-env.sh
spack repo remove builtin 2>/dev/null || true
spack repo add $SPACK_TREE/spack-packages/repos/spack_repo/builtin
```

Add the `source` + `spack repo add` lines to your shell rc.

## 2. Clone the repository

Anywhere `ault25` can see, with room for the `build/` outputs.

```bash
git clone -b sc2026 https://github.com/pratyai/dwarf-p-cloudsc.git
cd dwarf-p-cloudsc
```

## 3. Cloudsc spack env (one-time)

No uenv on ault. NVHPC lives at a fixed site path (`/opt/nvidia/...`), so
plain login-shell spack is enough — no wrapping required.

```bash
spack env create cloudsc-gpu ./arch/cscs/ault/nvhpc/21.3/spack.yaml
spack -e cloudsc-gpu concretize
spack -e cloudsc-gpu install     # ~30 min first time
spack env activate cloudsc-gpu
```

## 4. Build CLOUDSC

### FP64 (default)

```bash
spack env activate cloudsc-gpu
source ./arch/cscs/ault/nvhpc/21.3/env.sh
./cloudsc-bundle create
./cloudsc-bundle build --clean --with-gpu \
    --arch=./arch/cscs/ault/nvhpc/21.3 \
    --cloudsc-prototype1=OFF
```

### FP32

Add `--single-precision` to the `cloudsc-bundle build` line.

### FP16

`build_all.sh` builds all three, but FP16 on ault + NVHPC 21.3 has not
been validated and may ICE. Treat as best-effort.

To make `build_all.sh` target this arch dir:

```bash
ARCH=./arch/cscs/ault/nvhpc/21.3 ./build_all.sh
```

## 5. Run

Only the A100 node (`ault25`) can run the GPU binary. Request it
explicitly.

```
dwarf-cloudsc-gpu-scc-k-caching  NUMOMP  NGPTOTG  NPROMA
```

### Interactive

```bash
cd build
srun -A g34 -p total -w ault25 --gres=gpu:a100:1 \
     -n1 -t 5 \
     bin/dwarf-cloudsc-gpu-scc-k-caching 1 163840 128
```

### Batch

```bash
sbatch <<'EOF'
#!/bin/bash
#SBATCH --job-name=cloudsc-kcache
#SBATCH --account=g34
#SBATCH --partition=total
#SBATCH --nodelist=ault25
#SBATCH --gres=gpu:a100:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:05:00
srun bin/dwarf-cloudsc-gpu-scc-k-caching 1 163840 128
EOF
```

`total` partition caps at 4 h wall time.

## Troubleshooting

| Problem | Fix |
|---|---|
| `OpenMP not found` | `env.sh` not sourced. |
| `Corrupt or Old Module file hdf5.mod` | HDF5 built with wrong compiler. Recreate spack env; `spack.yaml` pins `%nvhpc@21.3`. |
| `nvhpc external prefix does not exist` | `/opt/nvidia/hpc_sdk/Linux_x86_64/21.3/` missing on this node. Check `module avail nvhpc`. |
| `ptxas … sm_80 unsupported` | CUDA toolkit too old for A100 target. `spack.yaml` picks the nvhpc-bundled CUDA 11.2, which supports sm_80. Confirm `nvcc --version` inside the env. |
