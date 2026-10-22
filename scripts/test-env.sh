# Environment for running the MySQL and PostgreSQL integration and end-to-end tests
# against Spanner Omni and the containers started by start-integration-test-envs.sh.
#
# Usage, in each shell that runs go test:
#   source scripts/test-env.sh
#
# Every value can be overridden by exporting it before sourcing. The generated PostgreSQL
# and MariaDB passwords are read from scripts/test-env.local.sh (git-ignored, chmod 600),
# which is sourced first and is written by the start-integration-test-envs scripts.

# This file must be sourced so the variables reach your shell.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  echo "Source this file: source ${0}" >&2
  exit 1
fi

_smt_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -f "$_smt_env_dir/test-env.local.sh" ] && . "$_smt_env_dir/test-env.local.sh"
unset _smt_env_dir

# Spanner Omni (use the same port passed to the start script, default 9010).
export SPANNER_EMULATOR_HOST="${SPANNER_EMULATOR_HOST:-localhost:9010}"
export SPANNER_EMULATOR_HOST_TYPE="${SPANNER_EMULATOR_HOST_TYPE:-omni}"   # lets the TestE2E_* tests run against Omni
export SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_PROJECT_ID="${SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_PROJECT_ID:-default}"
export SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_INSTANCE_ID="${SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_INSTANCE_ID:-default}"
export IMPORT_CMD_SKIP_DIALECT_VALIDATION="${IMPORT_CMD_SKIP_DIALECT_VALIDATION:-true}"

# Opt in to the TestE2E_* tests. With SPANNER_EMULATOR_HOST set they only run when
# SPANNER_EMULATOR_HOST_TYPE=omni (see onlyRunForEndToEndTest in testing/mysql and testing/postgres).
export SPANNER_MIGRATION_TOOL_RUN_E2E_TESTS="${SPANNER_MIGRATION_TOOL_RUN_E2E_TESTS:-true}"

# PostgreSQL
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"          # CHANGE ME if you changed the container password
export PGDATABASE="${PGDATABASE:-postgres}"
export PGDB_DATA_TYPES="${PGDB_DATA_TYPES:-test_pg_data_types}"

# MySQL (MariaDB container)
export MYSQLHOST="${MYSQLHOST:-localhost}"
export MYSQLPORT="${MYSQLPORT:-3306}"
export MYSQLUSER="${MYSQLUSER:-root}"
export MYSQLPWD="${MYSQLPWD:-root}"                  # CHANGE ME if you changed the container password
export MYSQLDATABASE="${MYSQLDATABASE:-test_interleave_table_data}"
export MYSQLDB_FKACTION="${MYSQLDB_FKACTION:-test_foreign_key_action_data}"
export MYSQLDB_CHECK_CONSTRAINT="${MYSQLDB_CHECK_CONSTRAINT:-test_mysql_checkconstraint}"
export MYSQLDB_DATA_TYPES="${MYSQLDB_DATA_TYPES:-test_mysql_data_types}"
export MYSQLDB_5000_TABLES="${MYSQLDB_5000_TABLES:-test_mysql_5000_tables}"
