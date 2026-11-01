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

On first launch it downloads the Radmin VPN installer it is validated against (or pass your own with `--installer`). A terminal opens with progress, and one sudo password prompt is needed for TAP setup.

Persistent state (wineprefix, MAC, logs) lives in `~/.local/share/radmin-vpn-linux/`.

> **Radmin closing by itself?** Its own updater is installing a newer build inside the running
> prefix. Do the upgrade in a controlled way instead — it keeps your prefix and your Radmin ID:
> ```bash
> ./RadminVPN-Linux-x86_64.AppImage --update
> ```
> Then turn off "Automatic updates" in the Radmin settings so it stops trying. Details in
> [Radmin's own auto-updater](#radmins-own-auto-updater).

## Prerequisites (source build / non-AppImage)

- **Wine** >= 11.0 (tested on Wine 11.5 Arch Linux and on Wine 11.6 Ubuntu 24.04)
- **mingw-w64** cross-compilers (`i686-w64-mingw32-gcc`, `x86_64-w64-mingw32-gcc`) — for building from source
- **iconv** (glibc) — for service log parsing
- **sudo** access — for TAP device creation and routing
- **TUN/TAP kernel support** — usually built-in, check with `modprobe tun`
- **Radmin VPN installer** — downloaded automatically if absent. The version this project is validated against is pinned in one place, `RADMIN_VERSION` in `lib.sh` (currently **2.1.4951.1**; 2.0.4899.9 also works). Radmin VPN **1.4 is not supported** — it registers and opens the adapter but never finishes connecting under the Wine shim, leaving the GUI stuck at "Connecting...".

### Arch Linux

```bash
sudo pacman -S wine mingw-w64-gcc
```

### Ubuntu/Debian

```bash
sudo apt install wine64 wine32 gcc-mingw-w64
```

### NixOS
If you are using NixOS, this project includes native support via Nix Flakes. Please refer to [NIX.md](NIX.md) for installing on NixOS instructions.

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
| `--update` | Upgrade Radmin to the pinned version in place. Keeps the prefix, so the RID registered with Famatech survives. |
| `--no-broadcast-routes` | Don't add the broadcast/multicast → TAP routes. |
| `--filter-ui` | Launch the optional GTK4 packet-filter UI (off by default). |
| `--fix-chat` | Patch Qt's `qwindows.dll` to fix the chat-window crash under Wine (off by default). |

### Radmin's own auto-updater

Radmin's GUI can download a newer build and run its installer *inside the live prefix*,
which kills the GUI and faults the running service (the GUI log then shows an installer
under `AppData\\Local\\Temp`). Two defences: the launcher ships the current validated
build so the updater has nothing to push, and a GUI that dies no longer takes the tunnel
with it — it is restarted once, then the VPN keeps running headless. To upgrade
deliberately, use `./run.sh --update`, which stops everything first. Turning off
"Automatic updates" in the GUI settings avoids the race entirely.

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
- `build/rvpn_dnsfix.so` — native LD_PRELOAD shim, preloaded into the service only
- `build/rvpn_reuseport.so` — native LD_PRELOAD shim, preloaded into `wineserver`
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
| `adapter_hook.dll` | Companion DLL loaded alongside RvControlSvc.exe. IAT hooks: renames TAP adapter to match Radmin's expected name, no-ops `RegSetKeySecurity` to work around a Wine SCM bug where services lack the SYSTEM SID, and answers the four `Perf{Increment,Decrement}ULong{,Long}CounterValue` lookups Wine's `advapi32` does not export. That last one is not cosmetic: Radmin 2.1 resolves seven perflib entry points in one all-or-nothing cascade, then passes the resulting per-peer counter object as the payload of the peer handshake — so four missing telemetry exports take down the whole data path (issue #24, `docs/wine-perflib.md`). |
| `tap_bridge` | Native Linux binary. Relays ethernet frames between the TAP device and named pipes (FIFOs) that the Wine driver reads/writes. |
| `netsh.exe` / `netsh64.exe` | Replaces Wine's netsh stub (32-bit in SysWOW64, 64-bit in System32). Translates Windows `netsh interface ip` commands to Linux `ip addr`/`ip link` commands via a file-based relay, validating the address before it reaches the root relay. |
| `rvpn_launcher.exe` | Injects `adapter_hook.dll` into the Radmin service process via `CreateRemoteThread` + `LoadLibrary`. |
| `drvinst.exe` | No-op stub replacing Radmin's real NDIS driver installer. Radmin runs it at runtime to load `NetMP60_1_1_64.sys`, which aborts Wine 11.x via `NdisInitializeReadWriteLock` (issue #12); since our driver already replaces that adapter, the real one must never load. |
| `rvpn_dnsfix.so` | Native `LD_PRELOAD` shim, injected into the service launch only. Short-circuits reverse DNS (`getnameinfo`/`gethostbyaddr`) of private IPv4/IPv6 at the glibc layer. Radmin PTR-resolves every local candidate address it gathers; on a host whose resolver black-holes RFC1918 PTR queries that stalls for minutes and the service registers but never becomes ready (issue #16). The lookup is issued by Wine's Unix side, out of reach of any hook inside `adapter_hook.dll`. |
| `rvpn_reuseport.so` | Native `LD_PRELOAD` shim, preloaded into `wineserver` (not into the service — the Unix sockets belong to wineserver). Sets `SO_REUSEPORT` on every TCP socket at creation. Radmin 2.1 does TCP port-reuse NAT traversal: it binds a listener to `uplink:PORT`, advertises that mapping, then binds its outbound peer sockets to the same local port with `SO_REUSEADDR`, which Windows allows. Wine translates that request into no Unix-level option for TCP (`server/sock.c`, `SO_REUSEPORT` is compiled `__APPLE__`-only), so the kernel refuses the second bind and the client sees `WSAEACCES` on every peer connect (issue #24). Wineserver's own conflict bookkeeping still runs, so binds Windows would refuse are still refused. |
| `rvpn_filter_ui` | Optional GTK4 UI to inspect and filter the packets crossing the bridge. Off by default; launch with `--filter-ui`. |

## Troubleshooting

**GUI stuck on "Waiting for adapter"**: the driver isn't loading. Check that `/tmp/radmin_driver.log` exists and has content. If empty, the driver service registration may be missing — delete the wineprefix and re-run.

**Registered but never "ready"**: the service reaches `Registered as #…` and stops there. Two known causes, both reported by the diagnostics block printed on timeout. (a) A transparent proxy or tunnel with its own routing policy (sing-box, clash/mihomo, v2ray…) intercepting the outbound connection — such stacks answer the TCP handshake locally, so the socket reads ESTABLISHED while nothing is relayed. Exclude `26.0.0.0/8` from its routes, and `*.radminte.com` too if you can reach those directly. (b) A resolver that black-holes reverse lookups of private addresses (a `docker0` at `172.17.0.1` is the usual trigger). `rvpn_dnsfix.so` handles this, but it is a 64-bit shim: a system Wine built as *old-wow64* ignores it. Workaround there — add a line for the address to `/etc/hosts`, or use `contrib/run-in-netns.sh` (which gets the service to "ready" but keeps the VPN inside a namespace: host applications cannot reach `26.0.0.0/8`, read the warning in its header).

**Your *other* Wine apps broke after running Radmin (`unimplemented function ndis.sys.NdisInitializeReadWriteLock`)**: versions up to 1.0.0 let Wine's `winemenubuilder.exe` run, which rewrites the host's Windows file associations (`.exe`, `.msi`, `.lnk`, `.reg`, `.chm`, …) to open in *our* prefix. Other Windows programs then start inside the Radmin prefix, and if Radmin's real NDIS miniport (`RvNetMP60`) is still registered there, every one of them aborts on that ndis stub. 1.0.1 disables `winemenubuilder` everywhere, purges the entries it wrote for a Radmin prefix, and removes `RvNetMP60` from `system.reg` offline — just run 1.0.1 once and both are repaired. Note `echo $WINEPREFIX` shows nothing in this situation: the hijack lives in `~/.local/share/applications/*.desktop`, not in your environment. Manual cleanup, if you prefer:

```bash
grep -rl 'WINEPREFIX=[^"]*radmin' ~/.local/share/applications --include='*.desktop' | xargs -r rm
rm -rf ~/.local/share/applications/wine/Programs/"Radmin VPN"
update-desktop-database ~/.local/share/applications
```

**Online and in your networks, but no peer ever connects (`error: 0x700000000`)**: this is Radmin 2.1 on a build older than 1.1.0. The service log looks healthy right up to the peer connections, which then fail in a loop with that code and finally give up with `node offline`. Two independent Wine gaps, both fixed in 1.1.0 and both explained above in the `rvpn_reuseport.so` and `adapter_hook.dll` rows: Wine sets no Unix-level option for a TCP `SO_REUSEADDR`, so 2.1's port-reuse NAT traversal gets `WSAEACCES` on every peer connect; and Wine's `advapi32` is missing four perflib exports, without which 2.1 sends a null payload as its peer handshake. Note the code itself carries no information — it is the generic give-up at the end of the error cascade, so don't try to read a subsystem out of it. The fix is to update this project to 1.1.0; nothing needs to change on the Radmin side.

**Service dies immediately**: check `/tmp/radmin_service.log` for Wine errors. Common cause: old wineprefix from a different Wine version. Delete `./wineprefix/` and re-run.

**0% packet loss with one peer, high loss with many**: this was the original bug — fixed by MAC-based frame routing in the driver. Make sure you're using the latest build.

**First ping is slow (~1s)**: the latest version caches MAC addresses for every IP packet the driver sees. If the target IP has sent at least one packet while the driver was running, the MAC is already cached and there's zero ARP delay. Only completely silent peers (those that have never sent a packet) require the initial ARP resolution, which adds ~1 second.

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

**Wine bug workaround.** The `RegSetKeySecurity` hook works around a [known Wine limitation](https://forum.winehq.org/viewtopic.php?t=37183) where services don't receive the SYSTEM SID (S-1-5-18). This may be fixed upstream in a future Wine release.

## Credits

Reverse engineering and the Wine shim: [@baptisterajaut](https://github.com/baptisterajaut).

- [@ayozetr](https://github.com/ayozetr) — tracked the "registers but never ready" hang down to a
  reverse-DNS lookup of a private address black-holed by the host resolver, proved it with a
  bare-libc repro after four wrong theories had been discarded (mine included), and wrote the
  original of `src/rvpn_dnsfix.c` and `contrib/run-in-netns.sh`.
- [@gringoestrangeiro](https://github.com/gringoestrangeiro) — Linux stability work: packet filters,
  ARP cache, crash recovery, headless and datacenter modes.
- [@yuxiaole-bili](https://github.com/yuxiaole-bili) — found that Wine's SCM auto-starts a second,
  unhooked service instance that fights the injected one for the adapter.
- [@D1spell-tech](https://github.com/D1spell-tech), [@Milkiway13](https://github.com/Milkiway13) and
  everyone who pasted a full diagnostics block — two independent hosts is what makes a bug findable.

## License

GPL-3.0. See [LICENSE](LICENSE).

In spirit, this code is public domain — do whatever you want with it. The GPL is here as a legal safety net: it explicitly protects reverse engineering for interoperability, which is what this project does. Belt and suspenders.

Radmin VPN is proprietary software by Famatech Corp. This project provides interoperability tools only — no Famatech code is included or distributed.
