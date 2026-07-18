# CLOUDSC Precision Study — SC2026 Workflow (ault)

Performance-focused runs on CSCS ault (A100 node `ault25`). Numerical
results for the paper are produced on daint (GH200); see
`SC2026_HOWTO.daint.md`. Default toolchain is spack-installed NVHPC 23.3
(FP16 works); the site NVHPC 21.3 install is offered as a shortcut but
its LLVM rejects the FP16 kernel.

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

Clone anywhere `ault25` can see — nothing in the scripts pins a path, they
locate themselves relative to the checkout. Outputs land in `build/` inside
the checkout and reach ~15 GB per `.h5` at 163840 columns, so pick a
filesystem with room (`$SCRATCH` is the obvious one).

```bash
git clone -b sc2026 https://github.com/pratyai/dwarf-p-cloudsc.git
cd dwarf-p-cloudsc
```

All subsequent commands assume you are in the `dwarf-p-cloudsc` directory.

### Cloudsc spack env (one-time)

No uenv on ault. Two arch dirs are shipped:

- `arch/cscs/ault/nvhpc/23.3/` — spack installs NVHPC 23.3 from the
  NVIDIA tarball (~4 GB fetch, ~1 h build). Handles FP16.
- `arch/cscs/ault/nvhpc/21.3/` — binds to the site install at
  `/opt/nvidia/hpc_sdk/Linux_x86_64/21.3/`. Instant setup, but its LLVM
  rejects the FP16 kernel (`invalid cast opcode for cast from 'i16' to
  'float'`), so FP32/FP64 only.

Use 23.3 unless you have a reason not to. Substitute `21.3` in every
command below if you want the shortcut.

```bash
spack env create cloudsc-gpu ./arch/cscs/ault/nvhpc/23.3/spack.yaml
spack -e cloudsc-gpu concretize
spack -e cloudsc-gpu install     # ~1 h first time for 23.3, ~30 min for 21.3
spack env activate cloudsc-gpu
```

### Python venv (one-time)

Ault has no `uv` and no `module` for it; system python is 3.6.8, too old
for the analysis scripts. Bootstrap uv first:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"     # add to shell rc too
```

Then create the venv:

```bash
uv python install 3.12
uv venv --python 3.12 --python-preference only-managed venv
source venv/bin/activate
uv pip install h5py polars numpy matplotlib
```

`--python-preference only-managed` is load-bearing: it points the venv at
a uv-downloaded interpreter under `~/.local/share/uv/python/`, which the
compute nodes can see. Without it the venv targets the login node's
python 3.12, and `ault25` only ships 3.6.

## Every login

```bash
export SPACK_TREE=$SCRATCH/spack-tree
export PATH="$HOME/.local/bin:$PATH"
source $SPACK_TREE/spack/share/spack/setup-env.sh
```

No uenv on ault, so that covers everything — every script below activates
`venv/` on its own, and finds the checkout relative to itself.

## 1. Build all precision variants

`build_all.sh` targets the daint arch by default. Override via env var:

```bash
ARCH=./arch/cscs/ault/nvhpc/23.3 ./build_all.sh
```

Builds FP16/FP32/FP64 under `build/bin/`. FP16 build only succeeds with
the 23.3 toolchain; the 21.3 fallback ICEs and dies before FP32/FP64,
so use `set +e` around the build or drop `--half-precision` from
`build_all.sh:91` if you're stuck on 21.3.

Binary: `build/bin/dwarf-cloudsc-gpu-scc-k-caching-multistep.{fp64,fp32,fp16}`

## 2. Run all configurations

Use the ault-header variant `run_all.ault.sh` (identical body to
`run_all.sh`, ault SBATCH block: `--partition=total`,
`--nodelist=ault25`, `--gres=gpu:a100:1`, no uenv).

```bash
sbatch run_all.ault.sh [--skip-existing] [--spinup N] [NSTEPS] [NPROMA] [TPHYS] [NSUB_COARSE] [NSUB_FINE]
# Defaults: NSTEPS=10, NPROMA=128, TPHYS=900.0, NSUB_COARSE=1, NSUB_FINE=2
# Paper canonical: pass 120.0 for TPHYS (see quick partial repro).
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

## 4. SASS + ncu

Same commands as daint (see `SC2026_HOWTO.daint.md` §4–5). The ncu batch
script `profile_all.sh` has no ault-header sibling yet — its SBATCH block
needs the same edit `run_all.ault.sh` got (`--partition=total`,
`--nodelist=ault25`, `--gres=gpu:a100:1`, drop the uenv lines).

## Key differences from daint

| Aspect | daint | ault |
|---|---|---|
| GPU | GH200 (cc90) | A100 (cc80) |
| NVHPC | 25.1 (via spack + uenv externals) | 23.3 (spack-built, default) / 21.3 (site) |
| CUDA | 12.6 (uenv) | 12.0 (bundled with NVHPC 23.3) / 11.2 (with 21.3) |
| Node runtime | `--uenv=icon/25.2:v1@santis --view=default` | none |
| Partition | `-p debug` (30 min) / longer | `-p total` (4 h), `--nodelist=ault25` |
| Account | `-A g34` | `-A g34` (kept for consistency) |
| FP16 | supported (paper baseline) | works on 23.3, broken on 21.3 |
| Grid sizes swept | 163840 x{1,2,4} by default | 40960 x{1,2,4}; 327680 OOMs at every precision on the 40 GB A100 |

## Troubleshooting

| Problem | Fix |
|---|---|
| Only 1 A100 node in the partition — job pending | `sinfo -p total -w ault25`; wait for the node to free. |
| `Corrupt or Old Module file hdf5.mod` | HDF5 built with wrong compiler. Recreate spack env; `spack.yaml` pins `%nvhpc@23.3` (or `@21.3`). |
| FP16 build ICEs (`NVFORTRAN-F-0000 Internal compiler error`) | Known 21.3 limitation. Skip FP16; use `--single-precision` and FP64 only. |
| `nvhpc external prefix does not exist` | Node doesn't have the NVHPC install mounted. Only `ault25` is guaranteed for GPU builds/runs. |

## Quick partial repro (perf only)

```bash
ARCH=./arch/cscs/ault/nvhpc/23.3 ./build_all.sh          # ~30 min
sbatch run_all.ault.sh --spinup 3 10 128 120.0 1 2       # ~20 min
./compare.sh 10 128 120.0 1 2                            # ~5 min
./report.sh --perf-only
```
