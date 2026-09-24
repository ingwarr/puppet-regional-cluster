#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

INVENTORY="${1:-}"

load_inventory "${INVENTORY}"
detect_node
verify_local_ip

log "Installing PostgreSQL ${POSTGRESQL_MAJOR} repository..."

dnf install -y \
  "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm"

#
# Avoid accidentally installing the distribution PostgreSQL module.
#
dnf -qy module disable postgresql || true

log "Installing PostgreSQL ${POSTGRESQL_MAJOR}..."

dnf install -y \
    "postgresql${POSTGRESQL_MAJOR}" \
    "postgresql${POSTGRESQL_MAJOR}-server" \
    "postgresql${POSTGRESQL_MAJOR}-contrib"

log "PostgreSQL version:"

/usr/pgsql-${POSTGRESQL_MAJOR}/bin/postgres --version

#
# Patroni owns PostgreSQL lifecycle.
#
systemctl disable "postgresql-${POSTGRESQL_MAJOR}" 2>/dev/null || true

#
# DO NOT run postgresql-${POSTGRESQL_MAJOR}-setup initdb.
#
if [[ -f "${POSTGRESQL_DATA}/PG_VERSION" ]]; then
    warn "Existing PostgreSQL cluster detected in ${POSTGRESQL_DATA}."
    warn "It will NOT be initialized or removed."
else
    log "PGDATA is not initialized. Patroni will initialize it."
fi

install \
    -d \
    -o postgres \
    -g postgres \
    -m 0700 \
    "${POSTGRESQL_DATA}"

log "Configuring firewall..."

firewall-cmd \
    --permanent \
    --add-port="${POSTGRESQL_PORT}/tcp"

firewall-cmd \
    --permanent \
    --add-port="${PATRONI_REST_PORT}/tcp"

firewall-cmd --reload

log "PostgreSQL package installation completed."

