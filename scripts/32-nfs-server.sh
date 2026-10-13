#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_inventory "${1:?Usage: $0 inventory/lab01.env}"

[[ "$(hostname -s)" == "${NFS01_NAME}" ]] ||
    die "Expected host ${NFS01_NAME}"

[[ "$(hostname -f)" == "${NFS01_FQDN}" ]] ||
    die "Unexpected hostname"

ip -o -4 addr show |
    grep -Fq "inet ${NFS01_IP}/" ||
    die "Expected IP ${NFS01_IP} not found"

[[ -b "${NFS_DEVICE}" ]] ||
    die "Device ${NFS_DEVICE} not found"

[[ "${NFS_MOUNT}" == "/srv/nfs" ]] ||
    die "Unexpected NFS mount path"

[[ "${CA_NFS_EXPORT}" == "${NFS_MOUNT}/openvox-ca" ]] ||
    die "Unexpected export path"

dnf install -y nfs-utils xfsprogs firewalld

# The filesystem must be prepared explicitly beforehand.
FSTYPE="$(blkid -s TYPE -o value "${NFS_DEVICE}" || true)"

[[ "${FSTYPE}" == "xfs" ]] ||
    die "${NFS_DEVICE} must contain XFS; found '${FSTYPE}'"

mkdir -p "${NFS_MOUNT}"

UUID="$(blkid -s UUID -o value "${NFS_DEVICE}")"
[[ -n "${UUID}" ]] || die "Filesystem UUID missing"

FSTAB_ENTRY="UUID=${UUID} ${NFS_MOUNT} xfs defaults,nofail 0 2"

if ! grep -qE "[[:space:]]${NFS_MOUNT}[[:space:]]" /etc/fstab; then
    echo "${FSTAB_ENTRY}" >> /etc/fstab
fi

systemctl daemon-reload
mountpoint -q "${NFS_MOUNT}" || mount "${NFS_MOUNT}"

SOURCE="$(findmnt -n -o SOURCE --target "${NFS_MOUNT}")"
[[ "$(blkid -s UUID -o value "${SOURCE}")" == "${UUID}" ]] ||
    die "Unexpected filesystem mounted at ${NFS_MOUNT}"

install -d -m 0700 "${CA_NFS_EXPORT}"

EXPORT_FILE="/etc/exports.d/openvox-ca.exports"

cat > "${EXPORT_FILE}" <<EOF
${CA_NFS_EXPORT} ${CA_NFS_CLIENT01}(rw,sync,no_subtree_check,root_squash) ${CA_NFS_CLIENT02}(rw,sync,no_subtree_check,root_squash)
EOF

chmod 0644 "${EXPORT_FILE}"

systemctl enable --now firewalld

firewall-cmd --permanent \
    --add-rich-rule="rule family=ipv4 source address=${CA_NFS_CLIENT01}/32 port port=2049 protocol=tcp accept"

firewall-cmd --permanent \
    --add-rich-rule="rule family=ipv4 source address=${CA_NFS_CLIENT02}/32 port port=2049 protocol=tcp accept"

firewall-cmd --reload

systemctl enable --now nfs-server
exportfs -ra

log "NFS export configured"
exportfs -v
