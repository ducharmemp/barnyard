#!/usr/bin/env bash
#
# CPU-profile barnyard under sustained pgbench load. Records with perf and
# leaves perf.data plus a text report in $OUT_DIR/profile/. Expects an
# unstripped binary at out/barnyard (see `just profile`).
#
# Usage: profile.sh [threads]
set -euo pipefail

here=$(dirname "$0")
. "$here/env.sh"

threads=${1:-4}
work="$OUT_DIR/profile"
mkdir -p "$work"

export BARNYARD_PORT
export BARNYARD_POOL="$POOL_SIZE"
./out/barnyard --ponymaxthreads="$threads" >"$work/barnyard.log" 2>&1 &
barnyard=$!

stop() {
  kill "$barnyard" 2>/dev/null || true
  wait "$barnyard" 2>/dev/null || true
}
trap stop EXIT

wait_ready "$BARNYARD_PORT" "barnyard@$threads"

jobs=$(( PROFILE_CONCURRENCY < 8 ? PROFILE_CONCURRENCY : 8 ))
echo ">> profiling barnyard@$threads for ${PROFILE_DURATION}s under c$PROFILE_CONCURRENCY $PROFILE_MODE load…" >&2
pgbench -h "$PGHOST" -p "$BARNYARD_PORT" -U "$PGUSER" -d "$PGDATABASE" \
  -n -c "$PROFILE_CONCURRENCY" -j "$jobs" -T "$PROFILE_DURATION" -S -M "$PROFILE_MODE" \
  >"$work/pgbench.log" 2>&1 &
load=$!

perf record --call-graph dwarf -p "$barnyard" -o "$work/perf.data" -- sleep "$PROFILE_DURATION"
wait "$load"

perf report --stdio --percent-limit 1 -i "$work/perf.data" > "$work/report.txt"
perf script -i "$work/perf.data" | inferno-collapse-perf | inferno-flamegraph > "$work/flame.svg"

echo
head -60 "$work/report.txt"
echo
echo ">> load results:  $work/pgbench.log"
echo ">> full report:   $work/report.txt"
echo ">> flamegraph:    $work/flame.svg"
echo ">> interactive:   perf report -i $work/perf.data"
