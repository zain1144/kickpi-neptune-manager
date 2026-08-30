#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
INSTALLER="${REPO_DIR}/kickpi_neptune_setup.sh"

export CAMERA_ENABLED=yes

# shellcheck source=/dev/null
source "$INSTALLER"

validate_settings
require_commands bash grep mktemp
render_all_configs

bash -n "$INSTALLER"
bash -n "${STAGING_DIR}/kickpi-ustreamer-start"
python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); compile(p.read_bytes(), str(p), "exec")' \
    "${STAGING_DIR}/kickpi-camera-gateway"

grep -qF 'listen 80 default_server;' "${STAGING_DIR}/kickpi-printer.conf"
grep -qF 'listen 8080;' "${STAGING_DIR}/kickpi-printer.conf"
grep -qF 'auth_request /_kickpi_camera_wake;' "${STAGING_DIR}/kickpi-printer.conf"
grep -qF 'proxy_pass http://127.0.0.1:18081;' "${STAGING_DIR}/kickpi-printer.conf"
grep -qF 'proxy_set_header Origin http://192.168.50.20;' "${STAGING_DIR}/kickpi-printer.conf"
grep -qF 'CONFIGURED_DEVICE=""' "${STAGING_DIR}/kickpi-ustreamer-start"
grep -qF 'SLOWDOWN_ARGS=(--slowdown)' "${STAGING_DIR}/kickpi-ustreamer-start"
grep -qF -- '--host=127.0.0.1' "${STAGING_DIR}/kickpi-ustreamer-start"
grep -qF 'CONTROL_HOST = "127.0.0.1"' "${STAGING_DIR}/kickpi-camera-gateway"
grep -qF 'def backend_online():' "${STAGING_DIR}/kickpi-camera-gateway"
grep -qF 'IDLE_MODE = "stop"' "${STAGING_DIR}/kickpi-camera-gateway"
grep -qF 'IDLE_TIMEOUT = 300' "${STAGING_DIR}/kickpi-camera-gateway"
grep -qF 'dhcp-range=192.168.50.20,192.168.50.20,255.255.255.0,24h' \
    "${STAGING_DIR}/kickpi-printer-lan.conf"
grep -qF 'masquerade' "${STAGING_DIR}/printer-nat.nft"
grep -qF '192.168.50.1/24' "${STAGING_DIR}/netplan-root${NETPLAN_FILE}"

# Exercise managed-file backup and restore without touching the host system.
ROLLBACK_FIXTURE="${STAGING_DIR}/rollback-fixture"
ORIGINAL_FILE="${ROLLBACK_FIXTURE}/etc/original.conf"
ORIGINALLY_ABSENT_FILE="${ROLLBACK_FIXTURE}/etc/absent.conf"
BACKUP_DIR="${ROLLBACK_FIXTURE}/backup"
# Consumed by restore_managed_paths from the sourced installer.
# shellcheck disable=SC2034
MANAGED_PATHS=("$ORIGINAL_FILE" "$ORIGINALLY_ABSENT_FILE")

mkdir -p "$(dirname -- "$ORIGINAL_FILE")" "${BACKUP_DIR}/files"
printf '%s\n' 'original-value' >"$ORIGINAL_FILE"
copy_path_to_backup "$ORIGINAL_FILE"
copy_path_to_backup "$ORIGINALLY_ABSENT_FILE"

printf '%s\n' 'changed-value' >"$ORIGINAL_FILE"
printf '%s\n' 'created-during-install' >"$ORIGINALLY_ABSENT_FILE"
restore_managed_paths

grep -qFx 'original-value' "$ORIGINAL_FILE"
[ ! -e "$ORIGINALLY_ABSENT_FILE" ]

if command -v netplan >/dev/null 2>&1 &&
    command -v dnsmasq >/dev/null 2>&1 &&
    command -v nft >/dev/null 2>&1 &&
    command -v nginx >/dev/null 2>&1; then
    validate_staged_configs
else
    warn "Runtime validators are unavailable; completed render-only checks."
fi

printf '\nSmoke test passed. No system files or services were changed.\n'
