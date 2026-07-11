#!/usr/bin/env bash
#
# Bench barnyard at a given --ponymaxthreads. Scheduler threads and the ASIO
# thread are pinned to cores so run-to-run scheduler/core migration doesn't
# masquerade as signal. Expects out/barnyard to exist (see `just release`).
#
# Usage: barnyard.sh [threads]
set -euo pipefail

here=$(dirname "$0")
. "$here/env.sh"

threads=${1:-4}

export BARNYARD_PORT
export BARNYARD_POOL="$POOL_SIZE"
exec "$here/launch.sh" "barnyard@$threads" "$BARNYARD_PORT" \
  ./out/barnyard --ponymaxthreads="$threads" --ponypin --ponypinasio
