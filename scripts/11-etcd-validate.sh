#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

INVENTORY="${1:-}"

load_inventory "${INVENTORY}"

require_command etcdctl
require_command jq

export ETCDCTL_API=3

#
# Important:
# use environment variable OR --endpoints,
# never both.
#
export ETCDCTL_ENDPOINTS="${ETCD_ENDPOINTS}"

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

log "Checking endpoint health..."

HEALTH_OUTPUT="$(
    etcdctl endpoint health 2>&1
)" || true

printf '%s\n' "${HEALTH_OUTPUT}"

HEALTHY_COUNT="$(
    printf '%s\n' "${HEALTH_OUTPUT}" |
    grep -c 'is healthy' || true
)"

if [[ "${HEALTHY_COUNT}" -eq 3 ]]; then
    pass "3/3 etcd endpoints are healthy."
else
    fail "Expected 3 healthy endpoints, found ${HEALTHY_COUNT}."
fi

log "Checking cluster membership..."

MEMBER_JSON="$(
    etcdctl member list --write-out=json
)"

MEMBER_COUNT="$(
    jq '.members | length' <<<"${MEMBER_JSON}"
)"

if [[ "${MEMBER_COUNT}" -eq 3 ]]; then
    pass "Cluster contains 3 members."
else
    fail "Expected 3 members, found ${MEMBER_COUNT}."
fi

STARTED_COUNT="$(
    jq '[.members[] | select(.name != "")] | length' \
        <<<"${MEMBER_JSON}"
)"

if [[ "${STARTED_COUNT}" -eq 3 ]]; then
    pass "All etcd members are started."
else
    fail "Not all etcd members are started."
fi

log "Checking leader..."

STATUS_JSON="$(
    etcdctl endpoint status --write-out=json
)"

LEADERS="$(
    jq '
        [
            .[]
            | select(
                .Status.header.member_id
                ==
                .Status.leader
            )
        ]
        | length
    ' <<<"${STATUS_JSON}"
)"

if [[ "${LEADERS}" -eq 1 ]]; then
    pass "Exactly one etcd leader detected."
else
    fail "Expected exactly one leader, found ${LEADERS}."
fi

log "Testing distributed write/read..."

TEST_KEY="/${REGION}/validation/$(date +%s)-$$"
TEST_VALUE="etcd-validation-${RANDOM}-${RANDOM}"

etcdctl put \
    "${TEST_KEY}" \
    "${TEST_VALUE}" >/dev/null

READ_VALUE="$(
    etcdctl get \
        "${TEST_KEY}" \
        --print-value-only
)"

if [[ "${READ_VALUE}" == "${TEST_VALUE}" ]]; then
    pass "Distributed write/read test successful."
else
    fail "Distributed write/read test failed."
fi

etcdctl del "${TEST_KEY}" >/dev/null

DELETE_VALUE="$(
    etcdctl get \
        "${TEST_KEY}" \
        --print-value-only
)"

if [[ -z "${DELETE_VALUE}" ]]; then
    pass "Delete test successful."
else
    fail "Delete test failed."
fi

echo

etcdctl endpoint status --write-out=table

echo

if [[ "${FAILED}" -ne 0 ]]; then
    printf '\nETCD %s: FAILED\n' "${REGION}" >&2
    exit 1
fi

printf '\nETCD %s: HEALTHY\n' "${REGION}"

