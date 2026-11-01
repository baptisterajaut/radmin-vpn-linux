# Running from source

The AppImage is the easy path. This is for running `run.sh` from a checkout, with your system's Wine.

## Requirements

- Wine 11.0 or newer (`run.sh` refuses anything older: the driver depends on Wine 11's overlapped I/O). Tested on Wine 11.5 (Arch) and 11.6 (Ubuntu 24.04).
- `sudo`, for the TAP device and the routes.
- TUN/TAP kernel support (`modprobe tun`).
- `iconv` (glibc) and Python 3.
- To build: the mingw-w64 cross-compilers (`i686-w64-mingw32-gcc`, `x86_64-w64-mingw32-gcc`) and GTK4 for the optional filter UI.

```bash
sudo pacman -S wine mingw-w64-gcc                 # Arch
sudo apt install wine64 wine32 gcc-mingw-w64      # Debian / Ubuntu
```

Or `make install-deps`, which knows the package names for the common distros. NixOS: see [NIX.md](../NIX.md).

The Radmin version this project is tested against is pinned once, `RADMIN_VERSION` in `lib.sh` (currently 2.1.4951.1; 2.0.4899.9 also works). Radmin 1.4 is not supported: it registers but stays on "Connecting...".

## Run

```bash
git clone https://github.com/baptisterajaut/radmin-vpn-linux.git
cd radmin-vpn-linux
make            # or grab radmin-vpn-linux-<tag>.tar.gz from a release and untar it into build/
./run.sh        # downloads the pinned installer on first run, or pass --installer
```

`run.sh` takes the same options as the AppImage (see the README). `run.sh` never compiles: after changing the sources, run `make` again or it deploys the old binaries.

The Wine prefix lives in `./wineprefix/` for a source run. A random adapter MAC is generated on the first run and kept in the prefix. Reuse the prefix: each new one registers a new Radmin ID with Famatech.

## What `run.sh` does

1. First run: installs Radmin silently, removes its real NDIS driver (it crashes Wine), registers ours.
2. Every run: creates the TAP device, opens it in the host firewall, starts the TAP bridge, writes the registry (adapter GUID, driver service), starts the Radmin service and GUI.
3. On exit (GUI closed or Ctrl+C): stops Wine, removes the firewall rules and the TAP device.

## Build outputs

`make` builds everything into `build/`:

- `rvpnnetmp.sys`: Wine kernel driver (64-bit PE)
- `adapter_hook.dll`: hook DLL (32-bit PE)
- `rvpn_launcher.exe`: DLL injector (32-bit PE)
- `netsh.exe`, `netsh64.exe`: netsh replacements (32-bit in SysWOW64, 64-bit in System32)
- `drvinst.exe`: no-op stub replacing Radmin's NDIS driver installer (issue #12)
- `tap_bridge`: native TAP bridge
- `rvpn_dnsfix.so`: LD_PRELOAD shim for the service
- `rvpn_reuseport.so`: LD_PRELOAD shim for `wineserver`
- `rvpn_filter_ui`: optional GTK4 packet-filter UI

## Building the AppImage

```bash
make
./packaging/build-appimage.sh       # → packaging/dist/RadminVPN-Linux-x86_64.AppImage
```

The first run downloads the Kron4ek Wine-Staging `amd64-wow64` build (~100 MB) and `appimagetool`, cached in `packaging/dist/`. Needs `curl` and ImageMagick (`convert`).
