# How it works

Radmin VPN's Windows service talks to an NDIS miniport driver for its virtual adapter. Wine has no NDIS, so we replace that driver with our own, which bridges to a Linux TAP device. A hook DLL covers the places where Wine behaves differently from Windows (adapter naming, registry permissions, missing exports). The Radmin service and GUI themselves run unmodified.

```
Linux app ← TAP (radminvpn0) ← tap_bridge ← FIFO ← rvpnnetmp.sys (Wine driver) ← RvControlSvc.exe
```

## Components

| Component | Role |
|---|---|
| `rvpnnetmp.sys` | Wine kernel driver standing in for Radmin's NDIS miniport. Handles the IOCTLs (VERSION, STATUS, SETUP, PEERMAC), the TLV frame format, an IRP queue for overlapped I/O, and MAC-based routing of frames to the right per-peer handle. |
| `adapter_hook.dll` | Loaded into `RvControlSvc.exe`. IAT hooks that rename the TAP adapter to the name Radmin expects, turn `RegSetKeySecurity` into a no-op (Wine services lack the SYSTEM SID, so Radmin would lock itself out of its own keys), and answer the four `Perf{Increment,Decrement}ULong{,Long}CounterValue` lookups Wine's `advapi32` lacks. That last one is not cosmetic: Radmin 2.1 sends a per-peer perf-counter object as the peer handshake payload, so without it no peer ever connects (issue #24, [wine-perflib.md](wine-perflib.md)). |
| `tap_bridge` | Native binary relaying Ethernet frames between the TAP device and the FIFOs the driver reads and writes. |
| `netsh.exe`, `netsh64.exe` | Replace Wine's netsh stub. Translate `netsh interface ip` commands into `ip addr` / `ip link` through a file relay, validating the address before it reaches the root side. |
| `rvpn_launcher.exe` | Injects `adapter_hook.dll` into the service with `CreateRemoteThread` + `LoadLibrary`. |
| `drvinst.exe` | No-op stand-in for Radmin's driver installer. The real one loads `NetMP60_1_1_64.sys`, which aborts Wine 11 on `NdisInitializeReadWriteLock` (issue #12). |
| `rvpn_dnsfix.so` | LD_PRELOAD shim for the service. Answers reverse DNS of private addresses locally: Radmin PTR-resolves every local address it finds, and a resolver that black-holes RFC1918 PTR queries stalls it for minutes before "ready" (issue #16). The lookup happens on Wine's Unix side, out of reach of the hook DLL. |
| `rvpn_reuseport.so` | LD_PRELOAD shim for `wineserver`, which owns the Unix sockets. Sets `SO_REUSEPORT` on TCP sockets. Radmin 2.1 binds its outbound peer sockets to the port of its own listener, which Windows allows with `SO_REUSEADDR`; Wine maps that to nothing for TCP, so every peer connect failed with `WSAEACCES` (issue #24). Wineserver's own conflict checks still apply. |
| `rvpn_filter_ui` | Optional GTK4 window to inspect and filter packets crossing the bridge (`--filter-ui`). |
| `patch_qwindows_font.py` | Patches one call site in Qt's `qwindows.dll`: Wine returns garbage font name offsets for some host fonts, and the chat window dereferenced them (issue #31). Refuses any `qwindows.dll` it does not recognise; the same file ships in Radmin 2.0.4899.9 and 2.1.4951.1. |

## Limitations

- One instance at a time (shared FIFOs in `/tmp/`; the AppImage enforces it with a lock).
- The `26.0.0.0/8` route and the broadcast/multicast routes apply system-wide while Radmin runs, and go away with the TAP device.
- `RegSetKeySecurity` is a workaround for a [Wine limitation](https://forum.winehq.org/viewtopic.php?t=37183): services don't get the SYSTEM SID (S-1-5-18). It can go once Wine fixes that upstream.
