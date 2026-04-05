# Radmin VPN for Linux

Run [Radmin VPN](https://www.radmin-vpn.com/) on Linux via Wine. Join VPN networks, see peers, play games — all without a Windows VM.

> I did not build this because it was easier than a VM. I built it because I thought it was easier than a VM.

**AI-assisted code.** Built collaboratively between a human and Claude (Anthropic). The driver, hooks, and bridge were written with extensive AI-assisted reverse engineering of Radmin VPN's undocumented driver protocol using Ghidra. **This works, but comes with no guarantees.** Not affiliated with Famatech. Radmin VPN is proprietary — download it yourself from [radmin-vpn.com](https://www.radmin-vpn.com/). Use at your own risk.

## How it works

Radmin VPN's Windows service talks to an NDIS miniport driver for its virtual network adapter. Wine doesn't support NDIS, so we replace the driver with our own implementation that bridges to a Linux TAP device. A hook DLL handles Wine compatibility issues (adapter naming, registry permissions). The result is a fully functional Radmin VPN client running natively under Wine.

```
Linux app ← TAP (radminvpn0) ← tap_bridge ← FIFO ← rvpnnetmp.sys (Wine driver) ← RvControlSvc.exe
```

## Prerequisites

- **Wine** >= 9.0 (tested on Wine 11.5, Arch Linux)
- **mingw-w64** cross-compilers (`i686-w64-mingw32-gcc`, `x86_64-w64-mingw32-gcc`) — for building from source
- **python3** — for service log parsing
- **sudo** access — for TAP device creation and routing
- **TUN/TAP kernel support** — usually built-in, check with `modprobe tun`
- **Radmin VPN installer** — download from [radmin-vpn.com](https://www.radmin-vpn.com/)

### Arch Linux

```bash
sudo pacman -S wine mingw-w64-gcc python
```

### Ubuntu/Debian

```bash
sudo apt install wine64 wine32 gcc-mingw-w64 python3
```

## Quick start

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
- `build/netsh.exe` — netsh replacement (32-bit PE)
- `build/tap_bridge` — native Linux TAP bridge

## What `run.sh` does

1. **First run**: installs Radmin VPN via Wine (`/VERYSILENT`), removes the real NDIS driver (incompatible with Wine), registers our custom driver
2. **Every run**: creates a TAP device, starts the TAP-to-FIFO bridge, configures Wine registry (adapter GUID, driver service), launches the Radmin VPN service and GUI
3. **On exit** (Ctrl+C or close GUI): kills Wine, removes TAP device, cleans up

The wineprefix is stored in `./wineprefix/`. A persistent MAC address is generated on first run and saved in the wineprefix.

## Architecture

| Component | Description |
|---|---|
| `rvpnnetmp.sys` | Wine kernel driver. Emulates the Radmin NDIS miniport. Handles IOCTLs (VERSION, STATUS, SETUP, PEERMAC), TLV frame encoding/decoding, IRP queue for overlapped I/O, MAC-based frame routing for multi-peer support. |
| `adapter_hook.dll` | Companion DLL loaded alongside RvControlSvc.exe. IAT hooks: renames TAP adapter to match Radmin's expected name, no-ops `RegSetKeySecurity` to work around a Wine SCM bug where services lack the SYSTEM SID. |
| `tap_bridge` | Native Linux binary. Relays ethernet frames between the TAP device and named pipes (FIFOs) that the Wine driver reads/writes. |
| `netsh.exe` | Replaces Wine's netsh stub. Translates Windows `netsh interface ip` commands to Linux `ip addr`/`ip link` commands via a file-based relay. |
| `rvpn_launcher.exe` | Injects `adapter_hook.dll` into the Radmin service process via `CreateRemoteThread` + `LoadLibrary`. |

## Troubleshooting

**GUI stuck on "Waiting for adapter"**: the driver isn't loading. Check that `wineprefix/drive_c/radmin_driver.log` exists and has content. If empty, the driver service registration may be missing — delete the wineprefix and re-run.

**Service dies immediately**: check `/tmp/radmin_service.log` for Wine errors. Common cause: old wineprefix from a different Wine version. Delete `./wineprefix/` and re-run.

**0% packet loss with one peer, high loss with many**: this was the original bug — fixed by MAC-based frame routing in the driver. Make sure you're using the latest build.

**First ping is slow (~1s)**: normal — it's ARP resolution through the VPN tunnel. Subsequent pings are 40-80ms depending on peer distance.

## Known limitations

- Only one instance can run at a time (shared FIFOs in `/tmp/`)
- The `26.0.0.0/8` on-link route affects the entire system while running (cleaned up on exit)
- Older Wine versions (< 9.0) may have different overlapped I/O behavior that breaks the driver

## Notes

**Ban risk.** Each fresh wineprefix creates a new registration ID with Famatech's servers. Don't delete and recreate your wineprefix unnecessarily. Reuse it across sessions.

**Wine bug workaround.** The `RegSetKeySecurity` hook works around a [known Wine limitation](https://forum.winehq.org/viewtopic.php?t=37183) where services don't receive the SYSTEM SID (S-1-5-18). This may be fixed upstream in a future Wine release.

## License

GPL-3.0. See [LICENSE](LICENSE).

In spirit, this code is public domain — do whatever you want with it. The GPL is here as a legal safety net: it explicitly protects reverse engineering for interoperability, which is what this project does. Belt and suspenders.

Radmin VPN is proprietary software by Famatech Corp. This project provides interoperability tools only — no Famatech code is included or distributed.
