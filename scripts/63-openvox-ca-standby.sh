#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_root
load_inventory "${1:?Usage: $0 inventory/lab01.env --check|--prepare|--validate}"
MODE="${2:?Missing mode}"
: "${CA02_NAME:?}" "${NFS01_IP:?}" "${CA_NFS_EXPORT:?}"
SOURCE="${NFS01_IP}:${CA_NFS_EXPORT}"
CADIR=/etc/puppetlabs/puppetserver/ca
GUARD=/usr/local/sbin/openvox-ca-standby-guard
DROPIN=/etc/systemd/system/puppetserver.service.d/20-ca-standby.conf
GATE=/run/openvox-ca/allow-start
[[ "$(hostname -s)" == "$CA02_NAME" ]] || die "Only ca02 ($CA02_NAME)"
[[ "$MODE" == --check || "$MODE" == --prepare || "$MODE" == --validate ]] || die "Invalid mode"
[[ "$(id -u puppet):$(id -g puppet)" == 52:52 ]] || die "puppet UID/GID must be 52:52"
! systemctl is-active --quiet puppetserver || die "Standby puppetserver ACTIVE: refusing"
check_mount() {
  mountpoint -q "$CADIR" || die "CA directory not a mountpoint"
  [[ "$(findmnt -n -o FSTYPE --mountpoint "$CADIR")" == nfs4 ]] || die "CA is not NFSv4"
  [[ "$(findmnt -n -o SOURCE --mountpoint "$CADIR")" == "$SOURCE" ]] || die "Unexpected NFS source"
}
check_state() {
  runuser -u puppet -- test -r "$CADIR/ca_crt.pem" || die "CA cert unreadable as puppet"
  runuser -u puppet -- test -r "$CADIR/ca_key.pem" || die "CA key unreadable as puppet"
  runuser -u puppet -- test -w "$CADIR/serial" || die "CA serial not writable as puppet"
  runuser -u puppet -- openssl x509 -in "$CADIR/ca_crt.pem" -noout -fingerprint -sha256
}
case "$MODE" in
  --check)
    command -v mount.nfs4 >/dev/null || die "NFS client missing"
    [[ ! -e "$CADIR" ]] || { [[ -d "$CADIR" ]] || die "cadir is not a directory"; ! mountpoint -q "$CADIR" || die "Already mounted"; [[ -z "$(find "$CADIR" -mindepth 1 -print -quit)" ]] || die "Local CA directory not empty"; }
    [[ ! -e "$DROPIN" ]] || die "Existing standby drop-in: inspect manually"
    [[ ! -e "$GUARD" ]] || die "Existing standby guard: inspect manually"
    ! grep -Eq "^[^#]*[[:space:]]${CADIR}[[:space:]]" /etc/fstab || die "Existing fstab entry"
    log "CHECK PASSED: safe to prepare standby (no service start)"
    ;;
  --prepare)
    # Preflight before any mutations.
    command -v mount.nfs4 >/dev/null || die "NFS client missing"
    [[ ! -e "$DROPIN" && ! -e "$GUARD" ]] || die "Already configured; use --validate"
    ! grep -Eq "^[^#]*[[:space:]]${CADIR}[[:space:]]" /etc/fstab || die "fstab already contains cadir"
    if [[ -e "$CADIR" ]]; then
      [[ -d "$CADIR" ]] || die "cadir is not directory"
      ! mountpoint -q "$CADIR" || die "Already mounted"
      [[ -z "$(find "$CADIR" -mindepth 1 -print -quit)" ]] || die "Local CA directory not empty"
    fi
    systemctl disable --now puppetserver
    install -d -m 0750 -o puppet -g puppet "$CADIR"
    install -d -m 0755 /etc/systemd/system/puppetserver.service.d /usr/local/sbin
    install -d -m 0700 /run/openvox-ca
    rm -f "$GATE"
    # Install fail-closed gate BEFORE NFS mount or enabling any service.
    cat > "$GUARD" <<'GUARD_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
CADIR=/etc/puppetlabs/puppetserver/ca
GATE=/run/openvox-ca/allow-start
SOURCE=__NFS_SOURCE__
mountpoint -q "$CADIR"
[[ "$(findmnt -n -o FSTYPE --mountpoint "$CADIR")" == nfs4 ]]
[[ "$(findmnt -n -o SOURCE --mountpoint "$CADIR")" == "$SOURCE" ]]
[[ -f "$GATE" && ! -L "$GATE" && "$(stat -c '%a:%u' "$GATE")" == 600:0 ]]
GUARD_EOF
    # Substitute the inventory-sourced NFS source safely without executing it.
    sed -i "s|__NFS_SOURCE__|${SOURCE}|" "$GUARD"
    chmod 0755 "$GUARD"
    cat > "$DROPIN" <<DROPIN_EOF
[Unit]
RequiresMountsFor=${CADIR}
After=network-online.target
Wants=network-online.target
[Service]
ExecStartPre=${GUARD}
DROPIN_EOF
    systemctl daemon-reload
    printf '%s\n' "${SOURCE} ${CADIR} nfs4 rw,vers=4.2,hard,_netdev,nofail 0 0" >> /etc/fstab
    mount "$CADIR" || die "Mount failed. Standby remains disabled, gate closed; inspect fstab"
    check_mount
    check_state
    log "PREPARED: NFS mounted; puppetserver disabled/inactive; start gate CLOSED"
    ;;
  --validate)
    check_mount
    check_state
    [[ -x "$GUARD" && -f "$DROPIN" ]] || die "Standby guard/drop-in missing"
    [[ ! -e "$GATE" ]] || die "Start gate OPEN; close it outside a planned failover"
    if "$GUARD"; then die "Guard unexpectedly allowed standby start"; fi
    [[ "$(systemctl is-enabled puppetserver 2>/dev/null || true)" == disabled ]] || die "puppetserver not disabled"
    log "VALIDATION PASSED: NFS CA readable as puppet; standby stopped; gate closed"
    ;;
esac
