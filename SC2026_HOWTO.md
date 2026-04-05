# CLOUDSC Precision Study — SC2026 Workflow

How to reproduce the results for the SC2026 paper. Everything runs on
CSCS Daint (GH200 nodes, NVHPC 24.7).

## Prerequisites

```bash
# Spack environment (one-time)
spack env activate cloudsc-gpu

# Python venv (one-time)
uv venv --python 3.12 venv
source venv/bin/activate
uv pip install h5py polars numpy
```

## 1. Build all precision variants

```bash
./build_all.sh
```

Builds FP16, FP16r, FP32, FP64 binaries under `build/bin/`. Also extracts
SASS dumps to `ptx/{fp64,fp32,fp16,fp16r}/cloudsc.sass`.

Binary: `build/bin/dwarf-cloudsc-gpu-scc-k-caching-multistep.{fp64,fp32,fp16,fp16r}`

## 2. Run all configurations

```bash
sbatch run_all.sh [NSTEPS] [NPROMA] [TPHYS]
# Defaults: NSTEPS=10, NPROMA=128, TPHYS=900.0
```

Runs each precision at 3 grid sizes (1x, 2x, 4x of 163840 columns), plus
FP64 at 2x timesteps for temporal refinement. At the end, runs the spatial
refinement pair (KLEV=137 vs KLEV=274, FP64, TPHYS=120, 40960 columns).

Outputs land in `build/`:
- `cloudsc_output_{prec}_{N}steps_{G}col_{K}lev.h5`
- `cloudsc_timing_{prec}_{N}steps_{G}col_{K}lev.csv`

### Spatial refinement standalone (optional)

If you only want to rerun the spatial part:

```bash
sbatch run_spatial_refine.sh [NSTEPS] [NPROMA] [TPHYS] [NGPTOTG]
# Defaults: NSTEPS=10, NPROMA=128, TPHYS=900.0, NGPTOTG=163840
```

This generates `input_2xklev.h5` if missing, runs coarse + fine, restricts,
compares, and appends to `cloudsc_results.db`.

## 3. Compare and report

```bash
sbatch compare.sh [NPROMA]
# Default: NPROMA=128
```

Auto-discovers all output files, ingests timing CSVs, runs all
precision/temporal comparisons in parallel, and also handles spatial
refinement (restricts 274-level outputs, compares against 137-level).
Results go into `cloudsc_results.db`. Calls `report.py` at the end.

### Report only (no recomputation)

```bash
./report.sh                    # full report
./report.sh --perf-only        # timing tables only
./report.sh --snr-only         # SNR/accuracy tables only
./report.sh -c 3               # single comparison by ID
./report.sh -q "SELECT ..."    # arbitrary SQL query
```

## 4. SASS instruction analysis

```bash
./sass_stats.sh [ptx]
```

Prints instruction mix table (FP64/FP32/FP16 arithmetic, MUFU special
functions, F2F format conversions, total instructions) per precision.

## Key files

| File | Purpose |
|---|---|
| `build_all.sh` | Build 4 precision binaries + extract SASS |
| `run_all.sh` | Run all configs (precision, temporal, spatial) |
| `run_spatial_refine.sh` | Standalone spatial refinement run |
| `compare.sh` | All comparisons + DB ingest + report |
| `compare_precision.py` | Core comparison engine (HDF5 → SQLite) |
| `report.py` | Read DB and print formatted tables |
| `report.sh` | Convenience wrapper for report.py |
| `vertical_refine.py` | `refine` (KLEV→2xKLEV) and `restrict` (2xKLEV→KLEV) |
| `sass_stats.sh` | SASS instruction mix summary |
| `latex_table.py` | Generate LaTeX tables from DB |
| `cloudsc_results.db` | SQLite database with all results |

## Database schema

**`timing`** — per-step kernel timing (wall, kernel, update, d2h in ms)

**`comparisons`** — metadata for each comparison (label, precisions, nsteps, grid size)

**`step_stats`** — per-step per-variable error metrics (max/mean abs/rel error, power SNR, variance SNR)

Variance SNR is the primary accuracy metric: `10*log10(var(ref) / var(ref-test))`.

## Important details

- **TPHYS=900s** is the default (IFS T511 physics timestep). TCo1279 uses 450s.
- **Spatial refinement uses TPHYS=120s** because KLEV=274 + TPHYS=900 diverges at step 9.
- **NV_ACC_CUDA_STACKSIZE=131072** is required for KLEV=274 GPU runs.
- **CLOUDSC_INPUT env var** selects the input file (without `.h5` extension). Default: `input`.
  Set to `input_2xklev` for the refined 274-level input.
- **`input_2xklev.h5`** is generated on-the-fly (not committed to git — too large).
  It's created in `config-files/` and symlinked into `build/`.
- Output filenames include KLEV: `cloudsc_output_fp64_10steps_163840col_137lev.h5`.
  `compare.sh` skips non-137lev files for precision/temporal comparisons; spatial
  comparisons are handled separately.
- **Variance SNR vs Power SNR**: Power SNR is inflated for fields with large means
  (PT ~232K gives a ~20dB artificial boost). Always use variance SNR.

## Quick full repro

```bash
./build_all.sh                  # ~30 min
sbatch run_all.sh               # ~20 min (includes spatial)
# wait for job to finish
sbatch compare.sh               # ~5 min
# wait for job to finish
./report.sh                     # instant
./sass_stats.sh                 # instant
```
