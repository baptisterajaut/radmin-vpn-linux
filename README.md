# Radmin VPN for Linux

Run [Radmin VPN](https://www.radmin-vpn.com/) on Linux via Wine. Join VPN networks, see peers, play games — all without a Windows VM.

> I did not build this because it was easier than a VM. I built it because I thought it was easier than a VM.

**AI-assisted code.** Built collaboratively between a human and Claude (Anthropic). The driver, hooks, and bridge were written with extensive AI-assisted reverse engineering of Radmin VPN's undocumented driver protocol using Ghidra. **This works, but comes with no guarantees.** Not affiliated with Famatech. Radmin VPN is proprietary — download it yourself from [radmin-vpn.com](https://www.radmin-vpn.com/). Use at your own risk.

## How it works

Radmin VPN's Windows service talks to an NDIS miniport driver for its virtual network adapter. Wine doesn't support NDIS, so we replace the driver with our own implementation that bridges to a Linux TAP device. A hook DLL handles Wine compatibility issues (adapter naming, registry permissions). The result is a fully functional Radmin VPN client running natively under Wine.

```
Linux app ← TAP (radminvpn0) ← tap_bridge ← FIFO ← rvpnnetmp.sys (Wine driver) ← RvControlSvc.exe
```

## Quick start (AppImage, recommended)

Grab `RadminVPN-Linux-x86_64.AppImage` from the [latest release](https://github.com/baptisterajaut/radmin-vpn-linux/releases/latest). Nothing to install — Wine is bundled.

> **Release candidates** (e.g. `v1.0.0-rc1`) are published as GitHub *pre-releases*. The `latest` link above always points to the newest *stable* build, so pre-releases won't appear there — grab those from the [full releases list](https://github.com/baptisterajaut/radmin-vpn-linux/releases).

```bash
chmod +x RadminVPN-Linux-x86_64.AppImage
./RadminVPN-Linux-x86_64.AppImage
```

On first launch it will prompt for the Radmin VPN installer (download `Radmin_VPN_*.exe` from [radmin-vpn.com](https://www.radmin-vpn.com/) first). A terminal opens with progress, and one sudo password prompt is needed for TAP setup.

Persistent state (wineprefix, MAC, logs) lives in `~/.local/share/radmin-vpn-linux/`.

## Prerequisites (source build / non-AppImage)

- **Wine** >= 11.0 (tested on Wine 11.5 Arch Linux and on Wine 11.6 Ubuntu 24.04)
- **mingw-w64** cross-compilers (`i686-w64-mingw32-gcc`, `x86_64-w64-mingw32-gcc`) — for building from source
- **iconv** (glibc) — for service log parsing
- **sudo** access — for TAP device creation and routing
- **TUN/TAP kernel support** — usually built-in, check with `modprobe tun`
- **Radmin VPN installer** — download from [radmin-vpn.com](https://www.radmin-vpn.com/). **Must be a 2.0.x build** (developed against 2.0.4899.9). Radmin VPN **1.4 is not supported** — it registers and opens the adapter but never finishes connecting under the Wine shim, leaving the GUI stuck at "Connecting...".

### Arch Linux

```bash
sudo pacman -S wine mingw-w64-gcc
```

### Ubuntu/Debian

```bash
sudo apt install wine64 wine32 gcc-mingw-w64
```

## Source quick start

```bash
git clone https://github.com/baptisterajaut/radmin-vpn-linux.git
cd radmin-vpn-linux

# Option A: download pre-built binaries from GitHub Releases
mkdir -p build
TAG=$(curl -sI https://github.com/baptisterajaut/radmin-vpn-linux/releases/latest | grep -i location | grep -oP 'v[\d.]+')
curl -sL "https://github.com/baptisterajaut/radmin-vpn-linux/releases/download/${TAG}/radmin-vpn-linux-${TAG}.tar.gz" \
  | tar xz -C build/

# Option B: build from source
make

# Download Radmin VPN installer from https://www.radmin-vpn.com/
./run.sh --installer ~/Downloads/Radmin_VPN_*.exe
```

On subsequent runs, just:

```bash
./run.sh
```

### Command-line flags

| Flag | Description |
|------|-------------|
| `--installer <path>` | Path to the `Radmin_VPN_*.exe` installer (first run only). |
| `--no-ui` | Run the service without launching the Radmin GUI. |
| `--no-broadcast-routes` | Don't add the broadcast/multicast → TAP routes. |
| `--filter-ui` | Launch the optional GTK4 packet-filter UI (off by default). |
| `--fix-chat` | Patch Qt's `qwindows.dll` to fix the chat-window crash under Wine (off by default). |

Both `--filter-ui` and `--fix-chat` are opt-in. The filter UI needs the `rvpn_filter_ui`
binary (built by `make`); the chat fix needs `patch_qwindows_font.py` and a Python 3 interpreter.

## Headless / server modes

Two extra launchers run Radmin VPN without a local desktop — for a VPS or datacenter host. Both install and configure exactly like `run.sh` (same wineprefix, same `--installer` first-run flow, same TAP bridge); they only differ in how the GUI is reached.

### `run_datacenter.sh` — GUI over the browser

Runs the real Radmin GUI on a virtual display (Xvfb) and serves it through VNC + noVNC, so you can configure your networks from a browser and then leave it running.

```bash
sudo apt install -y xvfb x11vnc websockify novnc   # or: make install-datacenter-deps
./run_datacenter.sh --installer ~/Downloads/Radmin_VPN_*.exe
```

| Flag | Default | Description |
|------|---------|-------------|
| `--vnc-port <n>` | `5900` | Port for the x11vnc server. |
| `--web-port <n>` | `6080` | Port for the noVNC web endpoint. |
| `--vnc-password <pw>` | *(none)* | Password for the VNC / web session. |
| `--web-bind <addr>` | `127.0.0.1` | Address noVNC listens on. |

By default noVNC binds to `127.0.0.1`, so it's only reachable through an SSH tunnel:

```bash
ssh -L 6080:localhost:6080 your-vps    # then open http://localhost:6080/vnc.html
```

To expose it publicly, pass `--web-bind 0.0.0.0` **together with** `--vnc-password` — otherwise anyone who reaches the web port lands on an unauthenticated, root-capable desktop. The script prints a loud warning if you bind publicly without a password.

### `run_vps.sh` — service only, fixed GUID

Starts the service headless with a hardcoded TAP GUID (no Wine WMI required) and no GUI at all. If a custom network enumerator (`rv_net_enum.exe`, not shipped in this repo) is present one directory up, it is launched; otherwise the service just runs until you Ctrl+C. Only `--installer` is accepted.

```bash
./run_vps.sh --installer ~/Downloads/Radmin_VPN_*.exe
```

## Building from source

Requires `mingw-w64` cross-compilers. Pre-built binaries are available from [Releases](https://github.com/baptisterajaut/radmin-vpn-linux/releases) (built by CI on each tagged version) if you don't want to install mingw.

```bash
make          # build everything to build/
make clean    # remove build artifacts
```

Produces:
- `build/rvpnnetmp.sys` — Wine kernel driver (64-bit PE)
- `build/adapter_hook.dll` — Hook DLL (32-bit PE)
- `build/rvpn_launcher.exe` — DLL injector (32-bit PE)
- `build/netsh.exe` — netsh replacement (32-bit PE, installed to SysWOW64)
- `build/netsh64.exe` — netsh replacement (64-bit PE, installed to System32)
- `build/drvinst.exe` — no-op stub replacing Radmin's real NDIS driver installer (issue #12)
- `build/tap_bridge` — native Linux TAP bridge
- `build/rvpn_filter_ui` — optional GTK4 packet-filter UI (`--filter-ui`)

### Building the AppImage

```bash
make
./packaging/build-appimage.sh       # → packaging/dist/RadminVPN-Linux-x86_64.AppImage
```

Downloads the Kron4ek Wine-Staging `amd64-wow64` build (~100 MB) and `appimagetool` on first run, caches both in `packaging/dist/`. Requires `curl` and ImageMagick (`convert`).

## What `run.sh` does

1. **First run**: installs Radmin VPN via Wine (`/VERYSILENT`), removes the real NDIS driver (incompatible with Wine), registers our custom driver
2. **Every run**: creates a TAP device, starts the TAP-to-FIFO bridge, configures Wine registry (adapter GUID, driver service), launches the Radmin VPN service and GUI
3. **On exit** (Ctrl+C or close GUI): kills Wine, removes TAP device, cleans up

The wineprefix is stored in `./wineprefix/` (source run) or `~/.local/share/radmin-vpn-linux/wineprefix/` (AppImage). A persistent MAC address is generated on first run and saved in the wineprefix.

## Architecture

| Component | Description |
|---|---|
| `rvpnnetmp.sys` | Wine kernel driver. Emulates the Radmin NDIS miniport. Handles IOCTLs (VERSION, STATUS, SETUP, PEERMAC), TLV frame encoding/decoding, IRP queue for overlapped I/O, MAC-based frame routing for multi-peer support. |
| `adapter_hook.dll` | Companion DLL loaded alongside RvControlSvc.exe. IAT hooks: renames TAP adapter to match Radmin's expected name, no-ops `RegSetKeySecurity` to work around a Wine SCM bug where services lack the SYSTEM SID. |
| `tap_bridge` | Native Linux binary. Relays ethernet frames between the TAP device and named pipes (FIFOs) that the Wine driver reads/writes. |
| `netsh.exe` / `netsh64.exe` | Replaces Wine's netsh stub (32-bit in SysWOW64, 64-bit in System32). Translates Windows `netsh interface ip` commands to Linux `ip addr`/`ip link` commands via a file-based relay, validating the address before it reaches the root relay. |
| `rvpn_launcher.exe` | Injects `adapter_hook.dll` into the Radmin service process via `CreateRemoteThread` + `LoadLibrary`. |
| `drvinst.exe` | No-op stub replacing Radmin's real NDIS driver installer. Radmin runs it at runtime to load `NetMP60_1_1_64.sys`, which aborts Wine 11.x via `NdisInitializeReadWriteLock` (issue #12); since our driver already replaces that adapter, the real one must never load. |
| `rvpn_filter_ui` | Optional GTK4 UI to inspect and filter the packets crossing the bridge. Off by default; launch with `--filter-ui`. |

## Troubleshooting

**GUI stuck on "Waiting for adapter"**: the driver isn't loading. Check that `/tmp/radmin_driver.log` exists and has content. If empty, the driver service registration may be missing — delete the wineprefix and re-run.

**Service dies immediately**: check `/tmp/radmin_service.log` for Wine errors. Common cause: old wineprefix from a different Wine version. Delete `./wineprefix/` and re-run.

**0% packet loss with one peer, high loss with many**: this was the original bug — fixed by MAC-based frame routing in the driver. Make sure you're using the latest build.

**First ping is slow (~1s)**: normal — it's ARP resolution through the VPN tunnel. Subsequent pings are 40-80ms depending on peer distance.

**LAN games don't see other peers / "auto-discovery" broken**: most LAN games discover each other with broadcast probes (UDP to `255.255.255.255`) or multicast (`224.0.0.0/4`). On Windows the Radmin TAP driver advertises itself as the preferred interface for those flows; on Linux you have to tell the kernel explicitly. `run.sh` now installs two extra routes when the VPN comes up:

```
ip route append 255.255.255.255/32 dev radminvpn0 metric 0
ip route append 224.0.0.0/4        dev radminvpn0 metric 0
```

Side effect: mDNS / Bonjour / SSDP on your physical LAN (Chromecast, AirPrint, Sonos, smart TVs, ...) will go through the VPN while it's up. If you need local-LAN discovery and Radmin in parallel, run with `--no-broadcast-routes`:

```bash
./run.sh --no-broadcast-routes
```

The routes are scoped to the TAP device, so they're auto-removed when `run.sh` tears the device down on exit.

## Known limitations

- Only one instance can run at a time (shared FIFOs in `/tmp/`)
- The `26.0.0.0/8` on-link route affects the entire system while running (cleaned up on exit)
- Default broadcast (`255.255.255.255/32`) and multicast (`224.0.0.0/4`) routes are steered to the VPN — disable with `--no-broadcast-routes` if you need local-LAN mDNS / SSDP in parallel
- Older Wine versions (< 11.0) may have different overlapped I/O behavior that breaks the driver

## Notes

**Ban risk.** Each fresh wineprefix creates a new registration ID with Famatech's servers. Don't delete and recreate your wineprefix unnecessarily. Reuse it across sessions.

**Wine bug workaround.** The `RegSetKeySecurity` hook works around a [known Wine limitation](https://forum.winehq.org/viewtopic.php?t=37183) where services don't receive the SYSTEM SID (S-1-5-18). This may be fixed upstream in a future Wine release.

## License

GPL-3.0. See [LICENSE](LICENSE).

In spirit, this code is public domain — do whatever you want with it. The GPL is here as a legal safety net: it explicitly protects reverse engineering for interoperability, which is what this project does. Belt and suspenders.

Radmin VPN is proprietary software by Famatech Corp. This project provides interoperability tools only — no Famatech code is included or distributed.
