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
uv pip install h5py polars numpy matplotlib
```

## 1. Build all precision variants

```bash
./build_all.sh
```

Builds FP16, FP32, FP64 binaries under `build/bin/`. Also extracts
SASS dumps to `ptx/{fp64,fp32,fp16}/cloudsc.sass`.

Binary: `build/bin/dwarf-cloudsc-gpu-scc-k-caching-multistep.{fp64,fp32,fp16}`

Note: `build_all.sh` preserves any existing `.h5`/`.csv` output files
across `--clean` rebuilds.

## 2. Run all configurations

```bash
sbatch run_all.sh [--skip-existing] [--spinup N] [NSTEPS] [NPROMA] [TPHYS] [NSUB_COARSE] [NSUB_FINE]
# Defaults: NSTEPS=10, NPROMA=128, TPHYS=120.0, NSUB_COARSE=1, NSUB_FINE=2
```

Flags:
- `--skip-existing` — skip runs whose output files already exist
- `--spinup N` — run N FP64 warmup steps to move the state off the IFS
  analysis onto the forward-Euler attractor (eliminates step-1 transient).
  Creates `config-files/input_spunup.h5` via `make_spunup_input.py`.

Runs each precision at 3 grid sizes (1x, 2x, 4x of 163840 columns), plus
temporal refinement (NSUB_COARSE vs NSUB_FINE at same NSTEPS). Then runs
3 spatial refinement configs (KLEV=137 nsub=1, KLEV=274 nsub=1, KLEV=274
nsub=2) at TPHYS=120, 40960 columns.

Outputs land in `build/`:
- `cloudsc_output_{prec}_{N}steps_{G}col_{K}lev[_nsubM].h5`
- `cloudsc_timing_{prec}_{N}steps_{G}col_{K}lev[_nsubM].csv`

## 3. Compare and report

```bash
./compare.sh [NSTEPS] [NPROMA] [TPHYS] [NSUB_COARSE] [NSUB_FINE]
# Same defaults as run_all.sh
```

Takes the same positional args as `run_all.sh`. Ingests timing CSVs, runs
precision/temporal/spatial comparisons in parallel, and writes results to
`cloudsc_results.db`. Calls `report.py` at the end.

### Report only (no recomputation)

```bash
./report.sh                    # full report
./report.sh --perf-only        # timing tables only
./report.sh --snr-only         # SNR/accuracy tables only
./report.sh -c 3               # single comparison by ID
./report.sh -q "SELECT ..."    # arbitrary SQL query
```

## 4. Plots

```bash
python plot_snr.py             # SNR evolution per field/grid → figs/snr_evolution.pdf
python plot_timing.py          # kernel timing plots → figs/timing.pdf
```

## 5. SASS instruction analysis

```bash
./sass_stats.sh [ptx]
```

Prints instruction mix table (FP64/FP32/FP16 arithmetic, MUFU special
functions, F2F format conversions, total instructions) per precision.

## 6. GPU profiling (ncu)

```bash
sbatch profile_all.sh [NSTEPS] [NPROMA] [TPHYS]
# Defaults: NSTEPS=2, NPROMA=128, TPHYS=120.0
```

Profiles all precisions at 3 grid sizes with Nsight Compute. Reports
go to `profile/cloudsc.{fp64,fp32,fp16}.{1x,2x,4x}.ncu-rep`.

## 7. Querying the results database

All results live in `cloudsc_results.db`. Useful queries:

```bash
# List all comparisons
sqlite3 cloudsc_results.db "SELECT id, label, ngptotg FROM comparisons"

# Per-field SNR at a specific step (e.g. p=2) for FP32
sqlite3 cloudsc_results.db "
  SELECT s.variable, ROUND(s.var_snr_db, 1) AS snr
  FROM step_stats s JOIN comparisons c ON s.comparison_id = c.id
  WHERE c.label = 'precision_fp64vs32_10steps_163840col' AND s.step = 2
  ORDER BY s.variable"

# SNR evolution (all steps) for a comparison
sqlite3 cloudsc_results.db "
  SELECT s.step, s.variable, ROUND(s.var_snr_db, 1) AS snr
  FROM step_stats s JOIN comparisons c ON s.comparison_id = c.id
  WHERE c.label = 'precision_fp64vs32_10steps_163840col' AND s.step >= 1
  ORDER BY s.variable, s.step"

# Temporal discretization noise floor
sqlite3 cloudsc_results.db "
  SELECT s.variable, ROUND(s.var_snr_db, 1) AS snr
  FROM step_stats s JOIN comparisons c ON s.comparison_id = c.id
  WHERE c.label = 'temporal_refine_nsub1vs2_10steps_163840col' AND s.step = 2
  ORDER BY s.variable"

# Spatial discretization noise floor
sqlite3 cloudsc_results.db "
  SELECT s.variable, ROUND(s.var_snr_db, 1) AS snr
  FROM step_stats s JOIN comparisons c ON s.comparison_id = c.id
  WHERE c.label = 'spatial_refine_klev137vs274_40960col' AND s.step = 2
  ORDER BY s.variable"

# Kernel timing per step
sqlite3 cloudsc_results.db "
  SELECT step, precision, ROUND(kernel_ms, 2), ROUND(update_ms, 2)
  FROM timing
  WHERE ngptotg = 163840 AND step > 0
  ORDER BY precision, step"
```

## Key files

| File | Purpose |
|---|---|
| `build_all.sh` | Build 3 precision binaries + extract SASS |
| `run_all.sh` | Run all configs (precision, temporal, spatial, spinup) |
| `compare.sh` | All comparisons + DB ingest + report |
| `compare_precision.py` | Core comparison engine (HDF5 → SQLite) |
| `report.py` | Read DB and print formatted tables |
| `report.sh` | Convenience wrapper for report.py |
| `vertical_refine.py` | `refine` (KLEV→2xKLEV) and `restrict` (2xKLEV→KLEV) |
| `make_spunup_input.py` | Extract spun-up state from FP64 output → new input file |
| `plot_snr.py` | SNR evolution plotter (multi-page PDF) |
| `plot_timing.py` | Kernel timing plotter |
| `profile_all.sh` | ncu profiling across grids and precisions |
| `sass_stats.sh` | SASS instruction mix summary |
| `cloudsc_results.db` | SQLite database with all results |

## Database schema

**`timing`** — per-step kernel timing (wall, kernel, update, d2h in ms)

**`comparisons`** — metadata for each comparison (label, precisions, nsteps, grid size)

**`step_stats`** — per-step per-variable error metrics (max/mean abs/rel error, power SNR, variance SNR)

Variance SNR is the primary accuracy metric: `10*log10(var(ref) / var(ref-test))`.

## Important details

- **TPHYS=120s** is the recommended timestep. TPHYS=900 causes odd/even
  oscillation in SNR due to frozen B_TMP forcing, and KLEV=274 diverges
  at TPHYS=900. TPHYS=120 gives clean monotonic decay.
- **Spinup (--spinup 3)**: the IFS analysis initial condition is not on the
  forward-Euler attractor, causing a step-1 transient. Running 3 FP64
  spinup steps eliminates this. The spun-up state is saved to
  `config-files/input_spunup.h5` and reused by all grid-loop runs.
- **NSUB sub-substeps**: each outer step p is subdivided into NSUB kernel
  calls with `dt_inner = dt_sub/NSUB`. Temporal refinement compares
  NSUB_COARSE vs NSUB_FINE at the same NSTEPS, making each step's error
  independent.
- **NV_ACC_CUDA_STACKSIZE=131072** is required for KLEV=274 GPU runs.
- **CLOUDSC_INPUT env var** selects the input file (without `.h5` extension).
  Default: `input`. Set to `input_2xklev` for 274-level, `input_spunup`
  for spun-up initial condition.
- **Generated files** (not committed): `input_2xklev.h5`, `input_spunup.h5`,
  `figs/`, `profile/`. All are regenerated by the scripts.
- **Variance SNR vs Power SNR**: Power SNR is inflated for fields with large
  means (PT ~232K gives a ~20dB artificial boost). Always use variance SNR.

## Quick full repro

```bash
./build_all.sh                                     # ~30 min
sbatch run_all.sh --spinup 3 10 128 120.0 1 2      # ~20 min
# wait for job to finish
./compare.sh 10 128 120.0 1 2                      # ~5 min
./report.sh                                        # instant
python plot_snr.py                                 # instant
./sass_stats.sh                                    # instant
```
