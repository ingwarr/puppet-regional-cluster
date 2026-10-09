#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

load_inventory "${1:?Usage: $0 inventory/lab01.env}"

FAILED=0

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; FAILED=1; }

for pkg in \
    openvox-agent \
    openvox-server \
    openvoxdb \
    openvoxdb-termini
do
    if rpm -q "${pkg}" >/dev/null 2>&1; then
        pass "Package ${pkg} installed"
    else
        fail "Package ${pkg} missing"
    fi
done

JAVA_VERSION="$(
    java -version 2>&1 |
    sed -n '1s/.*version "\([^"]*\)".*/\1/p'
)"

if [[ "${JAVA_VERSION}" == 17.* ]]; then
    pass "Java ${JAVA_VERSION}"
else
    fail "Unexpected Java version: ${JAVA_VERSION}"
fi

for svc in puppetserver puppetdb; do
    if systemctl is-active --quiet "${svc}"; then
        fail "${svc} started before configuration"
    else
        pass "${svc} not started"
    fi
done

if [[ "${FAILED}" -eq 0 ]]; then
    echo
    echo "OPENVOX PACKAGE LAYER: HEALTHY"
else
    echo
    echo "OPENVOX PACKAGE LAYER: FAILED"
    exit 1
fi
