
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INVENTORY="${1:?Usage: $0 inventory/lab01.env}"
load_inventory "${INVENTORY}"

: "${POSTGRES_SUPERUSER_PASSWORD:?Missing admin password}"
: "${PUPPETDB_PASSWORD:?Missing puppetdb password}"
: "${PUPPETDB_READ_PASSWORD:?Missing read password}"
: "${PUPPETDB_MIGRATOR_PASSWORD:?Missing migrator password}"

PSQL="/usr/pgsql-${POSTGRESQL_MAJOR}/bin/psql"
[[ -x "${PSQL}" ]] || die "psql not installed"

export PGHOST="${POSTGRESQL_SERVICE_NAME}"
export PGPORT="${HAPROXY_POSTGRES_PORT}"
export PGUSER="${POSTGRES_SUPERUSER}"
export PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}"
export PGDATABASE="postgres"
export PGCONNECT_TIMEOUT=5

log "Checking PostgreSQL primary endpoint..."

IS_PRIMARY="$(
    "${PSQL}" -X -At -v ON_ERROR_STOP=1 \
        -c "SELECT NOT pg_is_in_recovery()"
)"

[[ "${IS_PRIMARY}" == "t" ]] ||
    die "PostgreSQL endpoint is not primary"

log "Creating OpenVoxDB roles..."

"${PSQL}" -X -v ON_ERROR_STOP=1 \
    -v dbuser="${PUPPETDB_USER}" \
    -v dbpass="${PUPPETDB_PASSWORD}" \
    -v readuser="${PUPPETDB_READ_USER}" \
    -v readpass="${PUPPETDB_READ_PASSWORD}" \
    -v migrator="${PUPPETDB_MIGRATOR_USER}" \
    -v migratorpass="${PUPPETDB_MIGRATOR_PASSWORD}" <<'SQL'

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L',
              :'dbuser', :'dbpass')
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = :'dbuser'
) \gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L',
              :'readuser', :'readpass')
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = :'readuser'
) \gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L',
              :'migrator', :'migratorpass')
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = :'migrator'
) \gexec

SQL

log "Creating OpenVoxDB database..."

"${PSQL}" -X -v ON_ERROR_STOP=1 \
    -v dbname="${PUPPETDB_DB}" <<'SQL'

SELECT format(
    'CREATE DATABASE %I WITH OWNER postgres ENCODING %L',
    :'dbname', 'UTF8'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_database WHERE datname = :'dbname'
) \gexec

SQL

log "Configuring permissions..."

PGDATABASE="${PUPPETDB_DB}" \
"${PSQL}" -X -v ON_ERROR_STOP=1 \
    -v dbname="${PUPPETDB_DB}" \
    -v dbuser="${PUPPETDB_USER}" \
    -v readuser="${PUPPETDB_READ_USER}" \
    -v migrator="${PUPPETDB_MIGRATOR_USER}" <<'SQL'

REVOKE CREATE ON SCHEMA public FROM PUBLIC;

GRANT CREATE, USAGE ON SCHEMA public TO :"dbuser";
GRANT USAGE ON SCHEMA public TO :"readuser";

GRANT :"readuser" TO :"dbuser";

ALTER DEFAULT PRIVILEGES
    FOR ROLE :"dbuser"
    IN SCHEMA public
    GRANT SELECT ON TABLES TO :"readuser";

ALTER DEFAULT PRIVILEGES
    FOR ROLE :"dbuser"
    IN SCHEMA public
    GRANT USAGE ON SEQUENCES TO :"readuser";

ALTER DEFAULT PRIVILEGES
    FOR ROLE :"dbuser"
    IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO :"readuser";

REVOKE CONNECT ON DATABASE :"dbname" FROM PUBLIC;

GRANT CONNECT ON DATABASE :"dbname"
    TO :"migrator" WITH GRANT OPTION;

SET ROLE :"migrator";
GRANT CONNECT ON DATABASE :"dbname" TO :"dbuser";
GRANT CONNECT ON DATABASE :"dbname" TO :"readuser";
RESET ROLE;

GRANT :"dbuser" TO :"migrator";

CREATE EXTENSION IF NOT EXISTS pg_trgm;

SQL

log "OpenVoxDB database initialized."
