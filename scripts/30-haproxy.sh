#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

INVENTORY="${1:-}"
load_inventory "${INVENTORY}"

LOCAL_HOST="$(hostname -s)"

[[ "${LOCAL_HOST}" == "${HA01_NAME}" ]] ||
    die "This installer must run on ${HA01_NAME}; current host is ${LOCAL_HOST}"

if ! ip -br addr | grep -qw "${HA01_IP}"; then
    die "Expected IP ${HA01_IP} is not configured on this host."
fi

log "Installing HAProxy..."

dnf install -y haproxy firewalld curl

systemctl enable --now firewalld

log "Opening firewall..."

firewall-cmd \
    --permanent \
    --add-port="${HAPROXY_POSTGRES_PORT}/tcp"

firewall-cmd \
    --permanent \
    --add-port="${HAPROXY_STATS_PORT}/tcp"

firewall-cmd --reload

log "Writing HAProxy configuration..."

cp -a /etc/haproxy/haproxy.cfg \
    "/etc/haproxy/haproxy.cfg.backup.$(date +%Y%m%d%H%M%S)" \
    2>/dev/null || true

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice

    user haproxy
    group haproxy
    daemon

    maxconn 4096

defaults
    log global

    timeout connect 5s
    timeout client  1m
    timeout server  1m

# ------------------------------------------------------------
# PostgreSQL read/write endpoint
# ------------------------------------------------------------

frontend postgresql_primary
    bind ${HA01_IP}:${HAPROXY_POSTGRES_PORT}
    mode tcp

    default_backend postgresql_primary_nodes

backend postgresql_primary_nodes
    mode tcp

    option httpchk
    http-check connect port ${PATRONI_REST_PORT}
    http-check send meth GET uri /primary
    http-check expect status 200

    default-server \
        inter 2s \
        fall 2 \
        rise 2 \
        on-marked-down shutdown-sessions

    server ${PG01_NAME} ${PG01_IP}:${POSTGRESQL_PORT} check
    server ${PG02_NAME} ${PG02_IP}:${POSTGRESQL_PORT} check
    server ${PG03_NAME} ${PG03_IP}:${POSTGRESQL_PORT} check

# ------------------------------------------------------------
# HAProxy statistics
# ------------------------------------------------------------

listen stats
    bind ${HA01_IP}:${HAPROXY_STATS_PORT}

    mode http

    stats enable
    stats uri /stats
    stats refresh 5s
EOF

log "Validating HAProxy configuration..."

haproxy \
    -c \
    -f /etc/haproxy/haproxy.cfg

log "Starting HAProxy..."

systemctl enable haproxy
systemctl restart haproxy

if ! systemctl is-active --quiet haproxy; then

    journalctl \
        -u haproxy \
        -n 100 \
        --no-pager

    die "HAProxy failed to start."
fi

log "HAProxy installed successfully."

ss -lntp |
    grep -E ":(${HAPROXY_POSTGRES_PORT}|${HAPROXY_STATS_PORT})"
