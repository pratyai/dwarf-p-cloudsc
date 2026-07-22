#!/bin/bash
#SBATCH --job-name=cloudsc-compare
#SBATCH --account=g34
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --time=01:00:00
#SBATCH --output=compare_%j.log

set -euo pipefail

# Compare CLOUDSC output files and produce a SQLite database + report.
# Takes the same arguments as run_all.sh so filenames are deterministic.
#
# Usage:
#   sbatch compare.sh [NSTEPS] [NPROMA] [TPHYS] [NSUB_COARSE] [NSUB_FINE]
#   Defaults: NSTEPS=10, NPROMA=128, TPHYS=900.0, NSUB_COARSE=1, NSUB_FINE=2

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BUILD="${SCRIPT_DIR}/build"
DB="${SCRIPT_DIR}/${CLOUDSC_DB:-cloudsc_results.db}"
COMPARE="${SCRIPT_DIR}/compare_precision.py"

NSTEPS=${1:-10}
NPROMA=${2:-128}
TPHYS=${3:-900.0}
NSUB_COARSE=${4:-1}
NSUB_FINE=${5:-2}

NGPTOTG_BASE=${NGPTOTG_BASE:-163840}
read -r -a GRID_MULTIPLIERS <<< "${GRID_MULTIPLIERS:-1 2 4}"
SPATIAL_NGPTOTG=40960

# --- Activate venv ---
if [ ! -f "${SCRIPT_DIR}/venv/bin/activate" ]; then
  echo "FATAL: venv not found at ${SCRIPT_DIR}/venv/" >&2
  exit 1
fi
source "${SCRIPT_DIR}/venv/bin/activate"

# --- Helper: file path for a given config ---
outfile() {
  local prec=$1 steps=$2 ngpt=$3 nsub=${4:-1}
  local base="${BUILD}/cloudsc_output_${prec}_${steps}steps_${ngpt}col"
  if [ "$nsub" -gt 1 ]; then
    # NSUB>1: try _137lev_nsubN.h5 first, then _nsubN.h5 (old format)
    local f="${base}_137lev_nsub${nsub}.h5"
    if [ -f "$f" ]; then echo "$f"; return; fi
    echo "${base}_nsub${nsub}.h5"
  else
    # NSUB=1: try _137lev.h5 first, then plain .h5
    local f="${base}_137lev.h5"
    if [ -f "$f" ]; then echo "$f"; return; fi
    echo "${base}.h5"
  fi
}

# --- Helper: check file exists ---
require() {
  if [ ! -f "$1" ]; then
    echo "MISSING: $1 (skipping)" >&2
    return 1
  fi
}

# --- Delete old DB so we start fresh ---
rm -f "${DB}"

# --- Ingest timing CSVs ---
echo "Ingesting timing data..."
for MULT in "${GRID_MULTIPLIERS[@]}"; do
  NGPTOTG=$((NGPTOTG_BASE * MULT))
  for prec in fp64 fp32 fp16; do
    for steps in ${NSTEPS}; do
      # Skip FP32/FP16 — they don't have nsub variants
      csv="${BUILD}/cloudsc_timing_${prec}_${steps}steps_${NGPTOTG}col_137lev.csv"
      [ -f "$csv" ] || csv="${BUILD}/cloudsc_timing_${prec}_${steps}steps_${NGPTOTG}col.csv"
      [ -f "$csv" ] || continue
      python -c "
import sqlite3, csv
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
with open('${csv}') as fh:
    reader = csv.DictReader(fh)
    for row in reader:
        def flt(k):
            v = row.get(k, '').strip()
            return float(v) if v else None
        conn.execute('INSERT INTO timing (precision,nsteps,ngptotg,nproma,step,wall_ms,kernel_ms,update_ms,d2h_ms) VALUES (?,?,?,?,?,?,?,?,?)',
            ('${prec}', ${steps}, ${NGPTOTG}, ${NPROMA}, row['step'].strip(), float(row['wall_ms']),
             flt('kernel_ms'), flt('update_ms'), flt('d2h_ms')))
conn.commit()
conn.close()
"
      echo "  ${prec} ${steps}steps ${NGPTOTG}col -> db"
    done
  done
done
echo ""

# --- Run comparisons in parallel ---
TMPDIR_CMP=$(mktemp -d "${SCRIPT_DIR}/.compare_tmp.XXXXXX")
PIDS=()
LABELS=()

run_compare() {
  local label=$1 ref_file=$2 test_file=$3
  local ref_prec=$4 ref_n=$5 test_prec=$6 test_n=$7 ngpt=$8
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

for MULT in "${GRID_MULTIPLIERS[@]}"; do
  NGPTOTG=$((NGPTOTG_BASE * MULT))
  BASELINE=$(outfile fp64 ${NSTEPS} ${NGPTOTG} ${NSUB_COARSE})
  require "${BASELINE}" || continue

  # Temporal refinement: NSUB_COARSE vs NSUB_FINE (same NSTEPS, FP64)
  FINE=$(outfile fp64 ${NSTEPS} ${NGPTOTG} ${NSUB_FINE})
  if require "${FINE}" 2>/dev/null; then
    run_compare "temporal_refine_nsub${NSUB_COARSE}vs${NSUB_FINE}_${NSTEPS}steps_${NGPTOTG}col" \
      "${BASELINE}" "${FINE}" fp64 ${NSTEPS} fp64 ${NSTEPS} ${NGPTOTG}
  fi

  # Precision: FP32 and FP16 vs FP64
  for prec in fp32 fp16; do
    TEST=$(outfile ${prec} ${NSTEPS} ${NGPTOTG} ${NSUB_COARSE})
    if require "${TEST}" 2>/dev/null; then
      run_compare "precision_fp64vs${prec#fp}_${NSTEPS}steps_${NGPTOTG}col" \
        "${BASELINE}" "${TEST}" fp64 ${NSTEPS} ${prec} ${NSTEPS} ${NGPTOTG}
    fi
  done
done

# --- Spatial refinement ---
# Config 1: KLEV=137, nsub=1 (coarse baseline — always nsub=1)
COARSE=$(outfile fp64 ${NSTEPS} ${SPATIAL_NGPTOTG} 1)

# Config 2: KLEV=274, nsub=1 (spatial only)
FINE_274="${BUILD}/cloudsc_output_fp64_${NSTEPS}steps_${SPATIAL_NGPTOTG}col_274lev.h5"

# Config 3: KLEV=274, nsub=2 (spatial + temporal)
FINE_274_NSUB2="${BUILD}/cloudsc_output_fp64_${NSTEPS}steps_${SPATIAL_NGPTOTG}col_274lev_nsub2.h5"

# Compare 1 vs 2: spatial refinement only
if require "${COARSE}" 2>/dev/null && require "${FINE_274}" 2>/dev/null; then
  RESTRICTED="${BUILD}/cloudsc_output_fp64_2xklev_restricted_${NSTEPS}steps_${SPATIAL_NGPTOTG}col.h5"
  LABEL="spatial_refine_klev137vs274_${SPATIAL_NGPTOTG}col"
  TMPDB="${TMPDIR_CMP}/${LABEL}.db"

  echo "  Launching: ${LABEL} (restrict + compare)"
  (
    python "${SCRIPT_DIR}/vertical_refine.py" restrict "${FINE_274}" "${RESTRICTED}" --klev-coarse 137
    python "${COMPARE}" \
      --label "${LABEL}" \
      --ref-precision fp64 --ref-nsteps "${NSTEPS}" \
      --test-precision fp64 --test-nsteps "${NSTEPS}" \
      --db "${TMPDB}" --ngptotg "${SPATIAL_NGPTOTG}" --nproma "${NPROMA}" \
      "${COARSE}" "${RESTRICTED}"
  ) &
  PIDS+=($!)
  LABELS+=("${LABEL}")
fi

# Compare 1 vs 3: spatial + temporal refinement
if require "${COARSE}" 2>/dev/null && require "${FINE_274_NSUB2}" 2>/dev/null; then
  RESTRICTED_NSUB2="${BUILD}/cloudsc_output_fp64_2xklev_restricted_nsub2_${NSTEPS}steps_${SPATIAL_NGPTOTG}col.h5"
  LABEL="spatial_temporal_refine_klev274_nsub2_${SPATIAL_NGPTOTG}col"
  TMPDB="${TMPDIR_CMP}/${LABEL}.db"

  echo "  Launching: ${LABEL} (restrict + compare)"
  (
    python "${SCRIPT_DIR}/vertical_refine.py" restrict "${FINE_274_NSUB2}" "${RESTRICTED_NSUB2}" --klev-coarse 137
    python "${COMPARE}" \
      --label "${LABEL}" \
      --ref-precision fp64 --ref-nsteps "${NSTEPS}" \
      --test-precision fp64 --test-nsteps "${NSTEPS}" \
      --db "${TMPDB}" --ngptotg "${SPATIAL_NGPTOTG}" --nproma "${NPROMA}" \
      "${COARSE}" "${RESTRICTED_NSUB2}"
  ) &
  PIDS+=($!)
  LABELS+=("${LABEL}")
fi

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
import sqlite3, glob

main = sqlite3.connect('${DB}')
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

rm -rf "${TMPDIR_CMP}"

# --- Report ---
echo ""
if [ ${NERRORS} -gt 0 ]; then
  echo "WARNING: ${NERRORS} comparison(s) failed" >&2
fi

echo "Results written to: ${DB}"
echo ""
python "${SCRIPT_DIR}/report.py" --db "${DB}"
