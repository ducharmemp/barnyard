#!/usr/bin/env bash
#
# Single-shot pooler benchmark: barnyard vs direct postgres vs pgbouncer vs pgcat.
#
# Runs a read-only pgbench SELECT matrix (concurrency x query mode) against each
# target in turn and prints a tabular tps/latency report.
#
# Targets are benchmarked ONE AT A TIME on purpose: each pooler holds up to
# POOL_SIZE backend connections, and postgres max_connections is 100, so running
# them concurrently would exhaust the connection budget. Sequential runs also
# free the budget for the direct c64 case.
#
# Requirements: run inside the project's nix dev shell (direnv). It provides
# pgbench, psql, corral, ponyc, and the pgbouncer/pgcat pooler binaries. A
# missing pooler is skipped (its column is omitted) rather than fatal.
#
# Config via env (all optional):
#   PG_PORT (5432) POOL_SIZE (64) DURATION (8s) WARMUP (2s)
#   CONCURRENCIES ("1 8 16 32 64")  MODES ("simple extended")
#   BARNYARD_THREADS ("2 4 8")  -- sweep --ponymaxthreads, one column each
#   SKIP_BUILD (unset)  -- reuse existing out/barnyard
#
set -uo pipefail

PGHOST=${PGHOST:-127.0.0.1}
PGUSER=${PGUSER:-postgres}
PGDATABASE=${PGDATABASE:-postgres}
export PGPASSWORD=${PGPASSWORD:-postgres}     # trust/ok poolers ignore it; pgcat needs it
export PGCONNECT_TIMEOUT=3
export PSQLRC=/dev/null                        # avoid a verbose ~/.psqlrc

PG_PORT=${PG_PORT:-5432}
BARNYARD_PORT_=${BARNYARD_PORT_:-7669}
PGBOUNCER_PORT=${PGBOUNCER_PORT:-6432}
PGCAT_PORT=${PGCAT_PORT:-6433}

POOL_SIZE=${POOL_SIZE:-64}
DURATION=${DURATION:-8}
WARMUP=${WARMUP:-2}
read -r -a CONCURRENCIES <<<"${CONCURRENCIES:-1 8 16 32 64}"
read -r -a MODES <<<"${MODES:-simple extended}"
read -r -a BARNYARD_THREADS <<<"${BARNYARD_THREADS:-2 4 8}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"

declare -A R          # results: R["tps,<label>,<mode>,<conc>"] / R["lat,..."]
declare -a LABELS     # target labels actually benchmarked, in order
BARNYARD_PID="" ; POOLER_PID=""

log()  { printf '>> %s\n' "$*" >&2; }
warn() { printf '!! %s\n' "$*" >&2; }

cleanup() {
  [ -n "$POOLER_PID" ]   && kill "$POOLER_PID"   2>/dev/null
  [ -n "$BARNYARD_PID" ] && kill "$BARNYARD_PID" 2>/dev/null
  pgrep -x barnyard | xargs -r kill 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null || { warn "missing '$1' — run inside 'nix develop'"; exit 1; }; }
need pgbench ; need psql

# Pooler binaries come from the dev shell (see flake.nix developerPackages).
PGBOUNCER_BIN="$(command -v pgbouncer || true)"
PGCAT_BIN="$(command -v pgcat || true)"
[ -z "$PGBOUNCER_BIN" ] && warn "pgbouncer not on PATH — skipping (add it to flake.nix / 'nix develop')"
[ -z "$PGCAT_BIN" ]     && warn "pgcat not on PATH — skipping (add it to flake.nix / 'nix develop')"

# Build barnyard unless told to reuse.
if [ -z "${SKIP_BUILD:-}" ]; then
  log "building barnyard (release)…"
  ( cd "$ROOT" && just release ) >/dev/null 2>&1 || { warn "build failed"; exit 1; }
fi
[ -x "$ROOT/out/barnyard" ] || { warn "no out/barnyard binary"; exit 1; }

wait_ready() { # port
  for _ in $(seq 1 30); do
    [ "$(psql -h "$PGHOST" -p "$1" -U "$PGUSER" -d "$PGDATABASE" -tAc 'select 1' 2>/dev/null)" = 1 ] && return 0
    sleep 0.5
  done
  return 1
}

run_matrix() { # label port
  local label=$1 port=$2 mode conc j out tps lat
  LABELS+=("$label")
  log "warming $label (${WARMUP}s)…"
  pgbench -h "$PGHOST" -p "$port" -U "$PGUSER" -d "$PGDATABASE" -n -c 8 -j 8 -T "$WARMUP" -S >/dev/null 2>&1
  for mode in "${MODES[@]}"; do
    for conc in "${CONCURRENCIES[@]}"; do
      j=$(( conc < 8 ? conc : 8 ))
      out=$(pgbench -h "$PGHOST" -p "$port" -U "$PGUSER" -d "$PGDATABASE" \
            -n -c "$conc" -j "$j" -T "$DURATION" -S -M "$mode" 2>>"$WORK/pgbench.err")
      tps=$(grep -oE 'tps = [0-9.]+' <<<"$out" | grep -oE '[0-9.]+' | head -1)
      lat=$(grep -oE 'latency average = [0-9.]+' <<<"$out" | grep -oE '[0-9.]+' | head -1)
      [ -n "$tps" ] && tps=$(printf '%.0f' "$tps")   # whole tps; fractions are noise
      R["tps,$label,$mode,$conc"]=${tps:-'-'}
      R["lat,$label,$mode,$conc"]=${lat:-'-'}
      printf '   %-9s %-9s c%-3s tps=%-12s lat=%s ms\n' "$label" "$mode" "$conc" "${tps:-'-'}" "${lat:-'-'}" >&2
    done
  done
}

stop_pooler() { [ -n "$POOLER_PID" ] && kill "$POOLER_PID" 2>/dev/null; POOLER_PID=""; sleep 2; }

# ---- direct postgres (no pooler running, so c64 fits under max_connections) ----
pgrep -x barnyard | xargs -r kill 2>/dev/null; sleep 1
run_matrix direct "$PG_PORT"

# ---- barnyard (swept across scheduler thread counts via --ponymaxthreads) ----
for t in "${BARNYARD_THREADS[@]}"; do
  log "starting barnyard on $BARNYARD_PORT_ (pool $POOL_SIZE, --ponymaxthreads=$t)…"
  BARNYARD_PORT=$BARNYARD_PORT_ BARNYARD_POOL=$POOL_SIZE \
    "$ROOT/out/barnyard" --ponymaxthreads="$t" >"$WORK/barnyard-$t.log" 2>&1 &
  BARNYARD_PID=$!
  if wait_ready "$BARNYARD_PORT_"; then run_matrix "barnyard@$t" "$BARNYARD_PORT_"; else warn "barnyard@$t not ready"; fi
  kill "$BARNYARD_PID" 2>/dev/null; BARNYARD_PID=""; sleep 2
done

# ---- pgbouncer ----
if [ -n "$PGBOUNCER_BIN" ]; then
  cat >"$WORK/userlist.txt" <<EOF
"$PGUSER" "$PGPASSWORD"
EOF
  cat >"$WORK/pgbouncer.ini" <<EOF
[databases]
$PGDATABASE = host=$PGHOST port=$PG_PORT dbname=$PGDATABASE
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = $PGBOUNCER_PORT
auth_type = trust
auth_file = $WORK/userlist.txt
pool_mode = transaction
default_pool_size = $POOL_SIZE
max_client_conn = 500
admin_users = $PGUSER
logfile = $WORK/pgbouncer.log
pidfile = $WORK/pgbouncer.pid
EOF
  log "starting pgbouncer on $PGBOUNCER_PORT…"
  "$PGBOUNCER_BIN" -q "$WORK/pgbouncer.ini" >"$WORK/pgbouncer.out" 2>&1 &
  POOLER_PID=$!
  if wait_ready "$PGBOUNCER_PORT"; then run_matrix pgbouncer "$PGBOUNCER_PORT"; else warn "pgbouncer not ready (see $WORK/pgbouncer.out)"; fi
  stop_pooler
fi

# ---- pgcat ----
if [ -n "$PGCAT_BIN" ]; then
  cat >"$WORK/pgcat.toml" <<EOF
[general]
host = "0.0.0.0"
port = $PGCAT_PORT
admin_username = "admin"
admin_password = "admin"

[pools.$PGDATABASE]
pool_mode = "transaction"

[pools.$PGDATABASE.users.0]
username = "$PGUSER"
password = "$PGPASSWORD"
pool_size = $POOL_SIZE

[pools.$PGDATABASE.shards.0]
servers = [[ "$PGHOST", $PG_PORT, "primary" ]]
database = "$PGDATABASE"
EOF
  log "starting pgcat on $PGCAT_PORT…"
  "$PGCAT_BIN" "$WORK/pgcat.toml" >"$WORK/pgcat.out" 2>&1 &
  POOLER_PID=$!
  if wait_ready "$PGCAT_PORT"; then run_matrix pgcat "$PGCAT_PORT"; else warn "pgcat not ready (see $WORK/pgcat.out)"; fi
  stop_pooler
fi

# ---- report ----
print_table() { # metric title unit
  local metric=$1 title=$2 unit=$3 mode conc t v
  echo
  echo "=== $title  (read-only SELECT, pool=$POOL_SIZE, ${DURATION}s/run) ==="
  printf '%-9s %-6s' mode conc
  for t in "${LABELS[@]}"; do printf ' %12s' "$t"; done
  printf '   %s\n' "$unit"
  for mode in "${MODES[@]}"; do
    for conc in "${CONCURRENCIES[@]}"; do
      printf '%-9s c%-5s' "$mode" "$conc"
      for t in "${LABELS[@]}"; do
        v=${R["$metric,$t,$mode,$conc"]:-'-'}
        printf ' %12s' "${v:-'-'}"
      done
      printf '\n'
    done
  done
}

print_table tps "THROUGHPUT" "tps"
print_table lat "LATENCY"    "avg ms"
echo
