#!/bin/bash
#SBATCH --job-name=cloudsc-compare
#SBATCH --account=g34
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --time=01:00:00
#SBATCH --output=compare_%j.log

set -euo pipefail

# Auto-discover CLOUDSC HDF5 output files and run all comparisons.
# Writes aggregated stats to a SQLite database, then runs the reporter.
#
# Expects files produced by run_all.sh in build/:
#   cloudsc_output_{prec}_{N}steps_{G}col.h5
#
# Grid sizes and precisions are auto-discovered from filenames.
# Comparisons run in parallel; results are merged into a single DB.
#
# Usage:
#   sbatch compare.sh [NPROMA]
#   Default: NPROMA=128

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BUILD="${SCRIPT_DIR}/build"
DB="${SCRIPT_DIR}/cloudsc_results.db"

NPROMA=${1:-128}

# --- Activate venv ---
if [ ! -f "${SCRIPT_DIR}/venv/bin/activate" ]; then
  echo "FATAL: venv not found at ${SCRIPT_DIR}/venv/" >&2
  echo "  Run:  uv venv --python 3.12 venv && source venv/bin/activate && uv pip install h5py polars numpy" >&2
  exit 1
fi
source "${SCRIPT_DIR}/venv/bin/activate"

# --- Discover HDF5 files ---
echo "Scanning ${BUILD}/ for CLOUDSC output files..."

declare -A FILES  # key="fp64_10_163840" value="/path/to/file.h5"
declare -A GRIDS  # unique ngptotg values

for f in ${BUILD}/cloudsc_output_*.h5; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  if [[ "$base" =~ cloudsc_output_(fp[0-9]+)_([0-9]+)steps_([0-9]+)col\.h5 ]]; then
    prec="${BASH_REMATCH[1]}"
    nsteps="${BASH_REMATCH[2]}"
    ngpt="${BASH_REMATCH[3]}"
    FILES["${prec}_${nsteps}_${ngpt}"]="$f"
    GRIDS["${ngpt}"]=1
  elif [[ "$base" =~ cloudsc_output_(fp[0-9]+)_([0-9]+)steps\.h5 ]]; then
    # Legacy format (no col suffix) — assume base grid
    prec="${BASH_REMATCH[1]}"
    nsteps="${BASH_REMATCH[2]}"
    FILES["${prec}_${nsteps}_163840"]="$f"
    GRIDS["163840"]=1
  else
    echo "WARNING: Unexpected filename format: $base (skipping)" >&2
  fi
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "FATAL: No cloudsc_output_*.h5 files found in ${BUILD}/" >&2
  echo "  Run run_all.sh first." >&2
  exit 1
fi

IFS=$'\n' GRID_SIZES=($(printf '%s\n' "${!GRIDS[@]}" | sort -n)); unset IFS

echo "Found files:"
for key in $(echo "${!FILES[@]}" | tr ' ' '\n' | sort); do
  echo "  ${key} -> $(basename ${FILES[$key]})"
done
echo ""
echo "Grid sizes: ${GRID_SIZES[*]}"
echo ""

# --- Delete old DB so we start fresh each time ---
rm -f "${DB}"

# --- Ingest timing CSVs ---
echo "Ingesting timing data..."
for f in ${BUILD}/cloudsc_timing_*.csv; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  if [[ "$base" =~ cloudsc_timing_(fp[0-9]+)_([0-9]+)steps_([0-9]+)col\.csv ]]; then
    prec="${BASH_REMATCH[1]}"
    nsteps="${BASH_REMATCH[2]}"
    ngpt="${BASH_REMATCH[3]}"
  elif [[ "$base" =~ cloudsc_timing_(fp[0-9]+)_([0-9]+)steps\.csv ]]; then
    prec="${BASH_REMATCH[1]}"
    nsteps="${BASH_REMATCH[2]}"
    ngpt="163840"
  else
    continue
  fi
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
    wall_ms   REAL NOT NULL,
    kernel_ms REAL,
    update_ms REAL,
    d2h_ms    REAL
)''')
with open('${f}') as fh:
    reader = csv.DictReader(fh)
    for row in reader:
        def flt(k):
            v = row.get(k, '').strip()
            return float(v) if v else None
        conn.execute('INSERT INTO timing (precision,nsteps,ngptotg,nproma,step,wall_ms,kernel_ms,update_ms,d2h_ms) VALUES (?,?,?,?,?,?,?,?,?)',
            ('${prec}', ${nsteps}, ${ngpt}, ${NPROMA}, row['step'].strip(), float(row['wall_ms']),
             flt('kernel_ms'), flt('update_ms'), flt('d2h_ms')))
conn.commit()
conn.close()
"
  echo "  ${base} -> db"
done
echo ""

# --- Run comparisons in parallel ---
COMPARE="${SCRIPT_DIR}/compare_precision.py"
TMPDIR_CMP=$(mktemp -d "${SCRIPT_DIR}/.compare_tmp.XXXXXX")
PIDS=()
LABELS=()

run_compare() {
  local label=$1
  local ref_key=$2
  local test_key=$3
  local ngpt=$4

  local ref_file="${FILES[$ref_key]}"
  local test_file="${FILES[$test_key]}"

  local ref_prec="${ref_key%%_*}"
  local ref_rest="${ref_key#*_}"; local ref_n="${ref_rest%%_*}"
  local test_prec="${test_key%%_*}"
  local test_rest="${test_key#*_}"; local test_n="${test_rest%%_*}"

  # Each comparison gets its own temp DB to avoid SQLite write contention
  local tmpdb="${TMPDIR_CMP}/${label}.db"

  echo "  Launching: ${label}"

  python "${COMPARE}" \
    --label "${label}" \
    --ref-precision "${ref_prec}" --ref-nsteps "${ref_n}" \
    --test-precision "${test_prec}" --test-nsteps "${test_n}" \
    --db "${tmpdb}" --ngptotg "${ngpt}" --nproma "${NPROMA}" \
    "${ref_file}" "${test_file}" &

  PIDS+=($!)
  LABELS+=("${label}")
}

echo "Scheduling comparisons..."

for NGPT in "${GRID_SIZES[@]}"; do
  # Collect FP64 step counts for this grid
  FP64_STEPS_G=()
  for key in "${!FILES[@]}"; do
    if [[ "$key" =~ ^fp64_([0-9]+)_${NGPT}$ ]]; then
      FP64_STEPS_G+=("${BASH_REMATCH[1]}")
    fi
  done

  [ ${#FP64_STEPS_G[@]} -eq 0 ] && continue

  IFS=$'\n' FP64_SORTED_G=($(printf '%s\n' "${FP64_STEPS_G[@]}" | sort -n)); unset IFS

  BASELINE_STEPS=${FP64_SORTED_G[0]}
  BASELINE_KEY="fp64_${BASELINE_STEPS}_${NGPT}"

  # Temporal refinement
  for nsteps in "${FP64_SORTED_G[@]}"; do
    [ "$nsteps" = "$BASELINE_STEPS" ] && continue
    if [ "$nsteps" -gt "$BASELINE_STEPS" ]; then
      key="fp64_${nsteps}_${NGPT}"
      run_compare "temporal_refine_${BASELINE_STEPS}vs${nsteps}_${NGPT}col" \
        "${BASELINE_KEY}" "${key}" "${NGPT}"
    fi
  done

  # Precision
  for prec in fp32 fp16; do
    key="${prec}_${BASELINE_STEPS}_${NGPT}"
    if [ -n "${FILES[$key]+x}" ]; then
      run_compare "precision_fp64vs${prec#fp}_${BASELINE_STEPS}steps_${NGPT}col" \
        "${BASELINE_KEY}" "${key}" "${NGPT}"
    fi
  done
done

echo ""
echo "Waiting for ${#PIDS[@]} comparisons..."
NERRORS=0
for i in "${!PIDS[@]}"; do
  if ! wait "${PIDS[$i]}"; then
    echo "ERROR: ${LABELS[$i]} failed" >&2
    NERRORS=$((NERRORS + 1))
  else
    echo "  Done: ${LABELS[$i]}"
  fi
done

# --- Merge per-comparison DBs into main DB ---
echo ""
echo "Merging results..."
python -c "
import sqlite3, glob, sys

main = sqlite3.connect('${DB}')

# Ensure schema exists (main DB may only have timing table)
main.executescript('''
CREATE TABLE IF NOT EXISTS comparisons (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp     TEXT    NOT NULL,
    label         TEXT,
    ref_file      TEXT    NOT NULL,
    test_file     TEXT    NOT NULL,
    ref_precision TEXT,
    test_precision TEXT,
    ref_nsteps    INTEGER,
    test_nsteps   INTEGER,
    ngptotg       INTEGER,
    nproma        INTEGER,
    notes         TEXT
);
CREATE TABLE IF NOT EXISTS step_stats (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    comparison_id   INTEGER NOT NULL REFERENCES comparisons(id),
    step            INTEGER NOT NULL,
    variable        TEXT    NOT NULL,
    max_abs_err     REAL,
    mean_abs_err    REAL,
    max_rel_err     REAL,
    mean_rel_err    REAL,
    power_snr_db    REAL,
    var_snr_db      REAL,
    ref_min         REAL,
    ref_max         REAL,
    ref_mean        REAL,
    test_min        REAL,
    test_max        REAL,
    test_mean       REAL
);
''')

for tmpdb_path in sorted(glob.glob('${TMPDIR_CMP}/*.db')):
    tmp = sqlite3.connect(tmpdb_path)
    tmp.row_factory = sqlite3.Row

    # Copy comparisons and remap IDs
    for comp in tmp.execute('SELECT * FROM comparisons').fetchall():
        new_id = main.execute(
            '''INSERT INTO comparisons
               (timestamp, label, ref_file, test_file, ref_precision, test_precision,
                ref_nsteps, test_nsteps, ngptotg, nproma, notes)
               VALUES (?,?,?,?,?,?,?,?,?,?,?)''',
            (comp['timestamp'], comp['label'], comp['ref_file'], comp['test_file'],
             comp['ref_precision'], comp['test_precision'],
             comp['ref_nsteps'], comp['test_nsteps'],
             comp['ngptotg'], comp['nproma'], comp['notes'])
        ).lastrowid

        for stat in tmp.execute('SELECT * FROM step_stats WHERE comparison_id=?', (comp['id'],)).fetchall():
            main.execute(
                '''INSERT INTO step_stats
                   (comparison_id, step, variable, max_abs_err, mean_abs_err,
                    max_rel_err, mean_rel_err, power_snr_db, var_snr_db,
                    ref_min, ref_max, ref_mean, test_min, test_max, test_mean)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
                (new_id, stat['step'], stat['variable'],
                 stat['max_abs_err'], stat['mean_abs_err'],
                 stat['max_rel_err'], stat['mean_rel_err'],
                 stat['power_snr_db'], stat['var_snr_db'],
                 stat['ref_min'], stat['ref_max'], stat['ref_mean'],
                 stat['test_min'], stat['test_max'], stat['test_mean']))

    tmp.close()

main.commit()
main.close()
print(f'Merged {len(glob.glob(\"${TMPDIR_CMP}/*.db\"))} comparison DBs')
"

# Clean up temp DBs
rm -rf "${TMPDIR_CMP}"

# --- Report ---
echo ""
if [ ${NERRORS} -gt 0 ]; then
  echo "WARNING: ${NERRORS} comparison(s) failed" >&2
fi

echo "Results written to: ${DB}"
echo ""

python "${SCRIPT_DIR}/report.py" --db "${DB}"
