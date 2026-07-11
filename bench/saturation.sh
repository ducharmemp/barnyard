#!/usr/bin/env bash
#
# Client-connection saturation bench. Holds the backend pool SMALL and FIXED,
# then ramps the number of CLIENT connections through milestones, measuring at
# each: throughput, average latency, p50/p95/p99 latency, and connection
# failures. The point is to find where each pooler model's latency degrades and
# where it becomes untenable.
#
# IMPORTANT: barnyard currently does SESSION affinity (a backend stays bound to
# a client for its whole session), so it caps at ~pool_size concurrently-active
# clients: past that, extra clients block waiting for a session to free. Expect
# its throughput to plateau and p99 to explode once CLIENTS > pool. pgbouncer and
# pgdog transaction-pool, so they scale toward ~10k. Use this to quantify that
# gap and to track progress once barnyard grows transaction pooling.
#
# Config (override from the environment):
#   SAT_POOL       backend pool size                       (default 24)
#   SAT_DURATION   seconds per milestone                   (default 8)
#   SAT_MODE       simple | extended                       (default simple)
#   SAT_CLIENTS    client-count milestones                 (default 10..10000)
#
# Usage: saturation.sh <barnyard|pgbouncer|pgdog|direct> [pool]
set -uo pipefail   # deliberately not -e: record failures, don't abort

here=$(dirname "$0")
. "$here/env.sh"

target=${1:?usage: saturation.sh <barnyard|pgbouncer|pgdog|direct> [pool]}
SAT_POOL=${2:-${SAT_POOL:-24}}
SAT_DURATION=${SAT_DURATION:-8}
SAT_MODE=${SAT_MODE:-simple}
SAT_CLIENTS=${SAT_CLIENTS:-"10 50 100 250 500 1000 2000 5000 10000"}
work="$OUT_DIR/saturation"
mkdir -p "$work"

# Ramp the fd soft limit as high as the hard limit allows — thousands of client
# sockets live on both sides of the pooler.
ulimit -n 1048576 2>/dev/null || ulimit -n "$(ulimit -Hn 2>/dev/null)" 2>/dev/null || true

nproc_=$(nproc)
# Pony caps --ponymaxthreads at physical (not logical) cores.
phys=$(lscpu -p=core 2>/dev/null | grep -v '^#' | sort -u | wc -l)
[ "${phys:-0}" -lt 1 ] && phys=$nproc_
sat_threads=$(( phys < nproc_ ? phys : nproc_ ))

port_for() {
  case "$1" in
    direct) echo "$PG_PORT" ;;
    barnyard) echo "$BARNYARD_PORT" ;;
    pgbouncer) echo "$PGBOUNCER_PORT" ;;
    pgdog) echo "$PGDOG_PORT" ;;
  esac
}

launch_target() { # echoes the launched pid (empty for direct)
  case "$1" in
    direct) echo "" ;;
    barnyard)
      BARNYARD_PORT="$BARNYARD_PORT" BARNYARD_POOL="$SAT_POOL" \
        ./out/barnyard --ponymaxthreads="$sat_threads" \
        >"$work/barnyard.log" 2>&1 &
      echo $! ;;
    pgbouncer)
      printf '"%s" "%s"\n' "$PGUSER" "$PGPASSWORD" >"$work/userlist.txt"
      cat >"$work/pgbouncer.ini" <<EOF
[databases]
$PGDATABASE = host=$PGHOST port=$PG_PORT dbname=$PGDATABASE
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = $PGBOUNCER_PORT
auth_type = trust
auth_file = $work/userlist.txt
pool_mode = transaction
default_pool_size = $SAT_POOL
max_client_conn = 20000
logfile = $work/pgbouncer.log
pidfile = $work/pgbouncer.pid
EOF
      pgbouncer -q "$work/pgbouncer.ini" >"$work/pgbouncer.out" 2>&1 &
      echo $! ;;
    pgdog)
      cat >"$work/pgdog.toml" <<EOF
[general]
host = "0.0.0.0"
port = $PGDOG_PORT
[[databases]]
name = "$PGDATABASE"
host = "$PGHOST"
port = $PG_PORT
role = "primary"
EOF
      cat >"$work/users.toml" <<EOF
[[users]]
name = "$PGUSER"
database = "$PGDATABASE"
password = "$PGPASSWORD"
pool_size = $SAT_POOL
pooler_mode = "transaction"
EOF
      pgdog -c "$work/pgdog.toml" -u "$work/users.toml" run >"$work/pgdog.log" 2>&1 &
      echo $! ;;
  esac
}

wait_ready() {
  for _ in $(seq 1 60); do
    psql -h "$PGHOST" -p "$1" -U "$PGUSER" -d "$PGDATABASE" -tAc 'select 1' >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

# p50/p95/p99 (in ms) from pgbench per-transaction logs; field 3 is time in µs.
percentiles() {
  cat "$work"/log.* 2>/dev/null | awk '
    { v[NR] = $3 }
    END {
      n = asort(v)
      if (n == 0) { print "- - -"; exit }
      i50 = int(0.50 * n); if (i50 < 1) i50 = 1
      i95 = int(0.95 * n); if (i95 < 1) i95 = 1
      i99 = int(0.99 * n); if (i99 < 1) i99 = 1
      printf "%.2f %.2f %.2f", v[i50] / 1000.0, v[i95] / 1000.0, v[i99] / 1000.0
    }'
}

run_cell() { # <port> <clients> -> "tps avg_ms p50 p95 p99 fails"
  local port=$1 clients=$2 jobs out tps avg fails
  jobs=$(( clients < (nproc_ * 2) ? clients : (nproc_ * 2) ))
  [ "$jobs" -lt 1 ] && jobs=1
  rm -f "$work"/log.* 2>/dev/null

  out=$(timeout $((SAT_DURATION + 40)) \
    pgbench -h "$PGHOST" -p "$port" -U "$PGUSER" -d "$PGDATABASE" \
      -n -c "$clients" -j "$jobs" -T "$SAT_DURATION" -S -M "$SAT_MODE" \
      --log --log-prefix="$work/log" --sampling-rate=0.05 2>&1)
  local rc=$?

  tps=$(grep -oE 'tps = [0-9.]+' <<<"$out" | grep -oE '[0-9.]+' | head -1)
  avg=$(grep -oE 'latency average = [0-9.]+' <<<"$out" | grep -oE '[0-9.]+' | head -1)
  fails=$(grep -ciE 'could not connect|connection to server .+ failed|too many clients|out of memory|FATAL|pgbench: error|received' <<<"$out")
  [ "$rc" -eq 124 ] && { echo "TIMEOUT - - - - many"; return; }

  echo "${tps:--} ${avg:--} $(percentiles) $fails"
}

pkill -x barnyard 2>/dev/null; pkill -x pgbouncer 2>/dev/null; pkill -x pgdog 2>/dev/null
sleep 0.5
pid=$(launch_target "$target")
port=$(port_for "$target")
if ! wait_ready "$port"; then
  echo "!! $target on port $port never came up" >&2
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  exit 1
fi
pgbench -h "$PGHOST" -p "$port" -U "$PGUSER" -d "$PGDATABASE" -n -c 8 -j 8 -T 2 -S >/dev/null 2>&1 || true

echo
printf '== %s  (backend pool=%s, %s, %ss/step, fd limit=%s) ==\n' \
  "$target" "$SAT_POOL" "$SAT_MODE" "$SAT_DURATION" "$(ulimit -n)"
printf '%-8s %-10s %-9s %-8s %-8s %-9s %-6s\n' clients tps avg_ms p50_ms p95_ms p99_ms fails
for c in $SAT_CLIENTS; do
  read -r tps avg p50 p95 p99 fails < <(run_cell "$port" "$c")
  printf '%-8s %-10s %-9s %-8s %-8s %-9s %-6s\n' "$c" "$tps" "$avg" "$p50" "$p95" "$p99" "$fails"
done
echo

[ -n "$pid" ] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
