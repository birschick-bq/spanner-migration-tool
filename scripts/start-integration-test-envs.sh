#!/usr/bin/env bash
# Starts the Docker containers used by the Spanner migration tool integration tests and
# loads the test data into them. Bash equivalent of start-integration-test-envs.ps1.
#
# Mirrors the services and data loading in .github/workflows/integration-tests-against-omni.yaml:
# Spanner Omni, PostgreSQL, MariaDB (MySQL), SQL Server and Oracle. Containers are named
# smt-it-<service> and data is loaded with the client tools inside each container, so no
# database client needs to be installed on the host.

set -euo pipefail

ALL_SERVICES="omni postgres mysql sqlserver oracle"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -s, --services LIST       Comma-separated services to start (default: omni,postgres,mysql,sqlserver,oracle).
  -r, --recreate            Remove and recreate existing containers (reloads the test data).
      --stop                Remove the containers instead of starting them.
      --omni-port PORT      Host port for the Spanner Omni gRPC endpoint (default: 9010).
      --omni-admin-port P   Host port for the Spanner Omni admin endpoint (default: 9020).
      --omni-tag TAG        Spanner Omni image tag (default: 2026.r4-lts; CI uses 2026.r1-beta).
  -h, --help                Show this help.

Examples:
  $(basename "$0")
  $(basename "$0") --services mysql,omni --recreate
  $(basename "$0") --omni-tag 2026.r1-beta --services omni --recreate
  $(basename "$0") --stop
EOF
}

SERVICES="$ALL_SERVICES"
RECREATE=false
STOP=false
OMNI_PORT=9010
OMNI_ADMIN_PORT=9020
OMNI_TAG=2026.r4-lts

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--services) SERVICES="${2:?--services needs a value}"; SERVICES="${SERVICES//,/ }"; shift 2 ;;
    -r|--recreate) RECREATE=true; shift ;;
    --stop) STOP=true; shift ;;
    --omni-port) OMNI_PORT="${2:?--omni-port needs a value}"; shift 2 ;;
    --omni-admin-port) OMNI_ADMIN_PORT="${2:?--omni-admin-port needs a value}"; shift 2 ;;
    --omni-tag) OMNI_TAG="${2:?--omni-tag needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for service in $SERVICES; do
  case " $ALL_SERVICES " in
    *" $service "*) ;;
    *) echo "Unknown service: $service (valid: ${ALL_SERVICES// /, })" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DATA="$SCRIPT_DIR/../test_data"
# Generated PostgreSQL and MariaDB passwords are saved here (git-ignored, mode 600). test-env.sh sources it.
ENV_LOCAL_FILE="$SCRIPT_DIR/test-env.local.sh"

# Same images and credentials as the CI workflow, except PostgreSQL: the data types dump uses
# macaddr8, which needs PostgreSQL 10+ (CI pins 9.6).
SQLSERVER_PASSWORD='tCUE9c1&Ucp0'
IMAGE_OMNI="us-docker.pkg.dev/spanner-omni/images/spanner-omni:${OMNI_TAG}"
IMAGE_POSTGRES='postgres:16'
IMAGE_MYSQL='mariadb:10.11'
IMAGE_SQLSERVER='mcr.microsoft.com/mssql/server:2025-latest'
IMAGE_ORACLE='oracleinanutshell/oracle-xe-11g@sha256:8b740e77d4b90add693fedb22938f340821e89665fb58ecaeeb0dace853b9ee5'

ORACLE_HOME_DIR='/u01/app/oracle/product/11.2.0/xe'
SQLCMD='/opt/mssql-tools18/bin/sqlcmd'

generate_password() {
  # Hex only, so the value is safe in shell, docker and connection strings.
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 16
  else head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; echo; fi
}

# Writes (or replaces) "export VARIABLE='VALUE'" in the local env file, keeping its other lines.
save_secret() {
  local var="$1" value="$2" others=""
  [[ -f "$ENV_LOCAL_FILE" ]] && others="$(grep -v "^export $var=" "$ENV_LOCAL_FILE" || true)"
  (umask 077; { [[ -z "$others" ]] || printf '%s\n' "$others"; printf "export %s='%s'\n" "$var" "$value"; } > "$ENV_LOCAL_FILE")
  chmod 600 "$ENV_LOCAL_FILE"
}

# resolve_password SERVICE VARIABLE LEGACY_DEFAULT
# Sets RESOLVED_PASSWORD. A new password is generated when the container is being created (or
# recreated). Otherwise the saved one is reused. A container that already exists without a
# saved password was created with the old fixed password, which cannot be changed in place.
resolve_password() {
  local service="$1" var="$2" legacy="$3" saved=""
  [[ -f "$ENV_LOCAL_FILE" ]] && saved="$(sed -n "s/^export $var='\(.*\)'\$/\1/p" "$ENV_LOCAL_FILE" | tail -n 1)"
  if [[ "$RECREATE" == true ]] || { [[ -z "$saved" ]] && ! container_exists "smt-it-$service"; }; then
    RESOLVED_PASSWORD="$(generate_password)"
    save_secret "$var" "$RESOLVED_PASSWORD"
    echo "[$service] generated a new password, saved as $var in scripts/test-env.local.sh"
  elif [[ -n "$saved" ]]; then
    RESOLVED_PASSWORD="$saved"
  else
    RESOLVED_PASSWORD="$legacy"
    echo "[$service] existing container uses the old fixed password; run with --recreate to switch to a generated one." >&2
  fi
}

container_exists() { [[ -n "$(docker ps -a --filter "name=^/$1\$" --format '{{.Names}}')" ]]; }
container_running() { [[ -n "$(docker ps --filter "name=^/$1\$" --format '{{.Names}}')" ]]; }

# wait_until DESCRIPTION TIMEOUT_SECONDS COMMAND...
wait_until() {
  local description="$1" timeout="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  echo "Timed out after ${timeout}s waiting for $description." >&2
  return 1
}

# start_container SERVICE IMAGE [docker run args...] [-- image command...]
# Starts a container unless it is already running. Sets CREATED=true when a new container was
# created, meaning its test data still has to be loaded.
start_container() {
  local service="$1" image="$2"
  shift 2
  local name="smt-it-$service" run_args=() image_cmd=() in_cmd=false arg
  for arg in "$@"; do
    if [[ "$arg" == "--" && "$in_cmd" == false ]]; then in_cmd=true
    elif [[ "$in_cmd" == true ]]; then image_cmd+=("$arg")
    else run_args+=("$arg"); fi
  done

  CREATED=false
  if [[ "$RECREATE" == true ]] && container_exists "$name"; then
    echo "[$service] removing existing container $name"
    docker rm -f "$name" >/dev/null
  fi
  if container_running "$name"; then
    echo "[$service] $name already running (use --recreate to reload data)"
    return
  fi
  if container_exists "$name"; then
    echo "[$service] starting existing container $name (data already loaded)"
    docker start "$name" >/dev/null
    return
  fi
  echo "[$service] creating $name from $image"
  docker run -d --name "$name" "${run_args[@]}" "$image" ${image_cmd[@]+"${image_cmd[@]}"} >/dev/null
  CREATED=true
}

# Copies a test data file into the container so the in-container client can read it, and prints its path.
copy_to_container() {
  docker cp "$TEST_DATA/$2" "$1:/tmp/$2"
  echo "/tmp/$2"
}

start_omni() {
  local server_args=(start-single-server)
  # Newer releases listen only on localhost by default, which Docker port mapping cannot reach.
  # Older ones (such as 2026.r1-beta) listen on all addresses and do not have this flag.
  if docker run --rm "$IMAGE_OMNI" start-single-server --help 2>&1 | grep -q -- '--listen-addresses'; then
    server_args+=(--listen-addresses 0.0.0.0)
  fi
  start_container omni "$IMAGE_OMNI" \
    -p "${OMNI_PORT}:15000" -p "${OMNI_ADMIN_PORT}:15026" --tmpfs /spanner -- "${server_args[@]}"
  # An open port is not enough to tell the server is serving, so wait for its ready message.
  wait_until 'Spanner Omni' 120 bash -c 'docker logs smt-it-omni 2>&1 | grep -q "Spanner is ready"'
}

start_postgres() {
  local name=smt-it-postgres dump types
  resolve_password postgres PGPASSWORD postgres
  start_container postgres "$IMAGE_POSTGRES" \
    -e POSTGRES_USER=postgres -e "POSTGRES_PASSWORD=$RESOLVED_PASSWORD" -e POSTGRES_DB=postgres -p 5432:5432
  wait_until PostgreSQL 180 docker exec "$name" pg_isready -U postgres
  [[ "$CREATED" == true ]] || return 0
  echo '[postgres] loading test data'
  dump="$(copy_to_container "$name" pg_dump.test.out)"
  # pg_dump.test.out has a known failing statement that CI also ignores, so errors are not fatal here.
  docker exec "$name" psql -U postgres -d postgres -q -f "$dump" >/dev/null 2>&1 ||
    echo '[postgres] warning: pg_dump.test.out reported errors (expected, CI ignores them).' >&2
  docker exec "$name" psql -U postgres -c 'CREATE DATABASE test_pg_data_types;' >/dev/null
  types="$(copy_to_container "$name" postgres_data_types_dump.test.out)"
  docker exec -e PGOPTIONS='-c client_min_messages=warning' "$name" psql -U postgres -v ON_ERROR_STOP=1 -d test_pg_data_types -q -f "$types" >/dev/null
}

start_mysql() {
  local name=smt-it-mysql f
  resolve_password mysql MYSQLPWD root
  local mysql_pwd="$RESOLVED_PASSWORD"
  start_container mysql "$IMAGE_MYSQL" \
    -e "MYSQL_ROOT_PASSWORD=$mysql_pwd" -e MYSQL_DATABASE=test -p 3306:3306
  # Connect over TCP: the image runs a temporary socket-only server during initialization.
  wait_until MariaDB 180 docker exec -e "MYSQL_PWD=$mysql_pwd" "$name" mariadb -h 127.0.0.1 -uroot -e 'select 1'
  [[ "$CREATED" == true ]] || return 0
  echo '[mysql] loading test data'
  mysql_load() { # FILE [DATABASE]
    local path
    path="$(copy_to_container "$name" "$1")"
    docker exec -e "MYSQL_PWD=$mysql_pwd" "$name" sh -c "mariadb -h 127.0.0.1 -uroot ${2:-} < $path" >/dev/null
  }
  mysql_load mysqldump.test.out test
  for f in mysql_interleave_dump.test.out mysql_foreignkeyaction_dump.test.out \
    mysql_checkconstraint_dump.test.out mysql_data_types_dump.test.out; do
    mysql_load "$f"
  done
  docker exec -e "MYSQL_PWD=$mysql_pwd" "$name" mariadb -h 127.0.0.1 -uroot -e 'CREATE DATABASE test_mysql_5000_tables;' >/dev/null
  mysql_load mysql_5000_tables.sql test_mysql_5000_tables
}

start_sqlserver() {
  local name=smt-it-sqlserver file
  start_container sqlserver "$IMAGE_SQLSERVER" \
    -e "MSSQL_SA_PASSWORD=$SQLSERVER_PASSWORD" -e MSSQL_PID=Express -e ACCEPT_EULA=Y -p 1433:1433
  # SQLCMDPASSWORD keeps the password (which contains '&') out of shell quoting.
  wait_until 'SQL Server' 240 \
    docker exec -e "SQLCMDPASSWORD=$SQLSERVER_PASSWORD" "$name" "$SQLCMD" -U sa -C -Q 'select 1' -b
  [[ "$CREATED" == true ]] || return 0
  echo '[sqlserver] loading test data'
  file="$(copy_to_container "$name" sqlserver.test.out)"
  docker exec -e "SQLCMDPASSWORD=$SQLSERVER_PASSWORD" "$name" "$SQLCMD" -U sa -C -b -i "$file" >/dev/null
}

start_oracle() {
  local name=smt-it-oracle file
  start_container oracle "$IMAGE_ORACLE" -p 1521:1521
  # The first start initializes the database, which can take several minutes.
  wait_until 'Oracle XE' 600 docker exec -e "ORACLE_HOME=$ORACLE_HOME_DIR" "$name" sh -c \
    "echo exit | $ORACLE_HOME_DIR/bin/sqlplus -L -S SYS/oracle@127.0.0.1:1521/xe as sysdba"
  [[ "$CREATED" == true ]] || return 0
  echo '[oracle] loading test data'
  file="$(copy_to_container "$name" oracle.test.out)"
  docker exec -e "ORACLE_HOME=$ORACLE_HOME_DIR" "$name" sh -c \
    "$ORACLE_HOME_DIR/bin/sqlplus -L -S SYS/oracle@127.0.0.1:1521/xe as sysdba @$file" >/dev/null
}

docker info >/dev/null

if [[ "$STOP" == true ]]; then
  for service in $SERVICES; do
    name="smt-it-$service"
    if container_exists "$name"; then
      echo "[$service] removing $name"
      docker rm -f "$name" >/dev/null
    fi
  done
  exit 0
fi

for service in $SERVICES; do
  "start_$service"
done

echo
echo 'Environment is ready. Export these variables in the shell that runs go test.'
echo 'Easiest: source scripts/test-env.sh'
echo 'Generated passwords are in scripts/test-env.local.sh, which the template sources; they are not printed here.'
cat <<EOF

export SPANNER_EMULATOR_HOST=localhost:$OMNI_PORT
export SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_PROJECT_ID=default
export SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_INSTANCE_ID=default
export IMPORT_CMD_SKIP_DIALECT_VALIDATION=true

export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGDATABASE=postgres PGDB_DATA_TYPES=test_pg_data_types

export MYSQLHOST=localhost MYSQLPORT=3306 MYSQLUSER=root
export MYSQLDATABASE=test_interleave_table_data
export MYSQLDB_FKACTION=test_foreign_key_action_data
export MYSQLDB_CHECK_CONSTRAINT=test_mysql_checkconstraint
export MYSQLDB_DATA_TYPES=test_mysql_data_types
export MYSQLDB_5000_TABLES=test_mysql_5000_tables

export MSSQL_SA_PASSWORD='$SQLSERVER_PASSWORD'
export SQLSERVERHOST=localhost SQLSERVERPORT=1433 SQLSERVERUSER=sa SQLSERVERDATABASE=SqlServer_IntTest
EOF
