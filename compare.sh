#!/bin/bash
set -euo pipefail

# Auto-discover CLOUDSC HDF5 output files and run all comparisons.
# Writes aggregated stats to a SQLite database, then runs the reporter.
#
# Expects files produced by run_all.sh in build/:
#   cloudsc_output_fp64_{N}steps.h5      (baseline)
#   cloudsc_output_fp64_{2N}steps.h5     (temporal refinement)
#   cloudsc_output_fp64_{N/2}steps.h5    (temporal coarsening)
#   cloudsc_output_fp32_{N}steps.h5      (single precision)
#
# Usage:
#   ./compare.sh [NGPTOTG] [NPROMA]
#   Defaults: NGPTOTG=163840, NPROMA=128

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${SCRIPT_DIR}/build"
DB="${SCRIPT_DIR}/cloudsc_results.db"

NGPTOTG=${1:-163840}
NPROMA=${2:-128}

# --- Activate venv ---
if [ ! -f "${SCRIPT_DIR}/venv/bin/activate" ]; then
  echo "FATAL: venv not found at ${SCRIPT_DIR}/venv/" >&2
  echo "  Run:  uv venv --python 3.12 venv && source venv/bin/activate && uv pip install h5py polars numpy" >&2
  exit 1
fi
source "${SCRIPT_DIR}/venv/bin/activate"

# --- Discover HDF5 files ---
echo "Scanning ${BUILD}/ for CLOUDSC output files..."

# Find all output files and extract their (precision, nsteps) pairs
declare -A FILES  # key="fp64_10" value="/path/to/file.h5"
FP64_STEPS=()
FP32_STEPS=()
FP16_STEPS=()

for f in ${BUILD}/cloudsc_output_*.h5; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  if [[ "$base" =~ cloudsc_output_(fp[0-9]+)_([0-9]+)steps\.h5 ]]; then
    prec="${BASH_REMATCH[1]}"
    nsteps="${BASH_REMATCH[2]}"
    FILES["${prec}_${nsteps}"]="$f"
    if [ "$prec" = "fp64" ]; then
      FP64_STEPS+=("$nsteps")
    elif [ "$prec" = "fp32" ]; then
      FP32_STEPS+=("$nsteps")
    elif [ "$prec" = "fp16" ]; then
      FP16_STEPS+=("$nsteps")
    fi
  else
    echo "WARNING: Unexpected filename format: $base (skipping)" >&2
  fi
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "FATAL: No cloudsc_output_*.h5 files found in ${BUILD}/" >&2
  echo "  Run run_all.sh first." >&2
  exit 1
fi

# Sort FP64 steps to find baseline (middle value)
IFS=$'\n' FP64_SORTED=($(printf '%s\n' "${FP64_STEPS[@]}" | sort -n)); unset IFS

echo "Found files:"
for key in $(echo "${!FILES[@]}" | tr ' ' '\n' | sort); do
  echo "  ${key} -> $(basename ${FILES[$key]})"
done
echo ""

if [ ${#FP64_SORTED[@]} -lt 1 ]; then
  echo "FATAL: No FP64 output files found" >&2
  exit 1
fi

# Identify baseline: if there are 3 FP64 runs, baseline is the middle one.
# If only 1, that's the baseline.
if [ ${#FP64_SORTED[@]} -ge 3 ]; then
  MID=$(( ${#FP64_SORTED[@]} / 2 ))
  BASELINE_STEPS=${FP64_SORTED[$MID]}
elif [ ${#FP64_SORTED[@]} -eq 2 ]; then
  # Take the smaller as baseline
  BASELINE_STEPS=${FP64_SORTED[0]}
else
  BASELINE_STEPS=${FP64_SORTED[0]}
fi

BASELINE="fp64_${BASELINE_STEPS}"
if [ -z "${FILES[$BASELINE]+x}" ]; then
  echo "FATAL: Baseline file not found for ${BASELINE}" >&2
  exit 1
fi

echo "Baseline: FP64 ${BASELINE_STEPS} steps (${FILES[$BASELINE]})"
echo ""

# --- Delete old DB so we start fresh each time ---
rm -f "${DB}"

# --- Ingest timing CSVs ---
echo "Ingesting timing data..."
for f in ${BUILD}/cloudsc_timing_*.csv; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  if [[ "$base" =~ cloudsc_timing_(fp[0-9]+)_([0-9]+)steps\.csv ]]; then
    prec="${BASH_REMATCH[1]}"
    nsteps="${BASH_REMATCH[2]}"
    python -c "
import sqlite3, csv, sys
conn = sqlite3.connect('${DB}')
conn.execute('''CREATE TABLE IF NOT EXISTS timing (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    precision TEXT NOT NULL,
    nsteps    INTEGER NOT NULL,
    ngptotg   INTEGER NOT NULL,
    nproma    INTEGER NOT NULL,
    step      TEXT NOT NULL,
    wall_ms   REAL NOT NULL
)''')
with open('${f}') as fh:
    reader = csv.DictReader(fh)
    for row in reader:
        conn.execute('INSERT INTO timing (precision,nsteps,ngptotg,nproma,step,wall_ms) VALUES (?,?,?,?,?,?)',
            ('${prec}', ${nsteps}, ${NGPTOTG}, ${NPROMA}, row['step'].strip(), float(row['wall_ms'])))
conn.commit()
conn.close()
"
    echo "  ${base} -> db"
  fi
done
echo ""

# --- Run comparisons ---
COMMON="--db ${DB} --ngptotg ${NGPTOTG} --nproma ${NPROMA}"
COMPARE="${SCRIPT_DIR}/compare_precision.py"
NERRORS=0

run_compare() {
  local label=$1
  local ref_key=$2
  local test_key=$3

  local ref_file="${FILES[$ref_key]}"
  local test_file="${FILES[$test_key]}"

  # Parse precision and nsteps from key
  local ref_prec="${ref_key%%_*}"
  local ref_n="${ref_key#*_}"
  local test_prec="${test_key%%_*}"
  local test_n="${test_key#*_}"

  echo "============================================"
  echo "  ${label}"
  echo "  ref:  ${ref_key} -> $(basename ${ref_file})"
  echo "  test: ${test_key} -> $(basename ${test_file})"
  echo "============================================"

  python "${COMPARE}" \
    --label "${label}" \
    --ref-precision "${ref_prec}" --ref-nsteps "${ref_n}" \
    --test-precision "${test_prec}" --test-nsteps "${test_n}" \
    ${COMMON} \
    "${ref_file}" "${test_file}" || {
      echo "ERROR: Comparison '${label}' failed" >&2
      NERRORS=$((NERRORS + 1))
    }
  echo ""
}

# Compare FP64 baseline against all other FP64 step counts (temporal)
for nsteps in "${FP64_SORTED[@]}"; do
  [ "$nsteps" = "$BASELINE_STEPS" ] && continue
  key="fp64_${nsteps}"
  if [ "$nsteps" -gt "$BASELINE_STEPS" ]; then
    run_compare "temporal_refine_${BASELINE_STEPS}vs${nsteps}" \
      "${BASELINE}" "${key}"
  else
    run_compare "temporal_coarsen_${BASELINE_STEPS}vs${nsteps}" \
      "${BASELINE}" "${key}"
  fi
done

# Compare FP64 baseline against all FP32 runs (precision)
for nsteps in "${FP32_STEPS[@]}"; do
  key="fp32_${nsteps}"
  run_compare "precision_fp64vs32_${nsteps}steps" \
    "${BASELINE}" "${key}"
done

# Compare FP64 baseline against all FP16 runs (precision)
if [ ${#FP16_STEPS[@]} -gt 0 ]; then
  for nsteps in "${FP16_STEPS[@]}"; do
    key="fp16_${nsteps}"
    run_compare "precision_fp64vs16_${nsteps}steps" \
      "${BASELINE}" "${key}"
  done
fi

# --- Report ---
echo ""
if [ ${NERRORS} -gt 0 ]; then
  echo "WARNING: ${NERRORS} comparison(s) failed" >&2
fi

echo "Results written to: ${DB}"
echo ""

# Run reporter
python "${SCRIPT_DIR}/report.py" --db "${DB}"
