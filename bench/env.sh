# Shared benchmark configuration, sourced by the bench/ scripts.
# Every value can be overridden from the environment.

PGHOST=${PGHOST:-127.0.0.1}
PGUSER=${PGUSER:-postgres}
PGDATABASE=${PGDATABASE:-postgres}
export PGPASSWORD=${PGPASSWORD:-postgres}
export PGCONNECT_TIMEOUT=3
export PSQLRC=/dev/null

PG_PORT=${PG_PORT:-5432}
BARNYARD_PORT=${BARNYARD_PORT:-7669}
PGBOUNCER_PORT=${PGBOUNCER_PORT:-6432}
PGDOG_PORT=${PGDOG_PORT:-6433}
POOL_SIZE=${POOL_SIZE:-64}

DURATION=${DURATION:-8}
WARMUP=${WARMUP:-2}
MODES=${MODES:-"simple extended"}
CONCURRENCIES=${CONCURRENCIES:-"1 8 16 32 64"}
OUT_DIR=${OUT_DIR:-out/bench}

PROFILE_DURATION=${PROFILE_DURATION:-30}
PROFILE_CONCURRENCY=${PROFILE_CONCURRENCY:-16}
PROFILE_MODE=${PROFILE_MODE:-simple}

wait_ready() { # port [label]
  local port=$1 label=${2:-target}
  for _ in $(seq 1 30); do
    if psql -h "$PGHOST" -p "$port" -U "$PGUSER" -d "$PGDATABASE" -tAc 'select 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "!! $label on port $port never became ready" >&2
  exit 1
}
