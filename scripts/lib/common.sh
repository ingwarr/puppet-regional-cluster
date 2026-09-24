#!/usr/bin/env bash

set -Eeuo pipefail

log()
{
    printf '[INFO] %s\n' "$*"
}

warn()
{
    printf '[WARN] %s\n' "$*" >&2
}

die()
{
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

require_root()
{
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be executed as root."
    fi
}

require_command()
{
    local command_name="$1"

    command -v "${command_name}" >/dev/null 2>&1 ||
        die "Required command not found: ${command_name}"
}

load_inventory()
{
    local inventory="${1:-}"

    [[ -n "${inventory}" ]] ||
        die "Inventory file was not specified."

    [[ -f "${inventory}" ]] ||
        die "Inventory file does not exist: ${inventory}"

    # shellcheck disable=SC1090
    source "${inventory}"

    log "Loaded inventory: ${inventory}"
}

detect_node()
{
    local short_hostname
    local fqdn

    short_hostname="$(hostname -s)"
    fqdn="$(hostname -f)"

    case "${short_hostname}" in
        "${PG01_NAME}")
            NODE_NAME="${PG01_NAME}"
            NODE_FQDN="${PG01_FQDN}"
            NODE_IP="${PG01_IP}"
            ;;

        "${PG02_NAME}")
            NODE_NAME="${PG02_NAME}"
            NODE_FQDN="${PG02_FQDN}"
            NODE_IP="${PG02_IP}"
            ;;

        "${PG03_NAME}")
            NODE_NAME="${PG03_NAME}"
            NODE_FQDN="${PG03_FQDN}"
            NODE_IP="${PG03_IP}"
            ;;

        *)
            case "${fqdn}" in
                "${PG01_FQDN}")
                    NODE_NAME="${PG01_NAME}"
                    NODE_FQDN="${PG01_FQDN}"
                    NODE_IP="${PG01_IP}"
                    ;;

                "${PG02_FQDN}")
                    NODE_NAME="${PG02_NAME}"
                    NODE_FQDN="${PG02_FQDN}"
                    NODE_IP="${PG02_IP}"
                    ;;

                "${PG03_FQDN}")
                    NODE_NAME="${PG03_NAME}"
                    NODE_FQDN="${PG03_FQDN}"
                    NODE_IP="${PG03_IP}"
                    ;;

                *)
                    die "Host ${short_hostname}/${fqdn} is not present in inventory."
                    ;;
            esac
            ;;
    esac

    log "Detected node: ${NODE_NAME} (${NODE_FQDN}, ${NODE_IP})"
}

verify_local_ip()
{
    if ! ip -br address | grep -qw "${NODE_IP}"; then
        die "IP ${NODE_IP} is not configured on this host."
    fi
}
