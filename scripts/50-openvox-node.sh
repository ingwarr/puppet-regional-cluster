
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_inventory "${1:?Usage: $0 inventory/lab01.env}"

HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(hostname -f)"

case "${HOST_SHORT}" in
    "${OV01_NAME}")
        NODE_FQDN="${OV01_FQDN}"
        NODE_IP="${OV01_IP}"
        ;;
    "${OV02_NAME}")
        NODE_FQDN="${OV02_FQDN}"
        NODE_IP="${OV02_IP}"
        ;;
    *)
        die "Unknown OpenVox node: ${HOST_SHORT}"
        ;;
esac

log "Preparing ${NODE_FQDN}"

[[ "${HOST_FQDN}" == "${NODE_FQDN}" ]] ||
    die "FQDN mismatch: ${HOST_FQDN} != ${NODE_FQDN}"

ip -o -4 addr show |
    grep -Fq "inet ${NODE_IP}/" ||
    die "IP ${NODE_IP} is missing"

[[ "${OPENVOX_MAJOR}" == "8" ]] ||
    die "Only OpenVox 8 is supported by this installer"

[[ "${JAVA_MAJOR}" == "17" ]] ||
    die "This lab uses Java 17"

log "Installing OS dependencies"

dnf install -y \
    java-17-openjdk-headless \
    curl \
    ca-certificates \
    chrony \
    firewalld

systemctl enable --now chronyd firewalld

log "Installing OpenVox 8 repository"

dnf install -y \
    https://yum.voxpupuli.org/openvox8-release-el-9.noarch.rpm

log "Checking package availability"

dnf list --available \
    openvox-agent \
    openvox-server \
    openvoxdb \
    openvoxdb-termini

log "Installing OpenVox components"

dnf install -y \
    openvox-agent \
    openvox-server \
    openvoxdb \
    openvoxdb-termini

log "Ensuring services are not started prematurely"

systemctl stop puppetserver puppetdb 2>/dev/null || true
systemctl disable puppetserver puppetdb

# The agent must not attempt to contact an unconfigured CA.
systemctl stop puppet 2>/dev/null || true
systemctl disable puppet 2>/dev/null || true

log "Preparing firewall"

firewall-cmd --permanent --add-port=8140/tcp
firewall-cmd --permanent --add-port=8081/tcp
firewall-cmd --reload

log "Installed package versions"

rpm -q \
    openvox-agent \
    openvox-server \
    openvoxdb \
    openvoxdb-termini

log "Java version"
java -version

log "OpenVox node package installation complete"
log "Services intentionally disabled pending CA setup"
