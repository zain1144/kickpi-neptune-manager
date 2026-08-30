# KickPi Neptune Manager

A small Bash manager for exposing an Elegoo Neptune printer through a KickPi on standard HTTP port `80`.

It is designed for a setup where:

- KickPi connects to the home network through Wi-Fi.
- The Elegoo Neptune printer connects directly to KickPi through Ethernet.
- Moonraker is available on the printer.
- Nginx on KickPi proxies the printer to the home network.
- A camera service may continue using port `8080`.

The script also works around a WebSocket compatibility issue in newer ElegooSlicer releases. ElegooSlicer can send `Origin: file://`, which Moonraker rejects with HTTP `403`; the generated Nginx configuration supplies the printer's accepted internal origin upstream.

## Default network layout

| Component | Default value |
| --- | --- |
| KickPi Wi-Fi interface | `wlan0` |
| KickPi Ethernet interface | `eth0` |
| KickPi printer-side address | `192.168.50.1` |
| Printer address | `192.168.50.20` |
| Printer URL on the home LAN | `http://<KICKPI-WIFI-IP>/` |
| Optional camera URL | `http://<KICKPI-WIFI-IP>:8080/` |
| Old printer proxy port | `8081` disabled |

The Wi-Fi address is detected automatically. Interface names and printer addresses can be overridden with environment variables.

## Requirements

- A Debian or Ubuntu based KickPi installation.
- An already configured direct Ethernet connection between KickPi and the printer.
- `nginx`, `curl`, `ip`, `ss`, `sudo`, and `systemctl`.
- Moonraker reachable from KickPi at `http://192.168.50.20/` by default.
- Run the script over the Wi-Fi SSH connection, not through the printer-side Ethernet interface.

## Installation

Clone the repository and install the script:

```bash
git clone https://github.com/zain1144/kickpi-neptune-manager.git
cd kickpi-neptune-manager
chmod +x kickpi_neptune_setup.sh
sudo install -m 0755 kickpi_neptune_setup.sh /home/kickpi/kickpi_neptune_setup.sh
```

Replace `zain1144` with your GitHub username.

The script does not contain SSH passwords, Moonraker tokens, or printer configuration files.

## Usage

Open the interactive menu:

```bash
/home/kickpi/kickpi_neptune_setup.sh
```

Check the setup without changing anything:

```bash
/home/kickpi/kickpi_neptune_setup.sh status
```

Apply or repair the port-80 proxy:

```bash
/home/kickpi/kickpi_neptune_setup.sh apply
```

The `apply` command automatically requests `sudo`, creates an Nginx backup, validates the new configuration with `nginx -t`, and reloads Nginx. If the reload fails, it restores the previous configuration and reports failure.

Show command help:

```bash
/home/kickpi/kickpi_neptune_setup.sh help
```

## Full-install command

The manager contains an optional `install` command intended for the original machine on which a verified legacy full-setup backup already exists at:

```text
/home/kickpi/kickpi_neptune_setup.legacy-8081.sh
```

That private legacy backup is deliberately not included in this repository. It changes Netplan, DHCP, NAT, camera services, and installed packages. For normal use and proxy repair, use `status` and `apply`; they do not require the legacy installer.

Do not run `install` on a fresh machine unless you have reviewed and supplied your own compatible full-setup script. The manager applies the port-80 configuration after that installer completes.

## Custom addresses and interfaces

Override defaults for one command by supplying environment variables:

```bash
WIFI_IF=wlan0 \
ETH_IF=eth0 \
LAN_IP=192.168.50.1 \
PRINTER_IP=192.168.50.20 \
./kickpi_neptune_setup.sh status
```

The same variables are preserved when the script requests `sudo`.

## What `status` verifies

The status test checks:

1. The Wi-Fi and Ethernet addresses.
2. Listeners on ports `80`, `8080`, and `8081`.
3. Moonraker's `/server/info` endpoint and Klipper's `ready` state.
4. Creation of a Moonraker one-shot token.
5. A real WebSocket upgrade using `Origin: file://`.
6. That port `8081` is no longer listening.

A successful result ends with output similar to:

```text
Moonraker: ready
WebSocket: 101 Switching Protocols
Printer URL: http://192.168.x.x/
Port 8081: disabled
```

## Nginx backups and rollback

Before replacing the active proxy configuration, the script stores a timestamped backup under:

```text
/etc/nginx/kickpi-neptune-backups/
```

It validates the generated configuration before reload. If reload fails, the previous configuration is restored and reloaded where possible.

## ElegooSlicer

Add the printer using only the KickPi Wi-Fi address without `:8081`:

```text
http://<KICKPI-WIFI-IP>/
```

Example:

```text
http://192.168.1.50/
```

If ElegooSlicer still reports `Connection failed`:

```bash
./kickpi_neptune_setup.sh status
sudo nginx -t
systemctl is-active nginx
```

Also confirm that the printer itself is powered on and Moonraker reports Klipper as `ready`.

## Security

The proxy is intended for a trusted home LAN. It does not add authentication or TLS. Do not forward port `80` from your internet router and do not expose the printer directly to the public internet.

Do not commit SSH passwords, Moonraker credentials, `printer.cfg`, `moonraker.conf`, or private backups to GitHub.

## Tested setup

- Elegoo Neptune 4 Pro with OpenNeptune.
- KickPi connected to the home network over Wi-Fi and directly to the printer over Ethernet.
- Printer at `192.168.50.20`.
- Nginx printer proxy on port `80`.
- Camera retained on port `8080`.
- WebSocket handshake verified as `101 Switching Protocols` with `Origin: file://`.

## License

No license has been selected yet. Add a license before inviting public reuse or contributions.

---

## العربية

هذا السكربت يتيح الوصول إلى طابعة Elegoo Neptune عبر عنوان Wi-Fi الخاص بجهاز KickPi على المنفذ القياسي `80`، مع إبقاء الكاميرا على `8080` وتعطيل المنفذ القديم `8081`.

للفحص فقط:

```bash
./kickpi_neptune_setup.sh status
```

لتطبيق أو إصلاح إعداد Nginx:

```bash
./kickpi_neptune_setup.sh apply
```

عنوان الطابعة داخل ElegooSlicer يكون:

```text
http://<عنوان-Wi-Fi-الخاص-KickPi>/
```

لا ترفع النسخة القديمة أو كلمات مرور SSH أو ملفات إعداد Klipper وMoonraker إلى GitHub.
