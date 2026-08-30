#!/usr/bin/env bash
set -Eeuo pipefail

# KickPi + Elegoo Neptune port-80 manager
#
# Active printer endpoint:
#   http://<KickPi Wi-Fi IP>/
#
# Commands:
#   status           Check network, Moonraker, WebSocket, and listening ports.
#   apply            Safely apply/reapply the port-80 Nginx proxy only.
#   install [--yes]  Run the preserved full legacy setup, then convert it to port 80.
#   help             Show usage.

WIFI_IF="${WIFI_IF:-wlan0}"
ETH_IF="${ETH_IF:-eth0}"
LAN_IP="${LAN_IP:-192.168.50.1}"
PRINTER_IP="${PRINTER_IP:-192.168.50.20}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LEGACY_SCRIPT="${LEGACY_SCRIPT:-${SCRIPT_DIR}/kickpi_neptune_setup.legacy-8081.sh}"

NGINX_CONFIG="/etc/nginx/conf.d/kickpi-printer.conf"
OLD_STANDARD_CONFIG="/etc/nginx/conf.d/zz-kickpi-printer-standard.conf"
NGINX_BACKUP_DIR="/etc/nginx/kickpi-neptune-backups"

log() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        exec sudo -E bash "$0" "$@"
    fi
}

run_privileged_command() {
    if [ "$(id -u)" -eq 0 ]; then
        bash "$0" "$@"
    else
        sudo -E bash "$0" "$@"
    fi
}

get_wifi_ip() {
    ip -4 -o addr show dev "$WIFI_IF" scope global 2>/dev/null |
        awk 'NR == 1 {split($4, a, "/"); print a[1]}'
}

write_port80_config() {
    local wifi_ip="$1"
    local output_file="$2"

    cat >"$output_file" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name ${wifi_ip};

    client_max_body_size 0;

    location / {
        proxy_pass http://${PRINTER_IP};
        proxy_http_version 1.1;

        proxy_set_header Host ${PRINTER_IP};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # ElegooSlicer 1.5.x sends Origin: file:// for its WebSocket.
        # Moonraker rejects that Origin with HTTP 403, so present the
        # printer's permitted internal Origin to the upstream server.
        proxy_set_header Origin http://${PRINTER_IP};

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_connect_timeout 5s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
EOF
}

restore_proxy_config() {
    local config_backup="$1"
    local old_standard_backup="$2"

    if [ -n "$config_backup" ]; then
        cp -a "$config_backup" "$NGINX_CONFIG"
    else
        rm -f "$NGINX_CONFIG"
    fi

    if [ -n "$old_standard_backup" ]; then
        cp -a "$old_standard_backup" "$OLD_STANDARD_CONFIG"
    fi
}

test_proxy() {
    local wifi_ip
    local info
    local token_body
    local token
    local ws_headers
    local ws_status

    require_command ip
    require_command curl
    require_command ss

    wifi_ip="$(get_wifi_ip)"
    [ -n "$wifi_ip" ] || fail "No IPv4 address found on ${WIFI_IF}."

    log "Checking Moonraker through http://${wifi_ip}/"

    info="$(curl -fsS --max-time 5 "http://${wifi_ip}/server/info")" ||
        fail "Moonraker /server/info is not reachable through KickPi."

    printf '%s' "$info" | grep -q '"klippy_state"[[:space:]]*:[[:space:]]*"ready"' ||
        fail "Moonraker responded, but Klipper is not ready."

    token_body="$(curl -fsS --max-time 5 "http://${wifi_ip}/access/oneshot_token")" ||
        fail "Moonraker did not issue a one-shot token."

    token="$(printf '%s' "$token_body" |
        sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$token" ] || fail "Could not parse the Moonraker one-shot token."

    ws_headers="$(
        curl -sS -o /dev/null -D - --max-time 1 \
            -H 'Connection: Upgrade' \
            -H 'Upgrade: websocket' \
            -H 'Sec-WebSocket-Version: 13' \
            -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
            -H 'Origin: file://' \
            "http://${wifi_ip}/websocket?token=${token}" 2>/dev/null || true
    )"

    ws_status="$(printf '%s\n' "$ws_headers" | awk 'NR == 1 {print; exit}')"
    printf '%s' "$ws_status" | grep -q ' 101 ' ||
        fail "ElegooSlicer-compatible WebSocket test failed: ${ws_status:-no response}"

    if ss -lnt | grep -qE '[:.]8081[[:space:]]'; then
        fail "Port 8081 is still listening; expected port 80 only."
    fi

    printf '\nMoonraker: ready\n'
    printf 'WebSocket: 101 Switching Protocols\n'
    printf 'Printer URL: http://%s/\n' "$wifi_ip"
    printf 'Port 8081: disabled\n'
}

apply_proxy() {
    local wifi_ip
    local stamp
    local temp_config
    local config_backup=""
    local old_standard_backup=""

    require_root apply
    require_command nginx
    require_command curl
    require_command ip
    require_command install
    require_command systemctl

    wifi_ip="$(get_wifi_ip)"
    [ -n "$wifi_ip" ] || fail "No IPv4 address found on ${WIFI_IF}."

    curl -fsS --max-time 5 "http://${PRINTER_IP}/server/info" >/dev/null ||
        fail "The printer is not reachable at http://${PRINTER_IP}/server/info."

    stamp="$(date +%Y%m%d-%H%M%S)"
    temp_config="$(mktemp /tmp/kickpi-printer-nginx.XXXXXX)"

    mkdir -p "$NGINX_BACKUP_DIR"
    write_port80_config "$wifi_ip" "$temp_config"

    if [ -f "$NGINX_CONFIG" ]; then
        config_backup="${NGINX_BACKUP_DIR}/kickpi-printer.conf.${stamp}"
        cp -a "$NGINX_CONFIG" "$config_backup"
    fi

    if [ -f "$OLD_STANDARD_CONFIG" ]; then
        old_standard_backup="${NGINX_BACKUP_DIR}/zz-kickpi-printer-standard.conf.${stamp}"
        mv "$OLD_STANDARD_CONFIG" "$old_standard_backup"
    fi

    install -o root -g root -m 0644 "$temp_config" "$NGINX_CONFIG"
    rm -f "$temp_config"

    if ! nginx -t; then
        warn "Nginx validation failed; restoring the previous configuration."
        restore_proxy_config "$config_backup" "$old_standard_backup"
        nginx -t || true
        fail "The new proxy configuration was not applied."
    fi

    if ! systemctl reload nginx; then
        warn "Nginx reload failed; restoring and reloading the previous configuration."
        restore_proxy_config "$config_backup" "$old_standard_backup"

        if nginx -t; then
            systemctl reload nginx ||
                warn "The previous configuration was restored on disk, but Nginx still could not reload."
        else
            warn "The previous configuration was restored, but its validation also failed."
        fi

        fail "The new proxy configuration was rolled back."
    fi

    test_proxy
}

full_install() {
    local assume_yes="${1:-}"

    require_root install "$assume_yes"
    [ -f "$LEGACY_SCRIPT" ] || fail "Legacy setup backup not found: ${LEGACY_SCRIPT}"

    if [ "$assume_yes" != "--yes" ]; then
        printf '\nThis performs the full network, DHCP, NAT, camera, and package setup.\n'
        printf 'The verified legacy installer runs first; port 80 is applied afterward.\n'
        read -r -p 'Continue? [y/N] ' answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) printf 'Cancelled.\n'; return 0 ;;
        esac
    fi

    bash "$LEGACY_SCRIPT"
    apply_proxy
}

show_status() {
    printf '\nKickPi Neptune status\n'
    printf '%s\n' '----------------------'
    ip -br addr show dev "$WIFI_IF" 2>/dev/null || true
    ip -br addr show dev "$ETH_IF" 2>/dev/null || true
    printf '\n'
    ss -lnt | grep -E ':(80|8080|8081)[[:space:]]' || true
    test_proxy
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") COMMAND

Commands:
  status           Check the current setup without changing it.
  apply            Safely apply/reapply the port-80 printer proxy.
  install [--yes]  Perform the complete legacy setup, then enforce port 80.
  help             Show this help.

Run without a command to open the interactive menu.
EOF
}

interactive_menu() {
    while true; do
        cat <<'EOF'

KickPi Neptune Manager
======================
1) Show status and test the printer
2) Repair/reapply the port-80 proxy
3) Run the complete setup
4) Exit
EOF
        read -r -p 'Choose [1-4]: ' choice

        case "$choice" in
            1) show_status ;;
            2)
                run_privileged_command apply ||
                    warn "The port-80 proxy repair failed."
                ;;
            3)
                run_privileged_command install ||
                    warn "The complete setup did not finish successfully."
                ;;
            4) return 0 ;;
            *) warn "Invalid choice: $choice" ;;
        esac
    done
}

main() {
    local command="${1:-}"

    case "$command" in
        "") interactive_menu ;;
        status) show_status ;;
        apply) apply_proxy ;;
        install) full_install "${2:-}" ;;
        help|-h|--help) show_help ;;
        *) show_help; fail "Unknown command: $command" ;;
    esac
}

main "$@"
