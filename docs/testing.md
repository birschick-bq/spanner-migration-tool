# Running Integration Tests Locally

The integration tests involve performing actual migrations from a variety of sources (including actual databases),
targeted towards a local emulated instance of spanner. The following describes the steps needed to set up all the
resources required for running the integration tests.

## Quick Start With Docker

On Windows with Docker Desktop, [scripts/start-integration-test-envs.ps1](../scripts/start-integration-test-envs.ps1)
(or [scripts/start-integration-test-envs.sh](../scripts/start-integration-test-envs.sh) on Linux and macOS)
starts Spanner Omni, PostgreSQL, MariaDB (MySQL), SQL Server and Oracle containers (named `smt-it-*`) and loads the
test data described below. It generates random PostgreSQL and MariaDB passwords when it creates those containers and
saves them in `scripts/test-env.local.sh` (git-ignored). Run `source scripts/test-env.sh` before running the tests; it
sets the environment variables and loads the saved passwords. Containers created before this change keep the old fixed
passwords until they are recreated with `-Recreate` / `--recreate`.
```powershell
    .\scripts\start-integration-test-envs.ps1                      # start everything
    .\scripts\start-integration-test-envs.ps1 -Services mysql,omni # start a subset
    .\scripts\start-integration-test-envs.ps1 -Recreate            # recreate containers and reload data
    .\scripts\start-integration-test-envs.ps1 -Stop                # remove the containers
```
```sh
    ./scripts/start-integration-test-envs.sh                       # start everything
    ./scripts/start-integration-test-envs.sh -s mysql,omni         # start a subset
    ./scripts/start-integration-test-envs.sh --recreate            # recreate containers and reload data
    ./scripts/start-integration-test-envs.sh --stop                # remove the containers
```
Pass `-OmniPort`/`-OmniAdminPort` (`--omni-port`/`--omni-admin-port` for the shell script) if the default ports
9010/9020 are already in use. Spanner Omni defaults to the `2026.r4-lts` image; pass `-OmniTag`/`--omni-tag` to use another
tag, for example `2026.r1-beta` (the version used by CI). The scripts start the server with `--listen-addresses 0.0.0.0`
when the image supports it, because newer releases otherwise listen only on `localhost` inside the container and Docker's
published ports cannot reach them. The remaining sections describe the manual setup.

## Setup Source Databases

The following integration tests expect an actually running database to use as the source:
- `testing/mysql`
- `testing/oracle`
- `testing/postgres`
- `testing/sqlserver`

The schema and data for these source databases can be found in the `test_data` directory, as described below.

### MySQL

Start up a MySQL database server (either installed locally, via docker, an external server, etc.).

Initialize the database server with the following test data SQL scripts:
- `test_data/mysqldump.test.out`: A database must already exist (no specific DB name required); populates existing
  database
- `test_data/mysql_interleave_dump.test.out`: Creates and populates a database named `test_interleave_table_data`
- `test_data/mysql_foreignkeyaction_dump.test.out`: Creates and populates a database named `test_foreign_key_action_data`
- `test_data/mysql_checkconstraint_dump.test.out`: Creates and populates a database named `test_mysql_checkconstraint`

In the terminal from which you'll be running the tests, set the following environment variables:
```sh
    export MYSQLHOST=<MySQL DB server host>
    export MYSQLPORT=<MySQL DB server port> # not required if default MySQL port of 3306 is being used
    export MYSQLUSER=<MySQL DB server username>
    export MYSQLPWD=<MySQL DB server password>
    export MYSQLDATABASE=test_interleave_table_data
    export MYSQLDB_FKACTION=test_foreign_key_action_data
    export MYSQLDB_CHECK_CONSTRAINT=test_mysql_checkconstraint
```

### Oracle

Start up an Oracle Express Edition database server (either installed locally, via docker, an external server, etc.).

Initialize the database server with the following test data SQL scripts:
- `test_data/oracle.test.out`: Creates user "sti" with password "test1" and populates tables for that user

### Postgres

Start up a PostgreSQL database server (either installed locally, via docker, an external server, etc.).

Initialize the database server with the following test data SQL scripts:
- `test_data/pg_dump.test.out`: A database must already exist (initial postgres database is acceptable); populates
  existing database

In the terminal from which you'll be running the tests, set the following environment variables:
```sh
    export PGHOST=<Postgres DB server host>
    export PGPORT=<Postgres DB server port>
    export PGUSER=<Postgres DB server user>
    export PGPASSWORD=<Postgres DB server password>
    export PGDATABASE=<Postgres DB server database name>
```

### SQLServer

Start up a SQLServer database server (either installed locally, via docker, etc.). It must be available via hostname
`localhost` and user "sa" must exist (these are hard-coded in the test).

Initialize the database server with the following test data SQL scripts:
- `test_data/sqlserver.test.out`: Creates and populates a database named `SqlServer_IntTest`

In the terminal from which you'll be running the tests, set the following environment variables:
```sh
    export MSSQL_SA_PASSWORD=<Password for user "sa">
```


## Setup Spanner Omni

Spanner Omni can be used for local testing instead of the legacy emulator. It runs as a Docker container.

Start Spanner Omni:
```sh
    docker run -d -p 9010:15000 -p 9020:15026 --tmpfs /spanner us-docker.pkg.dev/spanner-omni/images/spanner-omni:2026.r1-beta start-single-server
```

Set the following environment variables in the terminal from which you'll be running the tests:
```sh
    export SPANNER_EMULATOR_HOST=localhost:9010
    export SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_INSTANCE_ID=default
    export SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_PROJECT_ID=default
```
Note: Spanner Omni in this mode automatically creates a default instance, so you can use `default` as the instance ID and project ID.

## Running the Tests

The integration tests are all found in the `testing` directory. Prior to running the integration tests, ensure you have
all required components (databases, emulated spanner, etc) up and running, and the relevant environment variables set as
described above.

Note that if you are only running certain unit tests, you only need to perform the setup for those specific tests (for
example, if you only want to run the the tests in `testing/mysql`, you only need to have a running MySQL instance with
the relevant environment variables set, there's no need to have any other database running).

Once you have everything setup as required, run the integration tests as follows:
```sh
    go test -v ./testing/...
```

Note that running all tests (using `go test -v ./...`) will also run the integration tests; if the
`SPANNER_EMULATOR_HOST` environment variable is **not** set, the integration tests will simply be skipped.

## Running the End-to-End Tests

The `TestE2E_*` tests in `testing/mysql` and `testing/postgres` (`e2e_test.go` and `e2e_data_types_test.go`) check
Spanner's own limits (table, index and interleave depth limits) and data type mappings. They run against a real Cloud
Spanner instance by default, or against Spanner Omni when it is declared as described below. They are never run against
the Cloud Spanner emulator, and they are opt-in.

| Environment variable | Required value |
|---|---|
| `SPANNER_MIGRATION_TOOL_RUN_E2E_TESTS` | Any non-empty value (for example `true`). Opts in to the end-to-end tests. If it is empty or unset, they are skipped. |
| `SPANNER_EMULATOR_HOST` | Must be **unset** to use Cloud Spanner. If it is set, the end-to-end tests are skipped unless `SPANNER_EMULATOR_HOST_TYPE` is `omni`. |
| `SPANNER_EMULATOR_HOST_TYPE` | Only read when `SPANNER_EMULATOR_HOST` is set. `omni` runs the tests against Spanner Omni; `emulator` (the default) skips them. |
| `SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_PROJECT_ID` | The Google Cloud project that contains the Spanner instance. |
| `SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_INSTANCE_ID` | The Spanner instance in which the tests create and drop databases. |

You also need credentials with permission to create and drop databases and read and write data on that instance (for
example, from `gcloud auth application-default login` or `GOOGLE_APPLICATION_CREDENTIALS`), plus the source database
for the tests you run, set up as described above. Use a dedicated or disposable instance, since usage is billed and a
failed run can leave databases behind.

```sh
    unset SPANNER_EMULATOR_HOST
    export SPANNER_MIGRATION_TOOL_RUN_E2E_TESTS=true
    export SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_PROJECT_ID=<GCP project ID>
    export SPANNER_MIGRATION_TOOL_TESTS_GCLOUD_INSTANCE_ID=<Spanner instance ID>
    go test -v -timeout 60m ./testing/mysql -run TestE2E
```

### Running against Spanner Omni

`SPANNER_EMULATOR_HOST` is also how the tests reach Spanner Omni, and the Cloud Spanner emulator uses the same
variable, so the tests cannot tell them apart. Setting `SPANNER_EMULATOR_HOST_TYPE=omni` declares that the endpoint is
Spanner Omni. `source scripts/test-env.sh` sets both variables along with the source database settings. A full run of
each package takes close to an hour. Some tests fail on known gaps, such as sizes over a limit that the tool does not
reject or data type mappings that differ from the expectations, so compare the results with a previous run.

A skipped test is reported as `SKIP` and does not fail the run, so check the output for `PASS` to confirm the tests
actually ran.
