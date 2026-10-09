#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

export PATH="/opt/puppetlabs/bin:${PATH}"

PUPPET="/opt/puppetlabs/bin/puppet"
PUPPETSERVER="/opt/puppetlabs/bin/puppetserver"

[[ -x "${PUPPET}" ]] ||
    die "Puppet executable not found"

[[ -x "${PUPPETSERVER}" ]] ||
    die "Puppetserver executable not found"

require_root
load_inventory "${1:?Usage: $0 inventory/lab01.env}"

[[ -n "${CA01_IP:-}" ]] ||
    die "CA01_IP is not configured"

[[ "$(hostname -s)" == "${CA01_NAME}" ]] ||
    die "This installer is only for ${CA01_NAME}"

[[ "$(hostname -f)" == "${CA01_FQDN}" ]] ||
    die "Unexpected CA FQDN"

ip -o -4 addr show |
    grep -Fq "inet ${CA01_IP}/" ||
    die "CA01_IP not found on this host"

[[ "${OPENVOX_MAJOR}" == "8" ]] ||
    die "Expected OpenVox 8"

if systemctl is-active --quiet puppetserver; then
    die "puppetserver is already running; refusing CA bootstrap"
fi

log "Installing OpenVox Server"

dnf install -y \
    java-17-openjdk-headless \
    firewalld \
    ca-certificates

dnf install -y \
    https://yum.voxpupuli.org/openvox8-release-el-9.noarch.rpm

dnf install -y openvox-server openvox-agent

systemctl enable --now firewalld

firewall-cmd --permanent --add-port=8140/tcp
firewall-cmd --reload

log "Configuring CA identity"

"${PUPPET}" config set certname \
    "${CA01_FQDN}" --section server

"${PUPPET}" config set dns_alt_names \
    "${OPENVOX_CA_SERVICE_NAME}" --section server

"${PUPPET}" config set server \
    "${OPENVOX_SERVICE_NAME}" --section main

"${PUPPET}" config set ca_server \
    "${OPENVOX_CA_SERVICE_NAME}" --section main

CA_CFG="/etc/puppetlabs/puppetserver/services.d/ca.cfg"

[[ -f "${CA_CFG}" ]] ||
    die "CA service configuration missing"

log "Checking CA service"

grep -Eq \
    '^[[:space:]]*puppetlabs.services.ca.certificate-authority-service/certificate-authority-service[[:space:]]*$' \
    "${CA_CFG}" ||
    die "CA service is not enabled"

CADIR="$("${PUPPET}" config print cadir --section server)"

[[ -n "${CADIR}" && "${CADIR}" == /etc/puppetlabs/* ]] ||
    die "Unexpected CA directory: ${CADIR}"

if [[ -e "${CADIR}/ca_key.pem" ||
      -e "${CADIR}/ca_crt.pem" ||
      -e "${CADIR}/ca.pem" ]]; then
    die "Existing CA material detected; refusing reinitialization"
fi

log "Initializing CA"

/opt/puppetlabs/bin/puppetserver ca setup

log "Starting CA service"

systemctl enable --now puppetserver

systemctl is-active --quiet puppetserver ||
    die "CA service failed to start"

log "CA initialized on ${CA01_FQDN}"
log "Do not initialize a second independent CA on ca02"
