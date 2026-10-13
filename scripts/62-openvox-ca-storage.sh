#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_root
load_inventory "${1:?Usage: $0 inventory/lab01.env --check|--migrate|--validate}"
MODE="${2:?Specify --check, --migrate, or --validate}"

: "${NFS01_IP:?}" "${CA01_NAME:?}" "${CA01_IP:?}"
NFS_EXPORT="${CA_NFS_EXPORT:-/srv/nfs/openvox-ca}"
NFS_SOURCE="${NFS01_IP}:${NFS_EXPORT}"
CADIR="/etc/puppetlabs/puppetserver/ca"
STAGE="/mnt/openvox-ca-test"
PUPPET="/opt/puppetlabs/bin/puppet"
BACKUP_ROOT="/root/openvox-ca-migration"
GUARD="/usr/local/sbin/openvox-ca-mount-guard"
DROPIN="/etc/systemd/system/puppetserver.service.d/20-ca-nfs.conf"
EXPECTED="${BACKUP_ROOT}/ca-fingerprint.sha256"
FSTAB_LINE="${NFS_SOURCE} ${CADIR} nfs4 rw,vers=4.2,hard,_netdev 0 0"
MIGRATION_STARTED=0
MIGRATION_COMMITTED=0

[[ "$(hostname -s)" == "${CA01_NAME}" ]] || die "Run only on ${CA01_NAME}"
[[ "${MODE}" == --check || "${MODE}" == --migrate || "${MODE}" == --validate ]] || die "Unknown mode ${MODE}"
[[ -x "${PUPPET}" ]] || die "Puppet executable missing"
[[ "$(${PUPPET} config print cadir --section server)" == "${CADIR}" ]] || die "Unexpected cadir"
[[ "$(id -u puppet)" == 52 && "$(id -g puppet)" == 52 ]] || die "Unexpected puppet UID/GID"

check_mount() {
  local where="$1"
  mountpoint -q "${where}" || die "Not a mountpoint: ${where}"
  [[ "$(findmnt -n -o FSTYPE --mountpoint "${where}")" == nfs4 ]] || die "Not NFSv4: ${where}"
  [[ "$(findmnt -n -o SOURCE --mountpoint "${where}")" == "${NFS_SOURCE}" ]] || die "Unexpected NFS source at ${where}"
}

# NFS uses root_squash: inspect the export as the service account.
# Distinguish an empty export from a failed find invocation.
check_empty_nfs() {
  local output rc
  if output="$(runuser -u puppet -- find "${STAGE}" -mindepth 1 -print -quit 2>&1)"; then
    [[ -z "${output}" ]] || die "NFS export is not empty: ${output}"
  else
    rc=$?
    die "Cannot inspect NFS export as puppet (exit=${rc}): ${output}"
  fi
}

check_active_ca() {
  [[ -s "${CADIR}/ca_crt.pem" && -s "${CADIR}/ca_key.pem" ]] || die "CA key/cert missing"
  local c k
  c="$(openssl x509 -in "${CADIR}/ca_crt.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)"
  k="$(openssl pkey -in "${CADIR}/ca_key.pem" -pubout -outform DER | sha256sum | cut -d' ' -f1)"
  [[ "${c}" == "${k}" ]] || die "CA key and cert mismatch"
  printf '%s\n' "${c}"
}

install_guard() {
  install -d -m 0755 /etc/systemd/system/puppetserver.service.d
  cat > "${GUARD}" <<GUARD_SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
mountpoint -q '${CADIR}'
[[ "\$(findmnt -n -o FSTYPE --mountpoint '${CADIR}')" == nfs4 ]]
[[ "\$(findmnt -n -o SOURCE --mountpoint '${CADIR}')" == '${NFS_SOURCE}' ]]
GUARD_SCRIPT
  chmod 0755 "${GUARD}"
  cat > "${DROPIN}" <<DROPIN_FILE
[Unit]
RequiresMountsFor=${CADIR}
After=network-online.target
Wants=network-online.target
ConditionPathIsMountPoint=${CADIR}
[Service]
ExecStartPre=${GUARD}
DROPIN_FILE
  systemctl daemon-reload
}

# Roll back only modifications made by this invocation. Keep NFS data and backups.
rollback_migration() {
  local rc="$1"
  trap - EXIT
  [[ "${MIGRATION_STARTED}" == 1 && "${MIGRATION_COMMITTED}" == 0 ]] || exit "${rc}"
  warn "Migration failed (exit=${rc}); attempting local CA rollback"
  systemctl stop puppetserver || true
  if mountpoint -q "${CADIR}"; then
    umount "${CADIR}" || { warn "Cannot unmount CA NFS; manual intervention required; service remains stopped"; exit "${rc}"; }
  fi
  # Only remove our own exact fstab entry, not unrelated mounts.
  if [[ -f /etc/fstab ]]; then
    awk -v target="${FSTAB_LINE}" '$0 != target' /etc/fstab > /etc/fstab.openvox-tmp && cat /etc/fstab.openvox-tmp > /etc/fstab && rm -f /etc/fstab.openvox-tmp || true
  fi
  rm -f "${DROPIN}" "${GUARD}"
  systemctl daemon-reload || true
  if [[ -d "${CADIR}.before-nfs-migration" ]]; then
    [[ ! -e "${CADIR}" ]] || rmdir "${CADIR}" || { warn "CA mountpoint not empty; manual intervention required"; exit "${rc}"; }
    mv "${CADIR}.before-nfs-migration" "${CADIR}" || { warn "Cannot restore local CA directory"; exit "${rc}"; }
  fi
  if [[ -s "${CADIR}/ca_crt.pem" && -s "${CADIR}/ca_key.pem" ]]; then
    systemctl start puppetserver || warn "Local CA restored but service did not start; investigate"
  else
    warn "Local CA files missing; service intentionally stopped"
  fi
  exit "${rc}"
}

case "${MODE}" in
  --check)
    systemctl is-active --quiet puppetserver || die "Active CA service is not running"
    ! mountpoint -q "${CADIR}" || die "CA directory already mounted"
    check_mount "${STAGE}"
    check_empty_nfs
    [[ "$(stat -c '%u:%g' "${STAGE}")" == 52:52 ]] || die "NFS owner mismatch"
    runuser -u puppet -- /usr/bin/test -w "${STAGE}" || die "puppet cannot write NFS"
    command -v rsync >/dev/null || die "rsync not installed"
    check_active_ca >/dev/null
    log "CHECK PASSED: ready for maintenance window"
    ;;
  --migrate)
    systemctl is-active --quiet puppetserver || die "Expected active CA before migration"
    ! mountpoint -q "${CADIR}" || die "CA already mounted"
    check_mount "${STAGE}"
    check_empty_nfs
    [[ "$(stat -c '%u:%g' "${STAGE}")" == 52:52 ]] || die "NFS owner mismatch"
    runuser -u puppet -- /usr/bin/test -w "${STAGE}" || die "puppet cannot write NFS"
    command -v rsync >/dev/null || die "rsync not installed"
    [[ ! -e "${BACKUP_ROOT}" ]] || die "Migration backup directory already exists"
    [[ ! -e "${CADIR}.before-nfs-migration" ]] || die "Previous migration directory exists"
    [[ ! -e "${DROPIN}" && ! -e "${GUARD}" ]] || die "Existing CA guard detected"
    ! grep -Eq "^[^#]*[[:space:]]${CADIR}[[:space:]]" /etc/fstab || die "fstab already has cadir mount"
    log "Stopping active CA for consistent migration"
    MIGRATION_STARTED=1
    trap 'rollback_migration "$?"' EXIT
    systemctl stop puppetserver
    ! systemctl is-active --quiet puppetserver || die "Cannot stop puppetserver"
    install -d -m 0700 "${BACKUP_ROOT}"
    cp -a "${CADIR}" "${BACKUP_ROOT}/ca-local"
    check_active_ca > "${EXPECTED}"
    log "Copying CA state to NFS as puppet (local backup retained)"
    runuser -u puppet -- rsync -a --checksum "${CADIR}/" "${STAGE}/" || die "NFS copy failed"
    runuser -u puppet -- rsync -a --checksum --dry-run --itemize-changes "${CADIR}/" "${STAGE}/" > "${BACKUP_ROOT}/rsync-diff.txt" || die "NFS verification failed"
    [[ ! -s "${BACKUP_ROOT}/rsync-diff.txt" ]] || die "NFS copy differs from local CA"
    mv "${CADIR}" "${CADIR}.before-nfs-migration"
    install -d -m 0750 -o puppet -g puppet "${CADIR}"
    printf '%s\n' "${FSTAB_LINE}" >> /etc/fstab
    systemctl daemon-reload
    mount "${CADIR}" || die "NFS mount failed"
    check_mount "${CADIR}"
    [[ "$(check_active_ca)" == "$(cat "${EXPECTED}")" ]] || die "CA identity changed"
    install_guard
    systemctl start puppetserver || die "Service start failed"
    systemctl is-active --quiet puppetserver || die "Service inactive after start"
    MIGRATION_COMMITTED=1
    trap - EXIT
    log "MIGRATION COMPLETED. Local CA backup retained. Run --validate."
    ;;
  --validate)
    check_mount "${CADIR}"
    [[ -f "${EXPECTED}" ]] || die "Baseline fingerprint missing"
    [[ "$(check_active_ca)" == "$(cat "${EXPECTED}")" ]] || die "CA fingerprint mismatch"
    [[ -x "${GUARD}" && -f "${DROPIN}" ]] || die "systemd guard missing"
    "${GUARD}" || die "Mount guard failed"
    systemctl is-active --quiet puppetserver || die "CA service inactive"
    CA_CERT="$(${PUPPET} config print cacert --section server)"
    curl --fail --silent --show-error --cacert "${CA_CERT}" \
      "https://${OPENVOX_CA_SERVICE_NAME}:8140/puppet-ca/v1/certificate/ca" >/dev/null \
      || die "CA HTTPS check failed"
    log "VALIDATION PASSED: CA state on NFS, identity intact, HTTPS healthy"
    ;;
esac
