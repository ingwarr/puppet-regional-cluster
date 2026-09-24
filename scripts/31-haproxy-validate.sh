#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INVENTORY="${1:-}"
load_inventory "${INVENTORY}"

PSQL="/usr/pgsql-${POSTGRESQL_MAJOR}/bin/psql"

[[ -x "${PSQL}" ]] ||
    die "PostgreSQL client not found: ${PSQL}"

export PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}"

FAILED=0

pass()
{
    printf '[PASS] %s\n' "$*"
}

fail()
{
    printf '[FAIL] %s\n' "$*" >&2
    FAILED=1
}

log "Checking service name..."

SERVICE_IP="$(
    getent ahostsv4 "${POSTGRESQL_SERVICE_NAME}" |
    awk 'NR == 1 {print $1}'
)"

if [[ "${SERVICE_IP}" == "${POSTGRESQL_SERVICE_IP}" ]]; then
    pass "${POSTGRESQL_SERVICE_NAME} -> ${SERVICE_IP}"
else
    fail \
        "${POSTGRESQL_SERVICE_NAME} resolves to ${SERVICE_IP}, expected ${POSTGRESQL_SERVICE_IP}"
fi

log "Checking PostgreSQL through HAProxy..."

RESULT="$(
    "${PSQL}" \
        -h "${POSTGRESQL_SERVICE_NAME}" \
        -p "${HAPROXY_POSTGRES_PORT}" \
        -U "${POSTGRES_SUPERUSER}" \
        -d postgres \
        -At \
        -c "
            SELECT
                inet_server_addr()::text
                || '|'
                || pg_is_in_recovery()::text;
        "
)" || {
    fail "Cannot connect through HAProxy."
    RESULT=""
}

if [[ -n "${RESULT}" ]]; then

    SERVER_IP="${RESULT%%|*}"
    RECOVERY="${RESULT##*|}"

    log "HAProxy selected PostgreSQL server: ${SERVER_IP}"

    if [[ "${RECOVERY}" == "false" || "${RECOVERY}" == "f" ]]; then
        pass "HAProxy routes traffic to PostgreSQL primary."
    else
        fail "HAProxy routed traffic to a replica."
    fi

    case "${SERVER_IP}" in
        "${PG01_IP}"|"${PG02_IP}"|"${PG03_IP}")
            pass "Backend belongs to the Patroni cluster."
            ;;
        *)
            fail "Unexpected PostgreSQL backend: ${SERVER_IP}"
            ;;
    esac
fi

log "Testing write/read through HAProxy..."

TEST_TABLE="haproxy_validation"

"${PSQL}" \
    -h "${POSTGRESQL_SERVICE_NAME}" \
    -p "${HAPROXY_POSTGRES_PORT}" \
    -U "${POSTGRES_SUPERUSER}" \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "
        CREATE TABLE IF NOT EXISTS ${TEST_TABLE} (
            id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
            server_addr inet,
            message text NOT NULL
        );
    " >/dev/null

TEST_VALUE="validation-$(date +%s)-$$"

"${PSQL}" \
    -h "${POSTGRESQL_SERVICE_NAME}" \
    -p "${HAPROXY_POSTGRES_PORT}" \
    -U "${POSTGRES_SUPERUSER}" \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "
        INSERT INTO ${TEST_TABLE}(server_addr,message)
        VALUES (inet_server_addr(),'${TEST_VALUE}');
    " >/dev/null

READ_VALUE="$(
    "${PSQL}" \
        -h "${POSTGRESQL_SERVICE_NAME}" \
        -p "${HAPROXY_POSTGRES_PORT}" \
        -U "${POSTGRES_SUPERUSER}" \
        -d postgres \
        -At \
        -c "
            SELECT message
            FROM ${TEST_TABLE}
            WHERE message='${TEST_VALUE}';
        "
)"

if [[ "${READ_VALUE}" == "${TEST_VALUE}" ]]; then
    pass "Write/read through HAProxy successful."
else
    fail "Write/read validation failed."
fi

"${PSQL}" \
    -h "${POSTGRESQL_SERVICE_NAME}" \
    -p "${HAPROXY_POSTGRES_PORT}" \
    -U "${POSTGRES_SUPERUSER}" \
    -d postgres \
    -c "
        DELETE FROM ${TEST_TABLE}
        WHERE message='${TEST_VALUE}';
    " >/dev/null

if [[ "${FAILED}" -ne 0 ]]; then
    printf '\nPOSTGRESQL SERVICE ENDPOINT: FAILED\n' >&2
    exit 1
fi

printf '\nPOSTGRESQL SERVICE ENDPOINT: HEALTHY\n'
