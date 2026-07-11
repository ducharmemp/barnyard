#!/usr/bin/env bash
#
# Bench the postgres backend directly (no pooler in the middle).
set -euo pipefail

here=$(dirname "$0")
. "$here/env.sh"

exec "$here/matrix.sh" direct "$PG_PORT"
