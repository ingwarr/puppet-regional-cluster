#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/opt/puppetlabs/bin:${PATH}"

PUPPET="/opt/puppetlabs/bin/puppet"
PUPPETSERVER="/opt/puppetlabs/bin/puppetserver"
EXPECTED_CERTNAME="ca01.lab.example"
EXPECTED_SAN="puppet-ca.lab.example"

fail() { echo "[FAIL] $*" >&2; exit 1; }

systemctl is-active --quiet puppetserver || fail "puppetserver inactive"

CERT="$("${PUPPET}" config print hostcert --section server)"
CA_CERT="$("${PUPPET}" config print cacert --section server)"

[[ -s "${CERT}" ]] || fail "Host certificate missing: ${CERT}"
# The CA state can reside on NFS with root_squash; access it as puppet.
runuser -u puppet -- test -s "${CA_CERT}" || fail "CA certificate missing or unreadable by puppet: ${CA_CERT}"

openssl x509 -in "${CERT}" -noout -checkend 86400 >/dev/null || fail "Host certificate expired or expires within 24h"
openssl x509 -in "${CERT}" -noout -subject | grep -Fq "${EXPECTED_CERTNAME}" || fail "Unexpected host certificate subject"
openssl x509 -in "${CERT}" -noout -ext subjectAltName | grep -Fq "DNS:${EXPECTED_SAN}" || fail "Required SAN missing"

echo "[PASS] CA host certificate and SAN"

"${PUPPETSERVER}" ca list --all || fail "CA certificate listing failed"

# Curl reads the NFS CA certificate as puppet. Pipe the returned PEM directly
# into openssl to avoid a fixed file in /tmp.
runuser -u puppet -- curl \
    --silent --show-error --fail \
    --cacert "${CA_CERT}" \
    "https://${EXPECTED_SAN}:8140/puppet-ca/v1/certificate/ca" \
    | openssl x509 -inform PEM -noout -subject -issuer \
    || fail "CA HTTPS check failed"

echo "[PASS] CA HTTPS endpoint"
echo "OPENVOX CA: HEALTHY"
