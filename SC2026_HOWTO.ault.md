# CLOUDSC Precision Study — SC2026 Workflow (ault)

Performance-focused runs on CSCS ault (A100 node `ault25`, NVHPC 21.3).
Numerical results for the paper are produced on daint (GH200); see
`SC2026_HOWTO.daint.md`. FP16 on this platform is best-effort — the
CLOUDSC FP16 path is fragile and NVHPC 21.3 may ICE it.

## Prerequisites

### Spack (one-time)

Spack and its packages repo live in two clones. Pick any location; the
example below uses `$SCRATCH` (on ault this resolves to
`/scratch/$USER` — plenty of space, but expect it to be scrubbed after
long inactivity; don't keep unique work there).

```bash
export SPACK_TREE=$SCRATCH/spack-tree
mkdir -p $SPACK_TREE && cd $SPACK_TREE
git clone --depth=1 https://github.com/spack/spack.git
git clone --depth=1 https://github.com/spack/spack-packages.git

source $SPACK_TREE/spack/share/spack/setup-env.sh
spack repo remove builtin 2>/dev/null || true   # drop any stale user-scoped entry
spack repo add $SPACK_TREE/spack-packages/repos/spack_repo/builtin
```

Add the `source` + `spack repo add` lines to your shell rc.

A site-wide spack lives at `/apps/ault/spack/` if you prefer to reuse it;
the recipe below assumes a fresh clone for reproducibility.

### Clone this repo (one-time)

```bash
cd $SCRATCH
git clone -b sc2026 https://github.com/pratyai/dwarf-p-cloudsc.git
cd dwarf-p-cloudsc
```

All subsequent commands assume you are in the `dwarf-p-cloudsc` directory.

### Cloudsc spack env (one-time)

No uenv on ault. NVHPC lives at a fixed site path
(`/opt/nvidia/hpc_sdk/Linux_x86_64/21.3/`), so plain login-shell spack is
enough.

```bash
spack env create cloudsc-gpu ./arch/cscs/ault/nvhpc/21.3/spack.yaml
spack -e cloudsc-gpu concretize
spack -e cloudsc-gpu install     # ~30 min first time
spack env activate cloudsc-gpu
```

### Python venv (one-time)

```bash
uv venv --python 3.12 venv
source venv/bin/activate
uv pip install h5py polars numpy matplotlib
```

## 1. Build all precision variants

`build_all.sh` targets the daint arch by default. Override via env var:

```bash
ARCH=./arch/cscs/ault/nvhpc/21.3 ./build_all.sh
```

Builds FP16/FP32/FP64 under `build/bin/`. FP16 may fail — proceed to
FP64/FP32 only if that happens.

Binary: `build/bin/dwarf-cloudsc-gpu-scc-k-caching-multistep.{fp64,fp32,fp16}`

## 2. Run all configurations

`run_all.sh` on ault needs its SBATCH headers adjusted (partition,
nodelist, no uenv). Copy and edit before use:

```bash
cp run_all.sh run_all.ault.sh
# In run_all.ault.sh, replace the SBATCH block with:
#   #SBATCH --job-name=cloudsc-runs
#   #SBATCH --account=g34
#   #SBATCH --partition=total
#   #SBATCH --nodelist=ault25
#   #SBATCH --gres=gpu:a100:1
#   #SBATCH --nodes=1
#   #SBATCH --ntasks=1
#   #SBATCH --exclusive
#   #SBATCH --time=02:00:00
#   #SBATCH --output=run_all_%j.log

sbatch run_all.ault.sh [--skip-existing] [--spinup N] [NSTEPS] [NPROMA] [TPHYS] [NSUB_COARSE] [NSUB_FINE]
# Defaults: NSTEPS=10, NPROMA=128, TPHYS=120.0, NSUB_COARSE=1, NSUB_FINE=2
```

Flags:
- `--skip-existing` — skip runs whose output files already exist
- `--spinup N` — run N FP64 warmup steps to move the state off the IFS
  analysis onto the forward-Euler attractor. Creates
  `config-files/input_spunup.h5` via `make_spunup_input.py`.

Outputs land in `build/`:
- `cloudsc_output_{prec}_{N}steps_{G}col_{K}lev[_nsubM].h5`
- `cloudsc_timing_{prec}_{N}steps_{G}col_{K}lev[_nsubM].csv`

`total` partition caps at 4 h wall time.

## 3. Compare and report

```bash
./compare.sh [NSTEPS] [NPROMA] [TPHYS] [NSUB_COARSE] [NSUB_FINE]
./report.sh
```

Same as daint; see `SC2026_HOWTO.daint.md` for the full DB / query
reference. Results land in `cloudsc_results.db`.

## 4. Plots, SASS, ncu

Same commands as daint (see `SC2026_HOWTO.daint.md` §4–6). The ncu batch
script `profile_all.sh` needs its SBATCH block edited the same way as
`run_all.sh`.

## Key differences from daint

| Aspect | daint | ault |
|---|---|---|
| GPU | GH200 (cc90) | A100 (cc80) |
| NVHPC | 25.1 (via spack + uenv externals) | 21.3 (site install at `/opt/nvidia`) |
| CUDA | 12.6 (uenv) | 11.2 (bundled with NVHPC 21.3) |
| Node runtime | `--uenv=icon/25.2:v1@santis --view=default` | none |
| Partition | `-p debug` (30 min) / longer | `-p total` (4 h), `--nodelist=ault25` |
| Account | `-A g34` | `-A g34` (kept for consistency) |
| FP16 | supported (paper baseline) | best-effort |

## Troubleshooting

| Problem | Fix |
|---|---|
| Only 1 A100 node in the partition — job pending | `sinfo -p total -w ault25`; wait for the node to free. |
| `Corrupt or Old Module file hdf5.mod` | HDF5 built with wrong compiler. Recreate spack env; `spack.yaml` pins `%nvhpc@21.3`. |
| FP16 build ICEs (`NVFORTRAN-F-0000 Internal compiler error`) | Known 21.3 limitation. Skip FP16; use `--single-precision` and FP64 only. |
| `nvhpc external prefix does not exist` | Node doesn't have the NVHPC install mounted. Only `ault25` is guaranteed for GPU builds/runs. |

## Quick partial repro (perf only)

```bash
ARCH=./arch/cscs/ault/nvhpc/21.3 ./build_all.sh          # ~30 min
sbatch run_all.ault.sh --spinup 3 10 128 120.0 1 2       # ~20 min (only FP64/FP32 will be measured if FP16 build failed)
./compare.sh 10 128 120.0 1 2                            # ~5 min
./report.sh --perf-only
```
