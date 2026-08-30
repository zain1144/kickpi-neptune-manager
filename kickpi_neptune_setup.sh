#!/usr/bin/env bash
set -Eeuo pipefail

# KickPi + Elegoo Neptune standalone bootstrap and port-80 manager.
# Target: Ubuntu 22.04 on KickPi K2B, NetworkManager, and Netplan.

SCRIPT_VERSION="2.0.0"

WIFI_IF="${WIFI_IF:-wlan0}"
ETH_IF="${ETH_IF:-eth0}"
LAN_CIDR="${LAN_CIDR:-192.168.50.1/24}"
LAN_IP="${LAN_IP:-${LAN_CIDR%%/*}}"
PRINTER_IP="${PRINTER_IP:-192.168.50.20}"
PRINTER_MAC="${PRINTER_MAC:-}"
DHCP_LEASE="${DHCP_LEASE:-24h}"

CAMERA_ENABLED="${CAMERA_ENABLED:-yes}"
CAMERA_DEVICE="${CAMERA_DEVICE:-}"
CAMERA_PORT="${CAMERA_PORT:-8080}"
CAMERA_RESOLUTION="${CAMERA_RESOLUTION:-1280x720}"
CAMERA_FPS="${CAMERA_FPS:-30}"

SKIP_APT="${SKIP_APT:-no}"
PRINTER_WAIT_SECONDS="${PRINTER_WAIT_SECONDS:-60}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"

NETPLAN_FILE="/etc/netplan/99-kickpi-neptune.yaml"
LEGACY_NETPLAN_FILE="/etc/netplan/10-kickpi-neptune.yaml"
DNSMASQ_CONFIG="/etc/dnsmasq.d/kickpi-printer-lan.conf"
NGINX_CONFIG="/etc/nginx/conf.d/kickpi-printer.conf"
OLD_STANDARD_CONFIG="/etc/nginx/conf.d/zz-kickpi-printer-standard.conf"
NGINX_DEFAULT_SITE="/etc/nginx/sites-enabled/default"
NAT_CONFIG="/etc/kickpi/printer-nat.nft"
NAT_SERVICE="/etc/systemd/system/kickpi-printer-nat.service"
SYSCTL_CONFIG="/etc/sysctl.d/99-kickpi-printer.conf"
CAMERA_LAUNCHER="/usr/local/sbin/kickpi-ustreamer-start"
CAMERA_SERVICE="/etc/systemd/system/kickpi-ustreamer.service"

BACKUP_ROOT="/root/kickpi-neptune-backups"
NGINX_BACKUP_ROOT="/etc/nginx/kickpi-neptune-backups"
LOCK_FILE="/run/lock/kickpi-neptune.lock"

MANAGED_PATHS=(
    "$NETPLAN_FILE"
    "$LEGACY_NETPLAN_FILE"
    "$DNSMASQ_CONFIG"
    "$NGINX_CONFIG"
    "$OLD_STANDARD_CONFIG"
    "$NGINX_DEFAULT_SITE"
    "$NAT_CONFIG"
    "$NAT_SERVICE"
    "$SYSCTL_CONFIG"
    "$CAMERA_LAUNCHER"
    "$CAMERA_SERVICE"
)

MANAGED_SERVICES=(
    dnsmasq.service
    nginx.service
    kickpi-printer-nat.service
    kickpi-ustreamer.service
)

STAGING_DIR=""
BACKUP_DIR=""
INSTALL_IN_PROGRESS=0
INSTALL_TOUCHED=0
INSTALL_COMMITTED=0
ROLLBACK_IN_PROGRESS=0
RESOLVED_CAMERA_DEVICE=""

log() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

error() {
    printf '\nERROR: %s\n' "$*" >&2
}

fail() {
    error "$*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_commands() {
    local command
    for command in "$@"; do
        require_command "$command"
    done
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        exec sudo -E bash "$SCRIPT_PATH" "$@"
    fi
}

run_privileged_command() {
    if [ "$(id -u)" -eq 0 ]; then
        bash "$SCRIPT_PATH" "$@"
    else
        sudo -E bash "$SCRIPT_PATH" "$@"
    fi
}

acquire_lock() {
    mkdir -p "$(dirname -- "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || fail "Another KickPi Neptune operation is already running."
}

is_yes_no() {
    case "$1" in
        yes|no) return 0 ;;
        *) return 1 ;;
    esac
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_ipv4() {
    local value="$1"
    local a="" b="" c="" d="" extra=""
    local octet

    IFS=. read -r a b c d extra <<<"$value"
    [ -z "$extra" ] || return 1

    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

same_ipv4_24() {
    [ "${1%.*}" = "${2%.*}" ]
}

get_wifi_ip() {
    ip -4 -o addr show dev "$WIFI_IF" scope global 2>/dev/null |
        awk 'NR == 1 {split($4, a, "/"); print a[1]}'
}

validate_settings() {
    local prefix="${LAN_CIDR#*/}"

    [[ "$WIFI_IF" =~ ^[a-zA-Z0-9_.:-]+$ ]] ||
        fail "Invalid Wi-Fi interface name: $WIFI_IF"
    [[ "$ETH_IF" =~ ^[a-zA-Z0-9_.:-]+$ ]] ||
        fail "Invalid Ethernet interface name: $ETH_IF"
    [ "$WIFI_IF" != "$ETH_IF" ] ||
        fail "Wi-Fi and Ethernet interfaces must be different."

    is_ipv4 "$LAN_IP" || fail "Invalid LAN_IP: $LAN_IP"
    is_ipv4 "$PRINTER_IP" || fail "Invalid PRINTER_IP: $PRINTER_IP"
    [ "${LAN_CIDR%%/*}" = "$LAN_IP" ] ||
        fail "LAN_CIDR address and LAN_IP do not match."
    [ "$prefix" = "24" ] ||
        fail "This installer currently supports a /24 printer LAN only."
    same_ipv4_24 "$LAN_IP" "$PRINTER_IP" ||
        fail "LAN_IP and PRINTER_IP must be in the same /24 network."
    [ "$LAN_IP" != "$PRINTER_IP" ] ||
        fail "LAN_IP and PRINTER_IP must be different."

    if [ -n "$PRINTER_MAC" ]; then
        [[ "$PRINTER_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] ||
            fail "Invalid PRINTER_MAC: $PRINTER_MAC"
    fi

    if ! is_uint "$CAMERA_PORT" ||
        ! ((10#$CAMERA_PORT >= 1 && 10#$CAMERA_PORT <= 65535)); then
        fail "Invalid CAMERA_PORT: $CAMERA_PORT"
    fi
    ((10#$CAMERA_PORT != 80)) ||
        fail "CAMERA_PORT must not be port 80."
    if ! is_uint "$CAMERA_FPS" ||
        ! ((10#$CAMERA_FPS >= 1 && 10#$CAMERA_FPS <= 120)); then
        fail "Invalid CAMERA_FPS: $CAMERA_FPS"
    fi
    [[ "$CAMERA_RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]] ||
        fail "Invalid CAMERA_RESOLUTION: $CAMERA_RESOLUTION"
    is_yes_no "$CAMERA_ENABLED" ||
        fail "CAMERA_ENABLED must be 'yes' or 'no'."
    is_yes_no "$SKIP_APT" ||
        fail "SKIP_APT must be 'yes' or 'no'."
    is_uint "$PRINTER_WAIT_SECONDS" ||
        fail "PRINTER_WAIT_SECONDS must be a whole number."
}

check_operating_system() {
    local os_id=""
    local version_id=""

    [ -r /etc/os-release ] || fail "Cannot determine the operating system."
    os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
    version_id="$(. /etc/os-release; printf '%s' "${VERSION_ID:-unknown}")"

    case "$os_id" in
        ubuntu) ;;
        *) fail "Supported operating system: Ubuntu. Detected: ${os_id:-unknown}." ;;
    esac

    if [ "$version_id" != "22.04" ]; then
        warn "Tested on Ubuntu 22.04; detected Ubuntu ${version_id}."
    fi
}

check_network_preflight() {
    local wifi_ip
    local ssh_server_ip=""

    ip link show "$WIFI_IF" >/dev/null 2>&1 ||
        fail "Wi-Fi interface not found: $WIFI_IF"
    ip link show "$ETH_IF" >/dev/null 2>&1 ||
        fail "Ethernet interface not found: $ETH_IF"
    systemctl is-active --quiet NetworkManager ||
        fail "NetworkManager must be active before installation."

    wifi_ip="$(get_wifi_ip)"
    [ -n "$wifi_ip" ] ||
        fail "Wi-Fi interface $WIFI_IF has no IPv4 address. Connect Wi-Fi first."

    if same_ipv4_24 "$wifi_ip" "$LAN_IP"; then
        fail "The Wi-Fi network and printer network overlap (${wifi_ip} and ${LAN_CIDR}). Choose a different LAN_CIDR."
    fi

    if [ -n "${SSH_CONNECTION:-}" ]; then
        ssh_server_ip="$(awk '{print $3}' <<<"$SSH_CONNECTION")"
        if [ -n "$ssh_server_ip" ] && [ "$ssh_server_ip" != "$wifi_ip" ]; then
            fail "SSH is not connected through the KickPi Wi-Fi address ${wifi_ip}. Reconnect over Wi-Fi before installation."
        fi
    fi

    if ! ip -4 route show default | grep -qE "dev[[:space:]]+${WIFI_IF}([[:space:]]|$)"; then
        warn "No default IPv4 route was found through ${WIFI_IF}. Printer internet access may not work."
    fi

    printf '\nWi-Fi:      %s -> %s\n' "$WIFI_IF" "$wifi_ip"
    printf 'Printer LAN: %s -> %s\n' "$ETH_IF" "$LAN_CIDR"
    printf 'Printer IP:  %s\n' "$PRINTER_IP"
}

resolve_camera_device() {
    local matches=()

    if [ -n "$CAMERA_DEVICE" ]; then
        RESOLVED_CAMERA_DEVICE="$CAMERA_DEVICE"
        return 0
    fi

    shopt -s nullglob
    matches=(/dev/v4l/by-id/*-video-index0)
    shopt -u nullglob

    if [ "${#matches[@]}" -gt 0 ]; then
        RESOLVED_CAMERA_DEVICE="${matches[0]}"
        if [ "${#matches[@]}" -gt 1 ]; then
            warn "Multiple cameras detected; using ${RESOLVED_CAMERA_DEVICE}. Set CAMERA_DEVICE to choose another."
        fi
    else
        RESOLVED_CAMERA_DEVICE="/dev/video0"
        warn "No camera is currently detected; the service will wait for /dev/video0."
    fi
}

make_staging_dir() {
    [ -z "$STAGING_DIR" ] || return 0
    STAGING_DIR="$(mktemp -d /tmp/kickpi-neptune.XXXXXX)"
    mkdir -p "$STAGING_DIR/netplan-root/etc/netplan"
}

cleanup_staging() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        case "$STAGING_DIR" in
            /tmp/kickpi-neptune.*) rm -rf -- "$STAGING_DIR" ;;
            *) warn "Refusing to remove unexpected staging path: $STAGING_DIR" ;;
        esac
    fi
    STAGING_DIR=""
}

copy_path_to_backup() {
    local path="$1"
    local destination

    if [ -e "$path" ] || [ -L "$path" ]; then
        destination="${BACKUP_DIR}/files/$(dirname -- "${path#/}")"
        mkdir -p "$destination"
        cp -a -- "$path" "$destination/"
    fi
}

record_service_states() {
    local service active enabled

    : >"${BACKUP_DIR}/service-states.tsv"
    for service in "${MANAGED_SERVICES[@]}"; do
        active="$(systemctl is-active "$service" 2>/dev/null || true)"
        enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
        printf '%s\t%s\t%s\n' "$service" "${active:-unknown}" "${enabled:-unknown}" \
            >>"${BACKUP_DIR}/service-states.tsv"
    done
}

create_install_backup() {
    local path stamp

    stamp="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="${BACKUP_ROOT}/${stamp}-$$"
    mkdir -p "${BACKUP_DIR}/files"
    chmod 700 "$BACKUP_DIR"

    for path in "${MANAGED_PATHS[@]}"; do
        copy_path_to_backup "$path"
    done

    record_service_states
    ip -4 addr >"${BACKUP_DIR}/ip-addresses.txt" 2>&1 || true
    ip route >"${BACKUP_DIR}/ip-routes.txt" 2>&1 || true
    nmcli device status >"${BACKUP_DIR}/nmcli-devices.txt" 2>&1 || true
    printf '%s\n' "$SCRIPT_VERSION" >"${BACKUP_DIR}/installer-version.txt"
    log "Backup created: $BACKUP_DIR"
}

restore_managed_paths() {
    local path saved

    for path in "${MANAGED_PATHS[@]}"; do
        saved="${BACKUP_DIR}/files/${path#/}"
        rm -f -- "$path"
        if [ -e "$saved" ] || [ -L "$saved" ]; then
            mkdir -p "$(dirname -- "$path")"
            cp -a -- "$saved" "$path"
        fi
    done
}

restore_service_states() {
    local service active enabled

    [ -r "${BACKUP_DIR}/service-states.tsv" ] || return 0
    while IFS=$'\t' read -r service active enabled; do
        case "$enabled" in
            enabled|enabled-runtime) systemctl enable "$service" >/dev/null 2>&1 || true ;;
            disabled|masked|not-found|unknown|"") systemctl disable "$service" >/dev/null 2>&1 || true ;;
        esac
        case "$active" in
            active|activating) systemctl start "$service" >/dev/null 2>&1 || true ;;
            *) systemctl stop "$service" >/dev/null 2>&1 || true ;;
        esac
    done <"${BACKUP_DIR}/service-states.tsv"
}

rollback_install() {
    [ "$ROLLBACK_IN_PROGRESS" -eq 0 ] || return 0
    ROLLBACK_IN_PROGRESS=1
    set +e

    warn "Installation failed; restoring the previous managed configuration."
    systemctl stop kickpi-ustreamer.service >/dev/null 2>&1
    systemctl stop kickpi-printer-nat.service >/dev/null 2>&1
    systemctl stop dnsmasq.service >/dev/null 2>&1
    systemctl stop nginx.service >/dev/null 2>&1
    nft delete table inet kickpi_printer >/dev/null 2>&1

    restore_managed_paths
    systemctl daemon-reload >/dev/null 2>&1
    if command -v netplan >/dev/null 2>&1; then
        netplan generate >/dev/null 2>&1
        netplan apply >/dev/null 2>&1
    fi
    if command -v sysctl >/dev/null 2>&1; then
        sysctl --system >/dev/null 2>&1
    fi
    restore_service_states
    warn "Rollback completed. Package installations are not removed. Backup: $BACKUP_DIR"
    set -e
}

on_exit() {
    local rc=$?
    trap - EXIT

    if [ "$INSTALL_IN_PROGRESS" -eq 1 ] &&
        [ "$INSTALL_TOUCHED" -eq 1 ] &&
        [ "$INSTALL_COMMITTED" -eq 0 ] &&
        [ "$rc" -ne 0 ]; then
        rollback_install || true
    fi

    cleanup_staging
    exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' INT TERM

write_netplan_config() {
    local output_file="$1"
    cat >"$output_file" <<EOF
network:
  version: 2
  renderer: NetworkManager

  ethernets:
    ${ETH_IF}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${LAN_CIDR}
      optional: true
EOF
    chmod 600 "$output_file"
}

write_dnsmasq_config() {
    local output_file="$1"
    cat >"$output_file" <<EOF
# Managed by kickpi_neptune_setup.sh
interface=${ETH_IF}
bind-dynamic
dhcp-authoritative

dhcp-range=${PRINTER_IP},${PRINTER_IP},255.255.255.0,${DHCP_LEASE}
EOF

    if [ -n "$PRINTER_MAC" ]; then
        printf 'dhcp-host=%s,%s,neptune,%s\n' \
            "$PRINTER_MAC" "$PRINTER_IP" "$DHCP_LEASE" >>"$output_file"
    fi

    cat >>"$output_file" <<EOF

dhcp-option=option:router,${LAN_IP}
dhcp-option=option:dns-server,${LAN_IP}
domain=printer.lan
local=/printer.lan/
log-dhcp
EOF
}

write_nftables_config() {
    local output_file="$1"
    cat >"$output_file" <<EOF
table inet kickpi_printer {
    chain forward {
        type filter hook forward priority 0;
        policy accept;

        iifname "${ETH_IF}" oifname "${WIFI_IF}" accept
        iifname "${WIFI_IF}" oifname "${ETH_IF}" \\
            ip daddr ${PRINTER_IP}/32 \\
            ct state established,related accept
    }

    chain postrouting {
        type nat hook postrouting priority srcnat;
        policy accept;

        ip saddr ${PRINTER_IP}/32 \\
            oifname "${WIFI_IF}" \\
            masquerade
    }
}
EOF
}

write_nat_service() {
    local output_file="$1"
    cat >"$output_file" <<EOF
[Unit]
Description=KickPi Neptune printer NAT
After=NetworkManager.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet kickpi_printer
ExecStart=/usr/sbin/sysctl -w net.ipv4.ip_forward=1
ExecStart=/usr/sbin/nft -f ${NAT_CONFIG}
ExecStop=-/usr/sbin/nft delete table inet kickpi_printer

[Install]
WantedBy=multi-user.target
EOF
}

write_sysctl_config() {
    local output_file="$1"
    printf '%s\n' '# Managed by kickpi_neptune_setup.sh' >"$output_file"
    printf '%s\n' 'net.ipv4.ip_forward=1' >>"$output_file"
}

write_nginx_config() {
    local output_file="$1"
    cat >"$output_file" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

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

        # ElegooSlicer 1.5.x may send Origin: file://.
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

write_nginx_test_config() {
    local output_file="$1"
    cat >"$output_file" <<EOF
pid ${STAGING_DIR}/nginx.pid;
error_log stderr notice;
events {}
http {
    access_log off;
    include ${STAGING_DIR}/kickpi-printer.conf;
}
EOF
}

write_camera_launcher() {
    local output_file="$1"
    cat >"$output_file" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

DEVICE="${RESOLVED_CAMERA_DEVICE}"
PORT="${CAMERA_PORT}"
RESOLUTION="${CAMERA_RESOLUTION}"
FPS="${CAMERA_FPS}"

printf 'KickPi camera waiting for %s\n' "\$DEVICE"
while [ ! -e "\$DEVICE" ]; do
    sleep 3
done

[ -x /usr/bin/ustreamer ] || {
    printf 'ERROR: /usr/bin/ustreamer is not installed.\n' >&2
    exit 1
}

exec /usr/bin/ustreamer \\
    --device="\$DEVICE" \\
    --host=0.0.0.0 \\
    --port="\$PORT" \\
    --resolution="\$RESOLUTION" \\
    --desired-fps="\$FPS" \\
    --format=MJPEG \\
    --persistent \\
    --allow-origin='*'
EOF
    chmod 755 "$output_file"
}

write_camera_service() {
    local output_file="$1"
    cat >"$output_file" <<EOF
[Unit]
Description=KickPi USB webcam stream
After=network.target

[Service]
Type=simple
ExecStart=${CAMERA_LAUNCHER}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
}

render_all_configs() {
    make_staging_dir
    if [ "$CAMERA_ENABLED" = "yes" ]; then
        resolve_camera_device
    else
        RESOLVED_CAMERA_DEVICE="disabled"
    fi

    write_netplan_config "${STAGING_DIR}/netplan-root${NETPLAN_FILE}"
    write_dnsmasq_config "${STAGING_DIR}/kickpi-printer-lan.conf"
    write_nftables_config "${STAGING_DIR}/printer-nat.nft"
    write_nat_service "${STAGING_DIR}/kickpi-printer-nat.service"
    write_sysctl_config "${STAGING_DIR}/99-kickpi-printer.conf"
    write_nginx_config "${STAGING_DIR}/kickpi-printer.conf"
    write_nginx_test_config "${STAGING_DIR}/nginx-test.conf"
    if [ "$CAMERA_ENABLED" = "yes" ]; then
        write_camera_launcher "${STAGING_DIR}/kickpi-ustreamer-start"
        write_camera_service "${STAGING_DIR}/kickpi-ustreamer.service"
    fi
}

validate_staged_configs() {
    log "Validating generated configurations"
    netplan generate --root-dir "${STAGING_DIR}/netplan-root"
    dnsmasq --test --conf-file="${STAGING_DIR}/kickpi-printer-lan.conf"
    nft -c -f "${STAGING_DIR}/printer-nat.nft"
    nginx -t -q -p "${STAGING_DIR}/" -c "${STAGING_DIR}/nginx-test.conf"
}

install_packages() {
    local packages=(curl dnsmasq iproute2 iputils-ping netplan.io network-manager nftables nginx v4l-utils)

    if [ "$CAMERA_ENABLED" = "yes" ]; then
        packages+=(ustreamer)
    fi
    if [ "$SKIP_APT" = "yes" ]; then
        log "Skipping package installation because SKIP_APT=yes"
        return 0
    fi

    log "Updating package metadata"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update

    if [ "$CAMERA_ENABLED" = "yes" ] && ! apt-cache show ustreamer >/dev/null 2>&1; then
        log "Enabling Ubuntu Universe for ustreamer"
        apt-get install -y software-properties-common
        add-apt-repository -y universe
        apt-get update
    fi

    log "Installing required packages"
    apt-get install -y "${packages[@]}"
}

require_runtime_commands() {
    require_commands awk curl dnsmasq flock grep install ip mktemp netplan nft nginx nmcli sed ss sysctl systemctl systemd-analyze
    if [ "$CAMERA_ENABLED" = "yes" ]; then
        [ -x /usr/bin/ustreamer ] || fail "ustreamer is required when CAMERA_ENABLED=yes."
    fi
}

stop_managed_services() {
    systemctl stop kickpi-ustreamer.service >/dev/null 2>&1 || true
    systemctl stop kickpi-printer-nat.service >/dev/null 2>&1 || true
    systemctl stop dnsmasq.service >/dev/null 2>&1 || true
    systemctl stop nginx.service >/dev/null 2>&1 || true
}

install_managed_files() {
    INSTALL_TOUCHED=1
    stop_managed_services

    install -D -o root -g root -m 0600 "${STAGING_DIR}/netplan-root${NETPLAN_FILE}" "$NETPLAN_FILE"
    if [ "$LEGACY_NETPLAN_FILE" != "$NETPLAN_FILE" ]; then
        rm -f -- "$LEGACY_NETPLAN_FILE"
    fi
    install -D -o root -g root -m 0644 "${STAGING_DIR}/kickpi-printer-lan.conf" "$DNSMASQ_CONFIG"
    install -D -o root -g root -m 0644 "${STAGING_DIR}/printer-nat.nft" "$NAT_CONFIG"
    install -D -o root -g root -m 0644 "${STAGING_DIR}/kickpi-printer-nat.service" "$NAT_SERVICE"
    install -D -o root -g root -m 0644 "${STAGING_DIR}/99-kickpi-printer.conf" "$SYSCTL_CONFIG"
    install -D -o root -g root -m 0644 "${STAGING_DIR}/kickpi-printer.conf" "$NGINX_CONFIG"

    rm -f -- "$OLD_STANDARD_CONFIG"
    rm -f -- "$NGINX_DEFAULT_SITE"

    if [ "$CAMERA_ENABLED" = "yes" ]; then
        install -D -o root -g root -m 0755 "${STAGING_DIR}/kickpi-ustreamer-start" "$CAMERA_LAUNCHER"
        install -D -o root -g root -m 0644 "${STAGING_DIR}/kickpi-ustreamer.service" "$CAMERA_SERVICE"
    else
        rm -f -- "$CAMERA_LAUNCHER"
        rm -f -- "$CAMERA_SERVICE"
    fi
}

validate_installed_configs() {
    log "Validating installed configurations"
    netplan generate
    dnsmasq --test
    nft -c -f "$NAT_CONFIG"
    nginx -t
    if [ "$CAMERA_ENABLED" = "yes" ]; then
        systemd-analyze verify "$NAT_SERVICE" "$CAMERA_SERVICE"
    else
        systemd-analyze verify "$NAT_SERVICE"
    fi
    if nginx -T 2>&1 | grep -qE 'listen[[:space:]]+([^;]*:)?8081([[:space:];]|$)'; then
        fail "An Nginx configuration still listens on port 8081."
    fi
}

wait_for_ethernet_address() {
    local tries=20
    while [ "$tries" -gt 0 ]; do
        if ip -4 -o addr show dev "$ETH_IF" | grep -q "[[:space:]]${LAN_IP}/24[[:space:]]"; then
            return 0
        fi
        sleep 1
        tries=$((tries - 1))
    done
    return 1
}

wait_for_tcp_listener() {
    local port="$1"
    local tries="${2:-15}"
    while [ "$tries" -gt 0 ]; do
        if ss -lnt | grep -qE "[:.]${port}[[:space:]]"; then
            return 0
        fi
        sleep 1
        tries=$((tries - 1))
    done
    return 1
}

activate_services() {
    log "Applying the Ethernet configuration"
    netplan apply
    wait_for_ethernet_address || fail "Expected ${LAN_IP}/24 was not applied to ${ETH_IF}."

    sysctl --system >/dev/null
    [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] || fail "IPv4 forwarding was not enabled."

    systemctl daemon-reload
    systemctl enable dnsmasq.service nginx.service kickpi-printer-nat.service >/dev/null
    systemctl restart kickpi-printer-nat.service
    systemctl restart dnsmasq.service
    systemctl restart nginx.service

    if [ "$CAMERA_ENABLED" = "yes" ]; then
        systemctl enable kickpi-ustreamer.service >/dev/null
        systemctl restart kickpi-ustreamer.service
    else
        systemctl disable kickpi-ustreamer.service >/dev/null 2>&1 || true
    fi
}

verify_core_services() {
    local service

    log "Verifying services and listeners"
    for service in dnsmasq.service nginx.service kickpi-printer-nat.service; do
        systemctl is-active --quiet "$service" || fail "Service is not active: $service"
    done
    if [ "$CAMERA_ENABLED" = "yes" ]; then
        systemctl is-active --quiet kickpi-ustreamer.service || fail "Camera service is not active."
    fi
    nft list table inet kickpi_printer >/dev/null 2>&1 || fail "The nftables NAT table is not active."
    wait_for_tcp_listener 80 15 || fail "Nginx is not listening on port 80."
    if ss -lnt | grep -qE '[:.]8081[[:space:]]'; then
        fail "Port 8081 is still listening; expected port 80 only."
    fi

    if [ "$CAMERA_ENABLED" = "yes" ]; then
        if [ -e "$RESOLVED_CAMERA_DEVICE" ]; then
            wait_for_tcp_listener "$CAMERA_PORT" 15 || fail "The camera exists, but port ${CAMERA_PORT} is not listening."
        else
            warn "Camera service is waiting for ${RESOLVED_CAMERA_DEVICE}."
        fi
    fi
}

wait_for_printer_http() {
    local tries="$PRINTER_WAIT_SECONDS"
    while [ "$tries" -gt 0 ]; do
        if curl -fsS --max-time 3 "http://${PRINTER_IP}/server/info" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        tries=$((tries - 1))
    done
    return 1
}

check_proxy() {
    local wifi_ip info token_body token ws_headers ws_status

    wifi_ip="$(get_wifi_ip)"
    [ -n "$wifi_ip" ] || { error "No IPv4 address found on ${WIFI_IF}."; return 1; }
    log "Checking Moonraker through http://${wifi_ip}/"

    info="$(curl -fsS --max-time 5 "http://${wifi_ip}/server/info")" || {
        error "Moonraker /server/info is not reachable through KickPi."
        return 1
    }
    printf '%s' "$info" | grep -q '"klippy_state"[[:space:]]*:[[:space:]]*"ready"' || {
        error "Moonraker responded, but Klipper is not ready."
        return 1
    }

    token_body="$(curl -fsS --max-time 5 "http://${wifi_ip}/access/oneshot_token")" || {
        error "Moonraker did not issue a one-shot token."
        return 1
    }
    token="$(printf '%s' "$token_body" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$token" ] || { error "Could not parse the Moonraker one-shot token."; return 1; }

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
    printf '%s' "$ws_status" | grep -q ' 101 ' || {
        error "ElegooSlicer-compatible WebSocket test failed: ${ws_status:-no response}"
        return 1
    }
    if ss -lnt | grep -qE '[:.]8081[[:space:]]'; then
        error "Port 8081 is still listening; expected port 80 only."
        return 1
    fi

    printf '\nMoonraker: ready\n'
    printf 'WebSocket: 101 Switching Protocols\n'
    printf 'Printer URL: http://%s/\n' "$wifi_ip"
    printf 'Port 8081: disabled\n'
}

backup_proxy_path() {
    local path="$1"
    local backup_dir="$2"
    local destination
    if [ -e "$path" ] || [ -L "$path" ]; then
        destination="${backup_dir}/files/$(dirname -- "${path#/}")"
        mkdir -p "$destination"
        cp -a -- "$path" "$destination/"
    fi
}

restore_proxy_paths() {
    local backup_dir="$1"
    local path saved
    local proxy_paths=("$NGINX_CONFIG" "$OLD_STANDARD_CONFIG" "$NGINX_DEFAULT_SITE")

    for path in "${proxy_paths[@]}"; do
        saved="${backup_dir}/files/${path#/}"
        rm -f -- "$path"
        if [ -e "$saved" ] || [ -L "$saved" ]; then
            mkdir -p "$(dirname -- "$path")"
            cp -a -- "$saved" "$path"
        fi
    done
}

apply_proxy() {
    local backup_dir path
    local proxy_paths=("$NGINX_CONFIG" "$OLD_STANDARD_CONFIG" "$NGINX_DEFAULT_SITE")

    require_root apply
    acquire_lock
    validate_settings
    require_commands awk curl flock grep install ip mktemp nginx sed ss systemctl
    curl -fsS --max-time 5 "http://${PRINTER_IP}/server/info" >/dev/null ||
        fail "The printer is not reachable at http://${PRINTER_IP}/server/info."

    make_staging_dir
    write_nginx_config "${STAGING_DIR}/kickpi-printer.conf"
    write_nginx_test_config "${STAGING_DIR}/nginx-test.conf"
    nginx -t -q -p "${STAGING_DIR}/" -c "${STAGING_DIR}/nginx-test.conf"

    backup_dir="${NGINX_BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "${backup_dir}/files"
    for path in "${proxy_paths[@]}"; do backup_proxy_path "$path" "$backup_dir"; done

    install -D -o root -g root -m 0644 "${STAGING_DIR}/kickpi-printer.conf" "$NGINX_CONFIG"
    rm -f -- "$OLD_STANDARD_CONFIG" "$NGINX_DEFAULT_SITE"

    if ! nginx -t; then
        warn "Nginx validation failed; restoring the previous configuration."
        restore_proxy_paths "$backup_dir"
        nginx -t || true
        fail "The new proxy configuration was not applied."
    fi
    if ! systemctl reload nginx; then
        warn "Nginx reload failed; restoring and reloading the previous configuration."
        restore_proxy_paths "$backup_dir"
        nginx -t && systemctl reload nginx || true
        fail "The new proxy configuration was rolled back."
    fi
    if ! check_proxy; then
        warn "Proxy health check failed; restoring the previous configuration."
        restore_proxy_paths "$backup_dir"
        nginx -t && systemctl reload nginx || true
        fail "The new proxy configuration failed its health check and was rolled back."
    fi
    printf '\nNginx backup: %s\n' "$backup_dir"
}

run_dry_install() {
    require_root install --dry-run
    acquire_lock
    validate_settings
    check_operating_system
    require_commands awk flock grep ip mktemp nmcli systemctl
    check_network_preflight
    require_runtime_commands
    render_all_configs
    validate_staged_configs

    printf '\nDry run successful. No system files or services were changed.\n'
    printf 'Camera device: %s\n' "$RESOLVED_CAMERA_DEVICE"
}

confirm_full_install() {
    local answer
    printf '\nThis operation will configure:\n'
    printf '  - %s as %s\n' "$ETH_IF" "$LAN_CIDR"
    printf '  - dnsmasq DHCP for %s\n' "$PRINTER_IP"
    printf '  - nftables forwarding/NAT through %s\n' "$WIFI_IF"
    printf '  - Nginx printer proxy on port 80\n'
    if [ "$CAMERA_ENABLED" = "yes" ]; then
        printf '  - ustreamer camera service on port %s\n' "$CAMERA_PORT"
    else
        printf '  - camera service disabled\n'
    fi
    printf '\nWi-Fi configuration and credentials are not modified.\n'
    read -r -p 'Continue with the full installation? [y/N] ' answer
    case "$answer" in y|Y|yes|YES) ;; *) printf 'Cancelled.\n'; return 1 ;; esac
}

full_install() {
    local mode="${1:-}"
    local wifi_ip

    if [ "$mode" = "--dry-run" ]; then
        run_dry_install
        return 0
    fi
    [ -z "$mode" ] || [ "$mode" = "--yes" ] || fail "Unknown install option: $mode"

    require_root install "$mode"
    acquire_lock
    validate_settings
    check_operating_system
    require_commands awk apt-get flock grep ip mktemp nmcli systemctl
    check_network_preflight
    if [ "$mode" != "--yes" ]; then confirm_full_install || return 0; fi

    INSTALL_IN_PROGRESS=1
    create_install_backup
    install_packages
    require_runtime_commands
    render_all_configs
    validate_staged_configs
    install_managed_files
    validate_installed_configs
    activate_services
    verify_core_services

    INSTALL_COMMITTED=1
    INSTALL_IN_PROGRESS=0
    wifi_ip="$(get_wifi_ip)"

    printf '\n============================================================\n'
    printf ' KickPi Neptune installation completed\n'
    printf '============================================================\n'
    printf 'Printer URL:   http://%s/\n' "$wifi_ip"
    printf 'Printer LAN:   %s\n' "$LAN_CIDR"
    printf 'Printer IP:    %s\n' "$PRINTER_IP"
    if [ "$CAMERA_ENABLED" = "yes" ]; then
        printf 'Camera URL:    http://%s:%s/\n' "$wifi_ip" "$CAMERA_PORT"
        printf 'Camera device: %s\n' "$RESOLVED_CAMERA_DEVICE"
    fi
    printf 'Backup:        %s\n' "$BACKUP_DIR"

    if wait_for_printer_http; then
        check_proxy || warn "Core installation succeeded, but the printer proxy health check needs attention."
    else
        warn "The printer did not become reachable within ${PRINTER_WAIT_SECONDS}s. Power/connect it, then run: $SCRIPT_PATH status"
    fi
}

show_status() {
    local service
    local rc=0

    validate_settings
    require_commands awk curl grep ip sed ss sysctl systemctl
    printf '\nKickPi Neptune status\n'
    printf '%s\n' '----------------------'
    ip -br addr show dev "$WIFI_IF" 2>/dev/null || true
    ip -br addr show dev "$ETH_IF" 2>/dev/null || true

    printf '\nServices:\n'
    for service in NetworkManager dnsmasq nginx kickpi-printer-nat kickpi-ustreamer; do
        printf '  %-24s active=%-10s enabled=%s\n' \
            "$service" \
            "$(systemctl is-active "$service" 2>/dev/null || true)" \
            "$(systemctl is-enabled "$service" 2>/dev/null || true)"
    done

    printf '\nListeners:\n'
    ss -lnt | grep -E ":(80|${CAMERA_PORT}|8081)[[:space:]]" || true

    if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" != "1" ]; then error "IPv4 forwarding is not enabled."; rc=1; fi
    if ! systemctl is-active --quiet nginx; then error "Nginx is not active."; rc=1; fi
    if ! systemctl is-active --quiet dnsmasq; then error "dnsmasq is not active."; rc=1; fi
    if ! systemctl is-active --quiet kickpi-printer-nat; then error "Printer NAT service is not active."; rc=1; fi
    check_proxy || rc=1
    return "$rc"
}

show_help() {
    cat <<EOF
KickPi Neptune Manager ${SCRIPT_VERSION}

Usage: $(basename "$SCRIPT_PATH") COMMAND

Commands:
  install            Full standalone installation with confirmation.
  install --yes      Full standalone installation without confirmation.
  install --dry-run  Render and validate everything without changing the system.
  status             Check network, services, Moonraker, and WebSocket.
  apply              Safely repair/reapply only the port-80 Nginx proxy.
  help               Show this help.
  version            Show the script version.

Environment overrides:
  WIFI_IF, ETH_IF, LAN_CIDR, LAN_IP, PRINTER_IP, PRINTER_MAC
  CAMERA_ENABLED, CAMERA_DEVICE, CAMERA_PORT, CAMERA_RESOLUTION, CAMERA_FPS
  SKIP_APT, PRINTER_WAIT_SECONDS

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
3) Validate a full installation (dry run)
4) Run the complete standalone installation
5) Exit
EOF
        read -r -p 'Choose [1-5]: ' choice
        case "$choice" in
            1) show_status || true ;;
            2) run_privileged_command apply || warn "The port-80 proxy repair failed." ;;
            3) run_privileged_command install --dry-run || warn "The installation dry run failed." ;;
            4) run_privileged_command install || warn "The complete installation did not finish successfully." ;;
            5) return 0 ;;
            *) warn "Invalid choice: $choice" ;;
        esac
    done
}

main() {
    local command="${1:-}"

    case "$command" in
        "") interactive_menu ;;
        install)
            [ "$#" -le 2 ] || fail "Too many install arguments."
            full_install "${2:-}"
            ;;
        status)
            [ "$#" -eq 1 ] || fail "The status command takes no arguments."
            show_status
            ;;
        apply)
            [ "$#" -eq 1 ] || fail "The apply command takes no arguments."
            apply_proxy
            ;;
        help|-h|--help) show_help ;;
        version|-V|--version) printf '%s\n' "$SCRIPT_VERSION" ;;
        *) show_help; fail "Unknown command: $command" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
