#!/bin/bash
set -euo pipefail

# Report on CLOUDSC comparison results from the SQLite database.
#
# Usage:
#   ./report.sh                          # full report
#   ./report.sh -c 2                     # single comparison
#   ./report.sh -q "SELECT * FROM ..."   # arbitrary SQL query

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${SCRIPT_DIR}/cloudsc_results.db"

if [ ! -f "${SCRIPT_DIR}/venv/bin/activate" ]; then
  echo "FATAL: venv not found at ${SCRIPT_DIR}/venv/" >&2
  echo "  Run:  uv venv --python 3.12 venv && source venv/bin/activate && uv pip install h5py polars numpy" >&2
  exit 1
fi
source "${SCRIPT_DIR}/venv/bin/activate"

if [ ! -f "${DB}" ]; then
  echo "FATAL: Database not found: ${DB}" >&2
  echo "  Run compare.sh first to generate it." >&2
  exit 1
fi

python "${SCRIPT_DIR}/report.py" --db "${DB}" "$@"
