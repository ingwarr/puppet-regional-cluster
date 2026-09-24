#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

INVENTORY="${1:-}"

load_inventory "${INVENTORY}"
detect_node
verify_local_ip

log "Installing common packages..."

dnf install -y \
    curl \
    wget \
    tar \
    jq \
    vim \
    chrony \
    firewalld

log "Enabling chronyd..."

systemctl enable --now chronyd

log "Enabling firewalld..."

systemctl enable --now firewalld

log "Installing LAB host records..."

HOSTS_BEGIN="# BEGIN ${REGION} managed hosts"
HOSTS_END="# END ${REGION} managed hosts"

sed -i \
    "/${HOSTS_BEGIN}/,/${HOSTS_END}/d" \
    /etc/hosts

cat >> /etc/hosts <<EOF

${HOSTS_BEGIN}
${PG01_IP} ${PG01_FQDN} ${PG01_NAME}
${PG02_IP} ${PG02_FQDN} ${PG02_NAME}
${PG03_IP} ${PG03_FQDN} ${PG03_NAME}
${HOSTS_END}
EOF

log "Checking name resolution..."

for host in \
    "${PG01_FQDN}" \
    "${PG02_FQDN}" \
    "${PG03_FQDN}"
do
    getent hosts "${host}" >/dev/null ||
        die "Cannot resolve ${host}"
done

log "Checking time synchronization..."

chronyc tracking || warn "chronyc tracking failed."

log "Common bootstrap completed successfully."
