#!/usr/bin/env bash
#
# Run the pgbench matrix (MODES x CONCURRENCIES) against one target and write
# one row per cell to $OUT_DIR/<label>.tsv: mode conc tps lat. Waits for the
# target to answer on <port> before benching.
#
# Usage: matrix.sh <label> <port>
set -euo pipefail

here=$(dirname "$0")
. "$here/env.sh"

label=${1:?usage: matrix.sh <label> <port>}
port=${2:?usage: matrix.sh <label> <port>}

pg() {
  pgbench -h "$PGHOST" -p "$port" -U "$PGUSER" -d "$PGDATABASE" "$@"
}

number_after() { # e.g. `number_after "tps"` pulls 123.45 out of "tps = 123.45"
  grep -oE "$1 = [0-9.]+" | grep -oE '[0-9.]+' | head -1 || true
}

bench_cell() { # prints one TSV row on stdout, progress on stderr
  local mode=$1 conc=$2 jobs out tps lat
  jobs=$(( conc < 8 ? conc : 8 ))
  out=$(pg -n -c "$conc" -j "$jobs" -T "$DURATION" -S -M "$mode")
  tps=$(number_after "tps" <<<"$out")
  lat=$(number_after "latency average" <<<"$out")
  if [ -n "$tps" ]; then
    tps=$(printf '%.0f' "$tps")   # whole tps; fractions are noise
  fi
  printf '%s\t%s\t%s\t%s\n' "$mode" "$conc" "${tps:--}" "${lat:--}"
  printf '   %-11s %-9s c%-3s tps=%-12s lat=%s ms\n' "$label" "$mode" "$conc" "${tps:--}" "${lat:--}" >&2
}

mkdir -p "$OUT_DIR"
wait_ready "$port" "$label"

echo ">> warming $label (${WARMUP}s)…" >&2
pg -n -c 8 -j 8 -T "$WARMUP" -S >/dev/null 2>&1 || true

for mode in $MODES; do
  for conc in $CONCURRENCIES; do
    bench_cell "$mode" "$conc"
  done
done > "$OUT_DIR/$label.tsv"
