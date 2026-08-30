# KickPi Neptune Manager

Standalone bootstrap and recovery installer for connecting an Elegoo Neptune printer to a KickPi over a dedicated Ethernet cable.

The installer builds the complete KickPi side from a clean Ubuntu installation:

- Preserves the existing Wi-Fi connection and credentials.
- Configures the printer-side Ethernet interface with a static address.
- Installs and configures `dnsmasq` to give the printer a fixed address.
- Enables IPv4 forwarding and nftables NAT so the printer can reach the internet through Wi-Fi.
- Installs an Nginx reverse proxy on standard HTTP port `80`.
- Fixes the `Origin: file://` WebSocket incompatibility seen with newer ElegooSlicer releases.
- Optionally installs an on-demand USB camera gateway on port `8080`: it starts `ustreamer` for the first viewer and stops capture after a configurable idle timeout.
- Creates timestamped backups and automatically rolls managed configuration back when installation fails after files are changed.
- Provides status, dry-run, and proxy-only repair commands.

No separate legacy installer is required.

## Tested platform

- KickPi K2B.
- Ubuntu `22.04.5 LTS` (`aarch64`).
- NetworkManager with Netplan.
- Elegoo Neptune 4 Pro running OpenNeptune/Moonraker.
- KickPi connected to the home network through Wi-Fi.
- Printer connected directly to KickPi through Ethernet.
- USB UVC camera with `ustreamer`.

Other Ubuntu releases produce a warning and should be tested with `install --dry-run` first. Non-Ubuntu distributions are rejected intentionally.

## Default network layout

| Component | Default |
| --- | --- |
| KickPi home-network interface | `wlan0` using existing Wi-Fi/DHCP |
| KickPi printer interface | `eth0` |
| KickPi printer-side address | `192.168.50.1/24` |
| Printer address | `192.168.50.20` |
| Printer URL from the home LAN | `http://<KICKPI-WIFI-IP>/` |
| Camera URL | `http://<KICKPI-WIFI-IP>:8080/` |
| Legacy printer port | `8081` disabled |

The home Wi-Fi network must not also use `192.168.50.0/24`. The preflight check refuses overlapping networks.

## Fresh-install prerequisites

Before running the script on a newly installed KickPi:

1. Install Ubuntu 22.04 for the KickPi.
2. Connect the KickPi to your Wi-Fi network.
3. Confirm that NetworkManager is active:

   ```bash
   systemctl is-active NetworkManager
   ```

4. Find the Wi-Fi address:

   ```bash
   ip -4 -br addr show wlan0
   ```

5. Connect through that Wi-Fi address using SSH.
6. Connect the printer directly to `eth0`.
7. Connect the USB camera if camera support is wanted.

The installer deliberately does not ask for, store, or modify Wi-Fi credentials. Establish Wi-Fi before using it.

## Download

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/zain1144/kickpi-neptune-manager.git
cd kickpi-neptune-manager
chmod +x kickpi_neptune_setup.sh
```

## Validate before changing anything

Run the complete generation and configuration validation path without writing to `/etc` or restarting services:

```bash
./kickpi_neptune_setup.sh install --dry-run
```

The script automatically requests `sudo`. A successful result ends with:

```text
Dry run successful. No system files or services were changed.
```

The dry run renders all files and validates generated Netplan, dnsmasq, nftables, Nginx, and camera-launcher content using the tools already installed on the machine. Installed systemd units are additionally checked during the real transaction before services start. On a completely clean image, install the runtime packages first or proceed with the confirmed full installer, which installs them automatically.

## Full standalone installation

Run interactively:

```bash
./kickpi_neptune_setup.sh install
```

Review the displayed interfaces and addresses, then confirm. For non-interactive installation after reviewing the configuration:

```bash
./kickpi_neptune_setup.sh install --yes
```

The full installer performs these phases:

1. Validates addresses, interfaces, operating system, NetworkManager, Wi-Fi connectivity, and SSH path.
2. Refuses to continue if SSH is connected through an address other than the current Wi-Fi address.
3. Creates a backup under `/root/kickpi-neptune-backups/`.
4. Installs required Ubuntu packages.
5. Generates all configuration in a private temporary directory.
6. Syntax-checks generated configuration before touching the active files.
7. Installs Netplan, DHCP, NAT, Nginx, systemd, sysctl, and optional camera files.
8. Validates the installed configuration and installed systemd units again.
9. Applies the Ethernet configuration and starts/enables the services.
10. Verifies services, forwarding, nftables, ports, Moonraker, and the ElegooSlicer-compatible WebSocket handshake.

If a failure occurs after managed files are changed, the installer restores the previous managed files and service states. Packages installed by APT are intentionally not removed during rollback.

## Normal usage

Open the menu:

```bash
./kickpi_neptune_setup.sh
```

Check the complete setup without changing it:

```bash
./kickpi_neptune_setup.sh status
```

Repair only the port-80 Nginx proxy:

```bash
./kickpi_neptune_setup.sh apply
```

Control and inspect the camera:

```bash
./kickpi_neptune_setup.sh camera detect
./kickpi_neptune_setup.sh camera status
./kickpi_neptune_setup.sh camera start
./kickpi_neptune_setup.sh camera stop
./kickpi_neptune_setup.sh camera restart
```

Show help and version:

```bash
./kickpi_neptune_setup.sh help
./kickpi_neptune_setup.sh version
```

## Configuration overrides

Defaults can be overridden for one installation with environment variables. The script preserves them when requesting `sudo`.

```bash
WIFI_IF=wlan0 \
ETH_IF=eth0 \
LAN_CIDR=192.168.50.1/24 \
LAN_IP=192.168.50.1 \
PRINTER_IP=192.168.50.20 \
CAMERA_ENABLED=yes \
CAMERA_PORT=8080 \
CAMERA_RESOLUTION=1280x720 \
CAMERA_FPS=30 \
CAMERA_IDLE_MODE=stop \
CAMERA_IDLE_TIMEOUT=300 \
./kickpi_neptune_setup.sh install --dry-run
```

After a successful dry run, repeat the same variables with `install`.

An example is provided in [`kickpi-neptune.env.example`](kickpi-neptune.env.example):

```bash
cp kickpi-neptune.env.example kickpi-neptune.env
nano kickpi-neptune.env
set -a
source ./kickpi-neptune.env
set +a
./kickpi_neptune_setup.sh install --dry-run
./kickpi_neptune_setup.sh install
```

The local `kickpi-neptune.env` file is ignored by Git.

### Available variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `WIFI_IF` | `wlan0` | Home-network Wi-Fi interface |
| `ETH_IF` | `eth0` | Direct printer Ethernet interface |
| `LAN_CIDR` | `192.168.50.1/24` | KickPi address and printer subnet |
| `LAN_IP` | Address part of `LAN_CIDR` | KickPi gateway on the printer LAN |
| `PRINTER_IP` | `192.168.50.20` | Address leased to the printer |
| `PRINTER_MAC` | empty | Optional printer MAC for an explicit DHCP host entry |
| `DHCP_LEASE` | `24h` | dnsmasq lease duration |
| `CAMERA_ENABLED` | `yes` | Set to `no` to omit/disable the camera service |
| `CAMERA_DEVICE` | auto-detected | Stable V4L by-id device, or `/dev/video0` fallback |
| `CAMERA_PORT` | `8080` | Camera HTTP port |
| `CAMERA_RESOLUTION` | `1280x720` | Camera resolution |
| `CAMERA_FPS` | `30` | Desired camera frame rate |
| `CAMERA_IDLE_MODE` | `stop` | `stop`, `slowdown`, or `always` behavior when nobody is watching |
| `CAMERA_IDLE_TIMEOUT` | `300` | Seconds with no active stream connection before stopping capture in `stop` mode |
| `CAMERA_CONTROL_PORT` | `18080` | Loopback-only gateway control port |
| `CAMERA_BACKEND_PORT` | `18081` | Loopback-only `ustreamer` backend port |
| `SKIP_APT` | `no` | Skip APT only when all dependencies are already installed |
| `PRINTER_WAIT_SECONDS` | `60` | Maximum post-install wait for Moonraker |

Only `/24` printer subnets are supported by this release.

## Camera behavior

The default `CAMERA_IDLE_MODE=stop` behavior is:

1. Nginx remains available on the public camera port `8080`.
2. A request from Fluidd or a browser asks the loopback-only gateway to start `ustreamer`.
3. Nginx proxies the unchanged camera URL to the internal backend.
4. While a stream connection is active, the backend remains running.
5. When all stream connections have closed, `ustreamer` uses `--slowdown` during the grace period and is stopped after `CAMERA_IDLE_TIMEOUT` seconds.
6. The next camera request starts it automatically again.

Fluidd camera URLs do not need to change. The first frame after a cold start may take one or two seconds. Merely configuring a webcam in Fluidd does not count as a viewer; an actual stream or snapshot request wakes it.

`CAMERA_IDLE_MODE=slowdown` keeps the backend open and relies on `ustreamer --slowdown`. `CAMERA_IDLE_MODE=always` keeps full-rate capture running.

When `CAMERA_DEVICE` is empty, the launcher detects the camera every time capture starts. It first chooses a stable device matching:

```text
/dev/v4l/by-id/*-video-index0
```

If there is no by-id match, it tries `/dev/video0`. If no camera is present, the backend waits; later connecting a UVC/V4L2 camera is enough. Replacing a USB camera normally requires only:

```bash
./kickpi_neptune_setup.sh camera restart
```

Use `CAMERA_DEVICE` only when more than one camera is attached and a specific device must be selected. Cameras that do not expose a V4L2 device, such as many CSI or IP cameras, require a different backend.

`camera stop` creates a manual pause that blocks automatic wake until `camera start`. The pause lasts until it is resumed or the KickPi reboots. Stopping capture closes the V4L2 device and usually turns off the camera LED, but USB power remains connected.

To disable camera installation:

```bash
CAMERA_ENABLED=no ./kickpi_neptune_setup.sh install --dry-run
CAMERA_ENABLED=no ./kickpi_neptune_setup.sh install
```

## ElegooSlicer compatibility

Use only the KickPi Wi-Fi URL, without `:8081`:

```text
http://<KICKPI-WIFI-IP>/
```

Newer ElegooSlicer releases may initiate the WebSocket with `Origin: file://`. Moonraker can reject that origin with HTTP `403`. The generated Nginx configuration presents `http://<PRINTER_IP>` upstream, while retaining the WebSocket upgrade headers.

The `status` command obtains a Moonraker one-shot token and performs a real handshake. Success includes:

```text
Moonraker: ready
WebSocket: 101 Switching Protocols
Port 8081: disabled
```

## Files managed on KickPi

The full installer owns these paths:

```text
/etc/netplan/99-kickpi-neptune.yaml
/etc/dnsmasq.d/kickpi-printer-lan.conf
/etc/nginx/conf.d/kickpi-printer.conf
/etc/kickpi/printer-nat.nft
/etc/systemd/system/kickpi-printer-nat.service
/etc/sysctl.d/99-kickpi-printer.conf
/usr/local/sbin/kickpi-ustreamer-start
/etc/systemd/system/kickpi-ustreamer.service
/usr/local/sbin/kickpi-camera-gateway
/etc/systemd/system/kickpi-camera-gateway.service
```

It migrates the old `/etc/netplan/10-kickpi-neptune.yaml`, disables the Ubuntu default Nginx site, and removes the known old standard proxy file when present.

## Backups and rollback

Full-install backups:

```text
/root/kickpi-neptune-backups/<timestamp>-<pid>/
```

Proxy-only backups:

```text
/etc/nginx/kickpi-neptune-backups/<timestamp>-<pid>/
```

Backups contain only the managed files, previous service states, and diagnostic network information. They do not contain Wi-Fi passwords.

## Troubleshooting

Run:

```bash
./kickpi_neptune_setup.sh status
sudo nginx -t
sudo dnsmasq --test
sudo netplan generate
systemctl --no-pager --full status kickpi-printer-nat dnsmasq nginx kickpi-camera-gateway kickpi-ustreamer
journalctl --no-pager -u kickpi-camera-gateway -u kickpi-ustreamer -n 100
```

Useful network checks:

```bash
ip -4 -br addr
ip route
ip neigh show dev eth0
sudo nft list table inet kickpi_printer
```

If the printer is not assigned `192.168.50.20`, power-cycle the printer after confirming the Ethernet cable and dnsmasq service. Supplying `PRINTER_MAC` makes the intended lease explicit.

## Security

- The proxy and camera are intended for a trusted home LAN.
- The privileged camera controller listens only on `127.0.0.1`; its Nginx wake location is marked `internal` and cannot accept arbitrary commands.
- The installer does not add authentication or TLS.
- Never forward ports `80` or `8080` from the internet router.
- Never commit Wi-Fi credentials, SSH passwords, Moonraker credentials, `printer.cfg`, `moonraker.conf`, or private backups.
- Run the full installer only while connected to the KickPi Wi-Fi address.

## Repository smoke test

On an already configured test KickPi, the included smoke test renders and validates the generated files without installing them:

```bash
sudo bash tests/smoke.sh
```

## References

- [Netplan configuration guides](https://netplan.readthedocs.io/en/stable/howto/)
- [Netplan NetworkManager configuration](https://netplan.readthedocs.io/en/latest/nm-all/)
- [Ubuntu DHCP overview](https://ubuntu.com/server/docs/explanation/networking/about-dhcp/)
- [Ubuntu 22.04 dnsmasq manual](https://manpages.ubuntu.com/manpages/jammy/man8/dnsmasq.8.html)
- [nftables manual](https://www.netfilter.org/projects/nftables/manpage.html)

## License

No license has been selected yet. Add a license before inviting public redistribution or contributions.

---

## العربية — الاستعادة السريعة

هذا الإصدار مثبت مستقل ولا يحتاج إلى سكربت `legacy-8081`. بعد تثبيت Ubuntu 22.04 وتوصيل KickPi بالـWi-Fi:

```bash
git clone https://github.com/zain1144/kickpi-neptune-manager.git
cd kickpi-neptune-manager
chmod +x kickpi_neptune_setup.sh
./kickpi_neptune_setup.sh install --dry-run
./kickpi_neptune_setup.sh install
```

السكربت لا يغيّر إعدادات أو كلمة مرور Wi-Fi. يجب الاتصال بالـWi-Fi أولاً والدخول إلى KickPi عبر عنوان Wi-Fi قبل تشغيل التثبيت.

التثبيت الكامل يضبط `eth0` وDHCP وNAT وNginx على المنفذ `80` والكاميرا اختيارياً على `8080`. وضع الكاميرا الافتراضي يشغّل الالتقاط تلقائياً عند فتحها من Fluidd، ثم يوقفه بعد خمس دقائق بلا مشاهدين، مع بقاء رابط `8080` نفسه. عند تبديل كاميرا USB يعاد اكتشافها في كل تشغيل، ويمكن تنفيذ `./kickpi_neptune_setup.sh camera restart`. عند فشل التثبيت بعد تعديل الملفات، يعيد الملفات والخدمات التي يديرها إلى حالتها السابقة.

للفحص لاحقاً:

```bash
./kickpi_neptune_setup.sh status
```

لإصلاح Nginx فقط:

```bash
./kickpi_neptune_setup.sh apply
```
