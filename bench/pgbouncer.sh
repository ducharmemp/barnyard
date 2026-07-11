#!/usr/bin/env bash
#
# Bench pgbouncer in transaction mode against the local postgres.
set -euo pipefail

here=$(dirname "$0")
. "$here/env.sh"

work="$OUT_DIR/pgbouncer"
mkdir -p "$work"

printf '"%s" "%s"\n' "$PGUSER" "$PGPASSWORD" > "$work/userlist.txt"
cat > "$work/pgbouncer.ini" <<EOF
[databases]
$PGDATABASE = host=$PGHOST port=$PG_PORT dbname=$PGDATABASE
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = $PGBOUNCER_PORT
auth_type = trust
auth_file = $work/userlist.txt
pool_mode = transaction
default_pool_size = $POOL_SIZE
max_client_conn = 500
admin_users = $PGUSER
logfile = $work/pgbouncer.log
pidfile = $work/pgbouncer.pid
EOF

exec "$here/launch.sh" pgbouncer "$PGBOUNCER_PORT" \
  pgbouncer -q "$work/pgbouncer.ini"
