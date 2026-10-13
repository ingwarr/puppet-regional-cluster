#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_inventory "${1:?Usage: $0 inventory/lab01.env}"

FAILURES=0

pass() { echo "[PASS] $*"; }
fail() {
    echo "[FAIL] $*"
    FAILURES=$((FAILURES + 1))
}

if [[ "$(hostname -s)" == "${NFS01_NAME}" ]]; then
    pass "Hostname"
else
    fail "Hostname"
fi

if mountpoint -q "${NFS_MOUNT}"; then
    pass "NFS data filesystem mounted"
else
    fail "NFS data filesystem not mounted"
fi

if [[ "$(findmnt -n -o FSTYPE --target "${NFS_MOUNT}")" == "xfs" ]]; then
    pass "XFS filesystem"
else
    fail "Expected XFS filesystem"
fi

if systemctl is-active --quiet nfs-server; then
    pass "NFS server active"
else
    fail "NFS server inactive"
fi

if [[ -d "${CA_NFS_EXPORT}" ]]; then
    pass "CA export directory exists"
else
    fail "CA export directory missing"
fi

if exportfs -v | grep -Fq "${CA_NFS_EXPORT}"; then
    pass "CA export published"
else
    fail "CA export missing"
fi

if ss -lnt | grep -Eq '(:2049)[[:space:]]'; then
    pass "NFS TCP 2049 listening"
else
    fail "NFS TCP 2049 not listening"
fi

echo
echo "Export details:"
exportfs -v

echo
echo "Filesystem:"
df -hT "${NFS_MOUNT}"

echo
if (( FAILURES > 0 )); then
    echo "NFS VALIDATION FAILED: ${FAILURES} checks"
    exit 1
fi

echo "NFS SERVER VALIDATION PASSED"
