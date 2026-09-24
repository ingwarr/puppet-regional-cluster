#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INVENTORY="${1:-}"
load_inventory "${INVENTORY}"

PATRONICTL="/opt/patroni/bin/patronictl"
PATRONI_CONFIG="/etc/patroni/patroni.yml"

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

require_command jq
[[ -x "${PATRONICTL}" ]] || die "patronictl not found"

log "Checking Patroni cluster..."

CLUSTER_JSON="$(
    "${PATRONICTL}" \
        -c "${PATRONI_CONFIG}" \
        list \
        --format json
)"

printf '%s\n' "${CLUSTER_JSON}" | jq .

HEALTHY_MEMBERS="$(
    jq '
        [
            .[]
            | select(
                (.Role == "Leader" and .State == "running")
                or
                (.Role == "Replica" and .State == "streaming")
            )
        ]
        | length
    ' <<<"${CLUSTER_JSON}"
)"

echo "${HEALTHY_MEMBERS}"

if [[ "${HEALTHY_MEMBERS}" -eq 3 ]]; then
    pass "All PostgreSQL members are healthy."
else
    fail "Expected 3 healthy members not found, found ${HEALTHY_MEMBERS}."
fi

REPLICAS="$(
    jq '[.[] | select(.Role == "Replica")] | length' \
        <<<"${CLUSTER_JSON}"
)"

if [[ "${REPLICAS}" -eq 2 ]]; then
    pass "Exactly two PostgreSQL replicas detected."
else
    fail "Expected 2 replicas, found ${REPLICAS}."
fi

ZERO_LAG_REPLICAS="$(
    jq '
        [
            .[]
            | select(
                .Role == "Replica"
                and (.["Replay Lag"] // 0) == 0
            )
        ]
        | length
    ' <<<"${CLUSTER_JSON}"
)"

if [[ "${ZERO_LAG_REPLICAS}" -eq 2 ]]; then
    pass "Both replicas report zero replay lag."
else
    warn "One or more replicas currently report replay lag."
fi

LEADERS="$(
    jq '[.[] | select(.Role == "Leader")] | length' \
        <<<"${CLUSTER_JSON}"
)"

if [[ "${LEADERS}" -eq 1 ]]; then
    pass "Exactly one PostgreSQL leader detected."
else
    fail "Expected exactly one leader, found ${LEADERS}."
fi

LEADER_HOST="$(
    jq -r '.[] | select(.Role == "Leader") | .Host' \
        <<<"${CLUSTER_JSON}"
)"

log "Current leader: ${LEADER_HOST}"

PSQL="/usr/pgsql-${POSTGRESQL_MAJOR}/bin/psql"

REPLICATION_JSON="$(
    PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" \
    "${PSQL}" \
        -h "${LEADER_HOST}" \
        -p "${POSTGRESQL_PORT}" \
        -U "${POSTGRES_SUPERUSER}" \
        -d postgres \
        -At \
        -c "
            SELECT json_agg(row_to_json(r))
            FROM (
                SELECT
                    application_name,
                    client_addr,
                    state,
                    sync_state
                FROM pg_stat_replication
            ) r;
        "
)"

STREAMING="$(
    jq '[.[] | select(.state == "streaming")] | length' \
        <<<"${REPLICATION_JSON}"
)"

if [[ "${STREAMING}" -eq 2 ]]; then
    pass "2/2 replicas are streaming."
else
    fail "Expected 2 streaming replicas, found ${STREAMING}."
fi

ASYNC="$(
    jq '[.[] | select(.sync_state == "async")] | length' \
        <<<"${REPLICATION_JSON}"
)"

if [[ "${ASYNC}" -eq 2 ]]; then
    pass "Both replicas currently use asynchronous replication."
else
    fail "Unexpected replication mode."
fi

echo

"${PATRONICTL}" \
    -c "${PATRONI_CONFIG}" \
    list

if [[ "${FAILED}" -ne 0 ]]; then
    printf '\nPOSTGRESQL %s: FAILED\n' "${REGION}" >&2
    exit 1
fi

printf '\nPOSTGRESQL %s: HEALTHY\n' "${REGION}"
