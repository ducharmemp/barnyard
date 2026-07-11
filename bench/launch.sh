#!/usr/bin/env bash
#
# Start a target in the background, bench it with matrix.sh, kill it after.
# The target's output lands in $OUT_DIR/<label>.log.
#
# Usage: launch.sh <label> <port> <command...>
set -euo pipefail

here=$(dirname "$0")
. "$here/env.sh"

label=${1:?usage: launch.sh <label> <port> <command...>}
port=${2:?usage: launch.sh <label> <port> <command...>}
shift 2

mkdir -p "$OUT_DIR"
"$@" >"$OUT_DIR/$label.log" 2>&1 &
pid=$!

stop() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
trap stop EXIT

"$here/matrix.sh" "$label" "$port"
