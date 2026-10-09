#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/opt/puppetlabs/bin:${PATH}"

PUPPET="/opt/puppetlabs/bin/puppet"
PUPPETSERVER="/opt/puppetlabs/bin/puppetserver"

EXPECTED_CERTNAME="ca01.lab.example"
EXPECTED_SAN="puppet-ca.lab.example"

systemctl is-active --quiet puppetserver || {
    echo "[FAIL] puppetserver inactive"
    exit 1
}

CERT="$("${PUPPET}" config print hostcert --section server)"
CA_CERT="$("${PUPPET}" config print cacert --section server)"

[[ -s "${CERT}" ]] || {
    echo "[FAIL] Host certificate missing"
    exit 1
}

[[ -s "${CA_CERT}" ]] || {
    echo "[FAIL] CA certificate missing"
    exit 1
}

openssl x509 -in "${CERT}" -noout -checkend 86400 >/dev/null

openssl x509 -in "${CERT}" -noout -subject |
    grep -Fq "${EXPECTED_CERTNAME}"

openssl x509 -in "${CERT}" -noout -ext subjectAltName |
    grep -Fq "DNS:${EXPECTED_SAN}"

echo "[PASS] CA host certificate and SAN"

"${PUPPETSERVER}" ca list --all

curl \
    --silent \
    --show-error \
    --fail \
    --cacert "${CA_CERT}" \
    "https://${EXPECTED_SAN}:8140/puppet-ca/v1/certificate/ca" \
    -o /tmp/openvox-ca-validation.pem

openssl x509 \
    -in /tmp/openvox-ca-validation.pem \
    -noout \
    -subject \
    -issuer

echo "[PASS] CA HTTPS endpoint"
echo "OPENVOX CA: HEALTHY"
