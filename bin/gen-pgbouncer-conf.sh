#!/usr/bin/env bash

POSTGRES_URLS=${POSTGRES_URLS:-DATABASE_URL}
POOL_MODE=${PGBOUNCER_POOL_MODE:-session}
SERVER_RESET_QUERY=${PGBOUNCER_SERVER_RESET_QUERY}
n=0

# if the SERVER_RESET_QUERY and pool mode is session, pgbouncer recommends DISCARD ALL be the default
# http://pgbouncer.projects.pgfoundry.org/doc/faq.html#_what_should_my_server_reset_query_be
if [ -z "${SERVER_RESET_QUERY}" ] &&  [ "$POOL_MODE" == "session" ]; then
  SERVER_RESET_QUERY="DISCARD ALL;"
fi

if [ -e /app/vendor/pgbouncer/pgbouncer.ini ] ; then
rm -rf /app/vendor/pgbouncer/pgbouncer.ini
fi
if [ -e /app/vendor/pgbouncer/users.txt ] ; then
rm -rf /app/vendor/pgbouncer/users.txt
fi

if [ -e /app/.qgtunnel ] ; then
rm -rf /app/.qgtunnel
fi

cat >> /app/vendor/pgbouncer/pgbouncer.ini << EOFEOF
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6432
auth_type = md5
auth_file = /app/vendor/pgbouncer/users.txt

; When server connection is released back to pool:
;   session      - after client disconnects
;   transaction  - after transaction finishes
;   statement    - after statement finishes
pool_mode = ${POOL_MODE}
pidfile=/app/pgbouncer.pid
server_reset_query = ${SERVER_RESET_QUERY}
max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN:-100}
default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE:10}
min_pool_size = ${PGBOUNCER_MIN_POOL_SIZE:-0}
reserve_pool_size = ${PGBOUNCER_RESERVE_POOL_SIZE:-1}
reserve_pool_timeout = ${PGBOUNCER_RESERVE_POOL_TIMEOUT:-5.0}
server_lifetime = ${PGBOUNCER_SERVER_LIFETIME:-3600}
server_idle_timeout = ${PGBOUNCER_SERVER_IDLE_TIMEOUT:-600}
log_connections = ${PGBOUNCER_LOG_CONNECTIONS:-1}
log_disconnections = ${PGBOUNCER_LOG_DISCONNECTIONS:-1}
log_pooler_errors = ${PGBOUNCER_LOG_POOLER_ERRORS:1}
stats_period = ${PGBOUNCER_STATS_PERIOD:-60}
verbose = ${PGBOUNCER_VERBOSE:-0}
dns_max_ttl = ${PGBOUNCER_DNS_MAX_TTL:-15}
server_tls_sslmode = ${PGBOUNCER_SERVER_TLS_SSLMODE:-require}
server_tls_ca_file = ${PGBOUNCER_SERVER_TLS_CA_FILE}
server_tls_protocols = secure
; psql -h 127.0.0.1 -p 6432 -U  -d db0 -c "select current_timestamp, b.*, a.* from pg_stat_activity a LEFT JOIN pg_stat_ssl b on a.pid = b.pid where a.pid = pg_backend_pid() ;" > output.txt

[databases]
EOFEOF

for POSTGRES_URL in $POSTGRES_URLS
do
  eval POSTGRES_URL_VALUE=\$$POSTGRES_URL
  IFS=':' read DB_USER DB_PASS DB_HOST DB_PORT DB_NAME <<< $(echo $POSTGRES_URL_VALUE | perl -lne 'print "$1:$2:$3:$4:$5" if /^postgres(?:ql)?:\/\/([^:]*):([^@]*)@(.*?):(.*?)\/(.*?)$/')

  DB_MD5_PASS="md5"`echo -n ${DB_PASS}${DB_USER} | md5sum | awk '{print $1}'`

  CLIENT_DB_NAME="db${n}"

  echo "Setting ${POSTGRES_URL}_PGBOUNCER config var"

  if [ "$PGBOUNCER_PREPARED_STATEMENTS" == "false" ]
  then
    export ${POSTGRES_URL}_PGBOUNCER=postgres://$DB_USER:$DB_PASS@127.0.0.1:6432/$CLIENT_DB_NAME?prepared_statements=false
  else
    export ${POSTGRES_URL}_PGBOUNCER=postgres://$DB_USER:$DB_PASS@127.0.0.1:6432/$CLIENT_DB_NAME
  fi

  cat >> /app/vendor/pgbouncer/users.txt << EOFEOF
"$DB_USER" "$DB_MD5_PASS"
EOFEOF

  cat >> /app/.qgtunnel << EOFEOF
[qgtunnel.${n}]
accept = "127.0.0.1:600${n}"
connect = "$DB_HOST:DB_PORT"
encrypted = false
transparent = true

EOFEOF

  if [ "${QUOTAGUARDSTATIC_URL}" == "" ] ;
  then
    cat >> /app/vendor/pgbouncer/pgbouncer.ini << EOFEOF
$CLIENT_DB_NAME= host=$DB_HOST port=$DB_PORT dbname=$DB_NAME max_db_connections=10
EOFEOF
  else
    cat >> /app/vendor/pgbouncer/pgbouncer.ini << EOFEOF
$CLIENT_DB_NAME= host=127.0.0.1 dbname=$DB_NAME port=600${n} max_db_connections=10
EOFEOF
  fi

  let "n += 1"

  if [ "$n" -gt 10 ]; then
     echo "More than 10 urls provided, stopping at 10"
     break
  fi
done

chmod -R 700 /app/vendor/pgbouncer/*
chmod -R 700 /app/.qgtunnel

echo `date`": /app/vendor/pgbouncer/pgbouncer.ini"
cat /app/vendor/pgbouncer/pgbouncer.ini


echo `date`": /app/vendor/pgbouncer/users.txt"
cat /app/vendor/pgbouncer/users.txt

echo `date`": /app/.qgtunnel"
cat /app/.qgtunnel

