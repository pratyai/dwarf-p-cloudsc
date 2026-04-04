#!/bin/bash
# Print SASS instruction mix for each CLOUDSC precision variant.
# Usage: ./sass_stats.sh [SASS_DIR]
# Default: SASS_DIR=ptx

set -euo pipefail

DIR="${1:-ptx}"

printf "%-6s  %6s  %6s  %6s  %6s  %6s  %6s\n" \
       "prec" "FP64" "FP32" "FP16" "MUFU" "F2F" "total"
printf "%s\n" "------  ------  ------  ------  ------  ------  ------"

for p in fp64 fp32 fp16r fp16; do
  f="${DIR}/${p}/cloudsc.sass"
  [ -f "$f" ] || continue
  fp64=$(grep -cE 'DADD|DMUL|DFMA' "$f" || true)
  fp32=$(grep -cE 'FADD|FMUL|FFMA' "$f" || true)
  fp16=$(grep -cE 'HADD|HMUL|HFMA' "$f" || true)
  mufu=$(grep -cE 'MUFU' "$f" || true)
  f2f=$(grep -cE 'F2F' "$f" || true)
  total=$(wc -l < "$f")
  printf "%-6s  %6d  %6d  %6d  %6d  %6d  %6d\n" \
         "$p" "$fp64" "$fp32" "$fp16" "$mufu" "$f2f" "$total"
done
