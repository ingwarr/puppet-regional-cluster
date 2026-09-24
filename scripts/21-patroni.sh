#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

INVENTORY="${1:-}"

load_inventory "${INVENTORY}"
detect_node
verify_local_ip

PATRONI_HOME="/opt/patroni"
PATRONI_CONFIG_DIR="/etc/patroni"
PATRONI_CONFIG="${PATRONI_CONFIG_DIR}/patroni.yml"

log "Installing Patroni dependencies..."

dnf install -y \
    python3 \
    python3-pip

if [[ ! -d "${PATRONI_HOME}" ]]; then
    log "Creating Patroni virtual environment..."

    python3 -m venv "${PATRONI_HOME}"
fi

log "Installing Patroni..."

"${PATRONI_HOME}/bin/pip" install --upgrade pip

"${PATRONI_HOME}/bin/pip" install \
    "patroni[etcd3]" \
    "psycopg[binary]"

log "Patroni version:"

"${PATRONI_HOME}/bin/patroni" --version

install \
    -d \
    -o postgres \
    -g postgres \
    -m 0750 \
    "${PATRONI_CONFIG_DIR}"

cat > "${PATRONI_CONFIG}" <<EOF
scope: ${PATRONI_SCOPE}
namespace: ${PATRONI_NAMESPACE}
name: ${NODE_NAME}

restapi:
  listen: ${NODE_IP}:${PATRONI_REST_PORT}
  connect_address: ${NODE_IP}:${PATRONI_REST_PORT}

etcd3:
  hosts:
    - ${PG01_IP}:${ETCD_CLIENT_PORT}
    - ${PG02_IP}:${ETCD_CLIENT_PORT}
    - ${PG03_IP}:${ETCD_CLIENT_PORT}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10

    maximum_lag_on_failover: 1048576

    postgresql:
      use_pg_rewind: true
      use_slots: true

      parameters:
        wal_level: replica
        hot_standby: "on"
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host all all 127.0.0.1/32 scram-sha-256
    - host all all ${PG01_IP}/32 scram-sha-256
    - host all all ${PG02_IP}/32 scram-sha-256
    - host all all ${PG03_IP}/32 scram-sha-256

    - host replication ${POSTGRES_REPLICATION_USER} ${PG01_IP}/32 scram-sha-256
    - host replication ${POSTGRES_REPLICATION_USER} ${PG02_IP}/32 scram-sha-256
    - host replication ${POSTGRES_REPLICATION_USER} ${PG03_IP}/32 scram-sha-256

postgresql:
  listen: ${NODE_IP}:${POSTGRESQL_PORT}
  connect_address: ${NODE_IP}:${POSTGRESQL_PORT}

  data_dir: ${POSTGRESQL_DATA}

  bin_dir: /usr/pgsql-${POSTGRESQL_MAJOR}/bin

  authentication:
    superuser:
      username: ${POSTGRES_SUPERUSER}
      password: "${POSTGRES_SUPERUSER_PASSWORD}"

    replication:
      username: ${POSTGRES_REPLICATION_USER}
      password: "${POSTGRES_REPLICATION_PASSWORD}"

  parameters:
    unix_socket_directories: '/var/run/postgresql'
    password_encryption: scram-sha-256

  create_replica_methods:
    - basebackup

  basebackup:
    checkpoint: fast

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

chown postgres:postgres "${PATRONI_CONFIG}"
chmod 0600 "${PATRONI_CONFIG}"

cat > /etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni PostgreSQL HA
After=network-online.target etcd.service
Wants=network-online.target
Requires=etcd.service

[Service]
Type=simple

User=postgres
Group=postgres

ExecStart=${PATRONI_HOME}/bin/patroni ${PATRONI_CONFIG}

KillMode=process
TimeoutSec=30
Restart=on-failure
RestartSec=5

LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable patroni
