#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_root
load_inventory "${1:?Usage: $0 inventory/lab01.env --check|--prepare|--validate}"
MODE="${2:?Missing mode}"
: "${CA02_NAME:?}" "${NFS01_IP:?}" "${CA_NFS_EXPORT:?}"
SOURCE="${NFS01_IP}:${CA_NFS_EXPORT}"
CADIR="/etc/puppetlabs/puppetserver/ca"
GUARD="/usr/local/sbin/openvox-ca-mount-guard"
DROPIN="/etc/systemd/system/puppetserver.service.d/20-ca-nfs.conf"
[[ "$(hostname -s)" == "${CA02_NAME}" ]] || die "Run on ca02 only"
[[ "${MODE}" == --check || "${MODE}" == --prepare || "${MODE}" == --validate ]] || die "Unknown mode"
[[ "$(id -u puppet)" == 52 && "$(id -g puppet)" == 52 ]] || die "puppet UID/GID mismatch"
mount_check() {
  mountpoint -q "${CADIR}" || die "CA state not mounted"
  [[ "$(findmnt -n -o FSTYPE --mountpoint "${CADIR}")" == nfs4 ]] || die "Not NFSv4"
  [[ "$(findmnt -n -o SOURCE --mountpoint "${CADIR}")" == "${SOURCE}" ]] || die "Wrong NFS source"
}
case "${MODE}" in
 --check)
   ! systemctl is-active --quiet puppetserver || die "Standby service is active!"
   [[ -d "${CADIR}" ]] || die "Missing CA directory"
   ! mountpoint -q "${CADIR}" || die "CA already mounted"
   [[ -z "$(find "${CADIR}" -mindepth 1 -print -quit)" ]] || die "Local CA directory not empty: inspect, do not overwrite"
   [[ -s /etc/puppetlabs/puppet/ssl/certs/ca.pem ]] || warn "Local SSL/host certificate not yet configured; standby cannot be started until provisioned"
   log "CHECK PASSED: standby local CA directory is empty"
   ;;
 --prepare)
   ! systemctl is-active --quiet puppetserver || die "Standby service active"
   ! mountpoint -q "${CADIR}" || die "Already mounted"
   [[ -d "${CADIR}" ]] || die "CA directory absent"
   [[ -z "$(find "${CADIR}" -mindepth 1 -print -quit)" ]] || die "Existing local CA state detected; refusing"
   ! grep -Eq "^[^#]*[[:space:]]${CADIR}[[:space:]]" /etc/fstab || die "fstab already configured"
   systemctl disable --now puppetserver
   printf '%s\n' "${SOURCE} ${CADIR} nfs4 rw,vers=4.2,hard,_netdev 0 0" >> /etc/fstab
   systemctl daemon-reload
   mount "${CADIR}" || die "NFS mount failed; service remains disabled"
   mount_check
   [[ -s "${CADIR}/ca_crt.pem" && -s "${CADIR}/ca_key.pem" ]] || die "Shared CA material missing"
   install -d -m 0755 /etc/systemd/system/puppetserver.service.d
   cat > "${GUARD}" <<GUARD_SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
mountpoint -q '${CADIR}'
[[ "\$(findmnt -n -o FSTYPE --mountpoint '${CADIR}')" == nfs4 ]]
[[ "\$(findmnt -n -o SOURCE --mountpoint '${CADIR}')" == '${SOURCE}' ]]
GUARD_SCRIPT
   chmod 0755 "${GUARD}"
   cat > "${DROPIN}" <<DROPIN_FILE
[Unit]
RequiresMountsFor=${CADIR}
After=network-online.target
Wants=network-online.target
[Service]
ExecStartPre=${GUARD}
DROPIN_FILE
   systemctl daemon-reload
   systemctl disable --now puppetserver
   log "STANDBY PREPARED: shared CA state mounted; service DISABLED and STOPPED"
   warn "Do not start standby before fencing ca01 and preparing ca02 host TLS identity"
   ;;
 --validate)
   mount_check
   [[ -x "${GUARD}" ]] || die "Mount guard missing"
   "${GUARD}" || die "Guard failed"
   ! systemctl is-active --quiet puppetserver || die "Standby unexpectedly active"
   [[ "$(systemctl is-enabled puppetserver 2>/dev/null || true)" == disabled ]] || die "Standby service not disabled"
   openssl x509 -in "${CADIR}/ca_crt.pem" -noout -fingerprint -sha256
   log "VALIDATION PASSED: standby mounted but inactive"
   ;;
esac
