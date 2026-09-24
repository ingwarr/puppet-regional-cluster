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

ARCH="$(uname -m)"

case "${ARCH}" in
    x86_64)
        ETCD_ARCH="amd64"
        ;;
    aarch64)
        ETCD_ARCH="arm64"
        ;;
    *)
        die "Unsupported architecture: ${ARCH}"
        ;;
esac

ETCD_PACKAGE="etcd-${ETCD_VERSION}-linux-${ETCD_ARCH}"
ETCD_ARCHIVE="${ETCD_PACKAGE}.tar.gz"
ETCD_URL="https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/${ETCD_ARCHIVE}"

log "Configuring firewall..."

firewall-cmd \
    --permanent \
    --add-port="${ETCD_CLIENT_PORT}/tcp"

firewall-cmd \
    --permanent \
    --add-port="${ETCD_PEER_PORT}/tcp"

firewall-cmd --reload

if ! id etcd >/dev/null 2>&1; then
    log "Creating etcd service account..."

    useradd \
        --system \
        --home-dir "${ETCD_DATA_DIR}" \
        --shell /sbin/nologin \
        etcd
fi

install \
    -d \
    -o etcd \
    -g etcd \
    -m 0700 \
    "${ETCD_DATA_DIR}"

install \
    -d \
    -o root \
    -g root \
    -m 0755 \
    "${ETCD_CONFIG_DIR}"

CURRENT_VERSION=""

if command -v etcd >/dev/null 2>&1; then
    CURRENT_VERSION="$(
        etcd --version |
        awk '/etcd Version:/ {print $3}'
    )"
fi

EXPECTED_VERSION="${ETCD_VERSION#v}"

if [[ "${CURRENT_VERSION}" != "${EXPECTED_VERSION}" ]]; then

    log "Installing etcd ${ETCD_VERSION}..."

    TMP_DIR="$(mktemp -d)"

    trap 'rm -rf "${TMP_DIR}"' EXIT

    curl \
        --fail \
        --location \
        --output "${TMP_DIR}/${ETCD_ARCHIVE}" \
        "${ETCD_URL}"

    tar \
        -xzf "${TMP_DIR}/${ETCD_ARCHIVE}" \
        -C "${TMP_DIR}"

    install \
        -m 0755 \
        "${TMP_DIR}/${ETCD_PACKAGE}/etcd" \
        /usr/local/bin/etcd

    install \
        -m 0755 \
        "${TMP_DIR}/${ETCD_PACKAGE}/etcdctl" \
        /usr/local/bin/etcdctl

else
    log "etcd ${CURRENT_VERSION} already installed."
fi

#
# Critical protection:
# existing etcd state must never be automatically removed.
#
if [[ -d "${ETCD_DATA_DIR}/member" ]]; then
    log "Existing etcd state detected in ${ETCD_DATA_DIR}."
    log "The existing state will be preserved."
    EXISTING_STATE=true
else
    EXISTING_STATE=false
fi

log "Writing etcd configuration..."

cat > "${ETCD_CONFIG_DIR}/etcd.conf" <<EOF
ETCD_NAME="${NODE_NAME}"

ETCD_DATA_DIR="${ETCD_DATA_DIR}"

ETCD_LISTEN_PEER_URLS="http://${NODE_IP}:${ETCD_PEER_PORT}"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${NODE_IP}:${ETCD_PEER_PORT}"

ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:${ETCD_CLIENT_PORT},http://${NODE_IP}:${ETCD_CLIENT_PORT}"
ETCD_ADVERTISE_CLIENT_URLS="http://${NODE_IP}:${ETCD_CLIENT_PORT}"

ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER}"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="${ETCD_CLUSTER_TOKEN}"
EOF

chmod 0644 "${ETCD_CONFIG_DIR}/etcd.conf"

log "Installing systemd unit..."

cat > /etc/systemd/system/etcd.service <<'EOF'
[Unit]
Description=etcd key-value store
Documentation=https://etcd.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify

User=etcd
Group=etcd

EnvironmentFile=/etc/etcd/etcd.conf

ExecStart=/usr/local/bin/etcd

Restart=on-failure
RestartSec=5s

LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable etcd

if [[ "${EXISTING_STATE}" == true ]]; then
    log "Restarting existing etcd member..."
    systemctl restart etcd
else
    log "Starting new etcd member..."
    systemctl start etcd
fi

sleep 3

if ! systemctl is-active --quiet etcd; then
    journalctl \
        -u etcd \
        -n 50 \
        --no-pager

    die "etcd failed to start."
fi

log "etcd is running."

etcd --version

log "Installation completed successfully."
