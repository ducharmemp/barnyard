#!/usr/bin/env bash
#
# Render the per-target files in $OUT_DIR as side-by-side throughput and
# latency tables. Rows come from the first target's file; columns are the
# targets in the order they were benched (file modification time).
set -euo pipefail

here=$(dirname "$0")
. "$here/env.sh"

cd "$OUT_DIR"

targets=$(ls -tr *.tsv 2>/dev/null | sed 's/\.tsv$//')
if [ -z "$targets" ]; then
  echo "no results in $OUT_DIR — run 'just bench' first" >&2
  exit 1
fi
first=$(echo "$targets" | head -1)

value_for() {
  local target=$1 mode=$2 conc=$3 column=$4
  awk -v m="$mode" -v c="$conc" -v col="$column" \
    '$1 == m && $2 == c { print $col; exit }' "$target.tsv"
}

table() {
  local column=$1 title=$2 unit=$3 target mode conc value

  echo
  echo "=== $title  ($unit) ==="
  {
    printf 'mode\tconc'
    for target in $targets; do
      printf '\t%s' "$target"
    done
    echo

    while IFS=$'\t' read -r mode conc _; do
      printf '%s\tc%s' "$mode" "$conc"
      for target in $targets; do
        value=$(value_for "$target" "$mode" "$conc" "$column")
        printf '\t%s' "${value:--}"
      done
      echo
    done < "$first.tsv"
  } | column -t -s "$(printf '\t')"
}

table 3 THROUGHPUT tps
table 4 LATENCY "avg ms"
echo
