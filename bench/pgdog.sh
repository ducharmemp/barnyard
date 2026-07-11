#!/usr/bin/env bash
#
# Bench pgdog in transaction mode against the local postgres.
set -euo pipefail

here=$(dirname "$0")
. "$here/env.sh"

work="$OUT_DIR/pgdog"
mkdir -p "$work"

cat > "$work/pgdog.toml" <<EOF
[general]
host = "0.0.0.0"
port = $PGDOG_PORT

[[databases]]
name = "$PGDATABASE"
host = "$PGHOST"
port = $PG_PORT
role = "primary"
EOF

cat > "$work/users.toml" <<EOF
[[users]]
name = "$PGUSER"
database = "$PGDATABASE"
password = "$PGPASSWORD"
pool_size = $POOL_SIZE
pooler_mode = "transaction"
EOF

exec "$here/launch.sh" pgdog "$PGDOG_PORT" \
  pgdog -c "$work/pgdog.toml" -u "$work/users.toml" run
