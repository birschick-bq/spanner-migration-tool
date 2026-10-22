<#
.SYNOPSIS
    Starts the Docker containers used by the Spanner migration tool integration tests
    and loads the test data into them.

.DESCRIPTION
    Mirrors the services and data loading in .github/workflows/integration-tests-against-omni.yaml:
    Spanner Omni, PostgreSQL, MariaDB (MySQL), SQL Server and Oracle. Containers are named
    smt-it-<service> and data is loaded with the client tools inside each container, so no
    database client needs to be installed on the host.

    Run from Windows PowerShell or PowerShell 7 with Docker Desktop running.

.PARAMETER Services
    Services to start. Defaults to all of: omni, postgres, mysql, sqlserver, oracle.

.PARAMETER Recreate
    Remove and recreate containers that already exist (reloads the test data).

.PARAMETER Stop
    Remove the containers instead of starting them.

.PARAMETER OmniPort
    Host port for the Spanner Omni gRPC endpoint. Defaults to 9010, which the docs use.

.PARAMETER OmniAdminPort
    Host port for the Spanner Omni admin endpoint. Defaults to 9020.

.PARAMETER OmniTag
    Spanner Omni image tag. Defaults to 2026.r4-lts (CI uses 2026.r1-beta).

.EXAMPLE
    .\scripts\start-integration-test-envs.ps1

.EXAMPLE
    .\scripts\start-integration-test-envs.ps1 -Services mysql,omni -Recreate

.EXAMPLE
    .\scripts\start-integration-test-envs.ps1 -OmniTag 2026.r1-beta -Services omni -Recreate

.EXAMPLE
    .\scripts\start-integration-test-envs.ps1 -Stop
#>
[CmdletBinding()]
param(
    [ValidateSet('omni', 'postgres', 'mysql', 'sqlserver', 'oracle')]
    [string[]]$Services = @('omni', 'postgres', 'mysql', 'sqlserver', 'oracle'),
    [switch]$Recreate,
    [switch]$Stop,
    [int]$OmniPort = 9010,
    [int]$OmniAdminPort = 9020,
    [string]$OmniTag = '2026.r4-lts'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testData = Join-Path $repoRoot 'test_data'
# Generated PostgreSQL and MariaDB passwords are saved here (git-ignored). test-env.sh sources it.
$envLocalFile = Join-Path $PSScriptRoot 'test-env.local.sh'

# Same images and credentials as the CI workflow, except PostgreSQL: the data types dump uses
# macaddr8, which needs PostgreSQL 10+ (CI pins 9.6).
$SqlServerPassword = 'tCUE9c1&Ucp0'
$images = @{
    omni      = "us-docker.pkg.dev/spanner-omni/images/spanner-omni:$OmniTag"
    postgres  = 'postgres:16'
    mysql     = 'mariadb:10.11'
    sqlserver = 'mcr.microsoft.com/mssql/server:2025-latest'
    oracle    = 'oracleinanutshell/oracle-xe-11g@sha256:8b740e77d4b90add693fedb22938f340821e89665fb58ecaeeb0dace853b9ee5'
}

function New-Password {
    # Hex only, so the value is safe in shell, docker and connection strings.
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

# Writes (or replaces) "export VARIABLE='VALUE'" in the local env file, keeping its other lines.
# The file is read by bash, so it is written with LF line endings and no byte order mark.
function Save-Secret($variable, $value) {
    $lines = @()
    if (Test-Path $envLocalFile) {
        $lines = @(Get-Content $envLocalFile | Where-Object { $_ -notmatch "^export $variable=" })
    }
    $lines += "export $variable='$value'"
    [System.IO.File]::WriteAllText($envLocalFile, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# Returns the password for a service. A new one is generated when the container is being created
# (or recreated). Otherwise the saved one is reused. A container that already exists without a
# saved password was created with the old fixed password, which cannot be changed in place.
function Resolve-Password($service, $variable, $legacyDefault) {
    $saved = ''
    if (Test-Path $envLocalFile) {
        $match = Select-String -Path $envLocalFile -Pattern "^export $variable='(.*)'$" | Select-Object -Last 1
        if ($match) { $saved = $match.Matches[0].Groups[1].Value }
    }
    if ($Recreate -or (-not $saved -and -not (Test-ContainerExists "smt-it-$service"))) {
        $password = New-Password
        Save-Secret $variable $password
        Write-Host "[$service] generated a new password, saved as $variable in scripts/test-env.local.sh"
        return $password
    }
    if ($saved) { return $saved }
    Write-Warning "[$service] existing container uses the old fixed password; run with -Recreate to switch to a generated one."
    return $legacyDefault
}

function Invoke-Docker {
    # Native commands do not honor $ErrorActionPreference, so check the exit code explicitly.
    # Docker writes progress to stderr, which Windows PowerShell 5.1 would treat as an error.
    $ErrorActionPreference = 'Continue'
    $output = & docker @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($args -join ' ') failed:`n$output"
    }
    $output
}

function Test-ContainerExists($name) {
    [bool](& docker ps -a --filter "name=^/$name$" --format '{{.Names}}')
}

function Test-ContainerRunning($name) {
    [bool](& docker ps --filter "name=^/$name$" --format '{{.Names}}')
}

# $check must end with a docker call; its exit code decides whether the wait is over.
function Wait-Until($description, [scriptblock]$check, [int]$timeoutSeconds = 180) {
    $ErrorActionPreference = 'Continue'
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        & $check 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 3
    }
    throw "Timed out after ${timeoutSeconds}s waiting for $description."
}

# Starts a container unless it is already running. Returns $true when a new container was
# created, meaning its test data still has to be loaded.
function Start-TestContainer($service, [string[]]$runArgs, [string[]]$imageCommand = @()) {
    $name = "smt-it-$service"
    if ($Recreate -and (Test-ContainerExists $name)) {
        Write-Host "[$service] removing existing container $name"
        Invoke-Docker rm -f $name | Out-Null
    }
    if (Test-ContainerRunning $name) {
        Write-Host "[$service] $name already running (use -Recreate to reload data)"
        return $false
    }
    if (Test-ContainerExists $name) {
        Write-Host "[$service] starting existing container $name (data already loaded)"
        Invoke-Docker start $name | Out-Null
        return $false
    }
    Write-Host "[$service] creating $name from $($images[$service])"
    Invoke-Docker run -d --name $name @runArgs $images[$service] @imageCommand | Out-Null
    return $true
}

# Copies a test data file into the container so the in-container client can read it.
function Copy-ToContainer($name, $file) {
    Invoke-Docker cp (Join-Path $testData $file) "${name}:/tmp/$file" | Out-Null
    "/tmp/$file"
}

function Start-Omni {
    $serverArgs = @('start-single-server')
    # Newer releases listen only on localhost by default, which Docker port mapping cannot reach.
    # Older ones (such as 2026.r1-beta) listen on all addresses and do not have this flag.
    $ErrorActionPreference = 'Continue'
    $help = & docker run --rm $images['omni'] start-single-server --help 2>&1 | Out-String
    if ($help -match '--listen-addresses') {
        $serverArgs += @('--listen-addresses', '0.0.0.0')
    }
    Start-TestContainer 'omni' @('-p', "${OmniPort}:15000", '-p', "${OmniAdminPort}:15026", '--tmpfs', '/spanner') $serverArgs | Out-Null
    # An open port is not enough to tell the server is serving, so wait for its ready message.
    Wait-Until 'Spanner Omni' { docker logs smt-it-omni 2>&1 | findstr /C:"Spanner is ready" } 120
}

function Start-Postgres {
    $name = 'smt-it-postgres'
    $pgPassword = Resolve-Password 'postgres' 'PGPASSWORD' 'postgres'
    $created = Start-TestContainer 'postgres' @(
        '-e', 'POSTGRES_USER=postgres', '-e', "POSTGRES_PASSWORD=$pgPassword", '-e', 'POSTGRES_DB=postgres',
        '-p', '5432:5432')
    Wait-Until 'PostgreSQL' { docker exec $name pg_isready -U postgres }
    if (-not $created) { return }
    Write-Host '[postgres] loading test data'
    $dump = Copy-ToContainer $name 'pg_dump.test.out'
    # pg_dump.test.out has a known failing statement that CI also ignores, so errors are not fatal here.
    try {
        Invoke-Docker exec $name psql -U postgres -d postgres -q -f $dump | Out-Null
    } catch {
        Write-Warning "[postgres] pg_dump.test.out reported errors (expected, CI ignores them)."
    }
    Invoke-Docker exec $name psql -U postgres -c 'CREATE DATABASE test_pg_data_types;' | Out-Null
    $types = Copy-ToContainer $name 'postgres_data_types_dump.test.out'
    Invoke-Docker exec $name psql -U postgres -v ON_ERROR_STOP=1 -d test_pg_data_types -q -f $types | Out-Null
}

function Start-MySql {
    $name = 'smt-it-mysql'
    $mysqlPassword = Resolve-Password 'mysql' 'MYSQLPWD' 'root'
    $created = Start-TestContainer 'mysql' @(
        '-e', "MYSQL_ROOT_PASSWORD=$mysqlPassword", '-e', 'MYSQL_DATABASE=test', '-p', '3306:3306')
    # Connect over TCP: the image runs a temporary socket-only server during initialization.
    Wait-Until 'MariaDB' { docker exec -e "MYSQL_PWD=$mysqlPassword" $name mariadb -h 127.0.0.1 -uroot -e 'select 1' }
    if (-not $created) { return }
    Write-Host '[mysql] loading test data'
    $load = {
        param($file, $db)
        Invoke-Docker exec -e "MYSQL_PWD=$mysqlPassword" $name sh -c "mariadb -h 127.0.0.1 -uroot $db < $file" | Out-Null
    }
    & $load (Copy-ToContainer $name 'mysqldump.test.out') 'test'
    foreach ($f in 'mysql_interleave_dump.test.out', 'mysql_foreignkeyaction_dump.test.out',
        'mysql_checkconstraint_dump.test.out', 'mysql_data_types_dump.test.out') {
        & $load (Copy-ToContainer $name $f) ''
    }
    Invoke-Docker exec -e "MYSQL_PWD=$mysqlPassword" $name mariadb -h 127.0.0.1 -uroot -e 'CREATE DATABASE test_mysql_5000_tables;' | Out-Null
    & $load (Copy-ToContainer $name 'mysql_5000_tables.sql') 'test_mysql_5000_tables'
}

function Start-SqlServer {
    $name = 'smt-it-sqlserver'
    $created = Start-TestContainer 'sqlserver' @(
        '-e', "MSSQL_SA_PASSWORD=$SqlServerPassword", '-e', 'MSSQL_PID=Express', '-e', 'ACCEPT_EULA=Y',
        '-p', '1433:1433')
    $sqlcmd = '/opt/mssql-tools18/bin/sqlcmd'
    # SQLCMDPASSWORD keeps the password (which contains '&') out of shell quoting.
    Wait-Until 'SQL Server' { docker exec -e "SQLCMDPASSWORD=$SqlServerPassword" $name $sqlcmd -U sa -C -Q 'select 1' -b } 240
    if (-not $created) { return }
    Write-Host '[sqlserver] loading test data'
    $file = Copy-ToContainer $name 'sqlserver.test.out'
    Invoke-Docker exec -e "SQLCMDPASSWORD=$SqlServerPassword" $name $sqlcmd -U sa -C -b -i $file | Out-Null
}

function Start-Oracle {
    $name = 'smt-it-oracle'
    $created = Start-TestContainer 'oracle' @('-p', '1521:1521')
    $oracleHome = 'ORACLE_HOME=/u01/app/oracle/product/11.2.0/xe'
    $sqlplus = '/u01/app/oracle/product/11.2.0/xe/bin/sqlplus'
    # The first start initializes the database, which can take several minutes.
    Wait-Until 'Oracle XE' { docker exec -e $oracleHome $name sh -c "echo exit | $sqlplus -L -S SYS/oracle@127.0.0.1:1521/xe as sysdba" } 600
    if (-not $created) { return }
    Write-Host '[oracle] loading test data'
    $file = Copy-ToContainer $name 'oracle.test.out'
    Invoke-Docker exec -e $oracleHome $name sh -c "$sqlplus -L -S SYS/oracle@127.0.0.1:1521/xe as sysdba @$file" | Out-Null
}

Invoke-Docker info | Out-Null

if ($Stop) {
    foreach ($service in $Services) {
        $name = "smt-it-$service"
        if (Test-ContainerExists $name) {
            Write-Host "[$service] removing $name"
            Invoke-Docker rm -f $name | Out-Null
        }
    }
    return
}

foreach ($service in $Services) {
    switch ($service) {
        'omni'      { Start-Omni }
        'postgres'  { Start-Postgres }
        'mysql'     { Start-MySql }
        'sqlserver' { Start-SqlServer }
        'oracle'    { Start-Oracle }
    }
}

Write-Host ''
Write-Host 'Environment is ready. Export these variables in the shell that runs go test.'
Write-Host 'Easiest: source scripts/test-env.sh'
Write-Host 'Generated passwords are in scripts/test-env.local.sh, which the template sources; they are not printed here.'
Write-Host @"

export SPANNER_EMULATOR_HOST=localhost:$OmniPort
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

export MSSQL_SA_PASSWORD='$SqlServerPassword'
export SQLSERVERHOST=localhost SQLSERVERPORT=1433 SQLSERVERUSER=sa SQLSERVERDATABASE=SqlServer_IntTest
"@
