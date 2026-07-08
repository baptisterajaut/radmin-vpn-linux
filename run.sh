#!/bin/bash
# run.sh - Radmin VPN on Linux
# Usage: ./run.sh [--installer /path/to/Radmin_VPN_*.exe] [--no-ui]
#                 [--no-broadcast-routes] [--filter-ui] [--fix-chat]
#   --filter-ui  launch the optional GTK4 packet-filter UI (off by default)
#   --fix-chat   patch Qt qwindows.dll to fix the chat crash (off by default)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Shared diagnostics/health library (colors, check_*, dump_diagnostics).
source "$DIR/lib.sh"

# ── Portability helpers ───────────────────────────────────────────────────────

_distro() {
    if command -v dnf     >/dev/null 2>&1; then printf 'fedora'
    elif command -v apt-get >/dev/null 2>&1; then printf 'debian'
    elif command -v pacman  >/dev/null 2>&1; then printf 'arch'
    elif command -v zypper  >/dev/null 2>&1; then printf 'suse'
    else printf 'unknown'; fi
}

_wine_install_hint() {
    case "$(_distro)" in
        fedora)  echo "  sudo dnf install wine winetricks  # or add the WineHQ repo for a newer version" ;;
        debian)  echo "  sudo apt install wine winetricks" ;;
        arch)    echo "  sudo pacman -S wine winetricks" ;;
        suse)    echo "  sudo zypper install wine winetricks" ;;
        *)       echo "  Install wine from: https://www.winehq.org/" ;;
    esac
}

wine_version_str() { wine --version 2>/dev/null | head -n1; }
wine_major() { wine_version_str | sed -n 's/^wine-\([0-9]\+\).*/\1/p'; }

_http_get() {
    local dest="$1" url="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "$dest" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url" 2>/dev/null
    else
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# When launched from the AppImage, AppRun already exports WINEPREFIX and BUILD_DIR.
# Fall back to the traditional $DIR-relative paths when running directly.
export WINEPREFIX="${WINEPREFIX:-$DIR/wineprefix}"
# Disable Wine debug output to reduce memory consumption
export WINEDEBUG=-all
# Reduce glibc memory arenas to prevent fragmentation
export MALLOC_ARENA_MAX=2
RADMIN="$WINEPREFIX/drive_c/Program Files (x86)/Radmin VPN"
BUILD_DIR="${BUILD_DIR:-$DIR/build}"
TAP_DEV="radminvpn0"
CMD_FILE="/tmp/radmin_netsh_cmd"
LOG="$WINEPREFIX/drive_c/ProgramData/Famatech/Radmin VPN/service.log"
MAC_FILE="$WINEPREFIX/radmin_mac"
RELAY_PID=""
BRIDGE_PID=""
FILTER_UI_PID=""
MONITOR_PID=""
NO_UI=0
FILTER_UI=0
FIX_CHAT=0

# Parse args
INSTALLER=""
for arg in "$@"; do
    case "$arg" in
        --installer) shift; INSTALLER="$1"; shift ;;
        --installer=*) INSTALLER="${arg#*=}" ;;
        --no-ui) NO_UI=1 ;;
        --no-broadcast-routes) NO_BCAST_ROUTES=1 ;;
        --filter-ui) FILTER_UI=1 ;;
        --fix-chat) FIX_CHAT=1 ;;
    esac
done
NO_BCAST_ROUTES="${NO_BCAST_ROUTES:-0}"

# Find installer if not specified
if [ -z "$INSTALLER" ]; then
    # Search project dir first, then BUILD_DIR (where AppImage bundles it)
    INSTALLER=$(find "$DIR" -maxdepth 1 -name "Radmin_VPN_*.exe" -print -quit 2>/dev/null || true)
    if [ -z "$INSTALLER" ]; then
        INSTALLER=$(find "$BUILD_DIR" -maxdepth 1 -name "Radmin_VPN_*.exe" -print -quit 2>/dev/null || true)
    fi
fi

# Download installer at runtime if still not found
INSTALLER_URL="${RADMIN_INSTALLER_URL:-https://download.radmin-vpn.com/download/files/Radmin_VPN_2.0.4899.9.exe}"
if [ -z "$INSTALLER" ] || [ ! -f "$INSTALLER" ]; then
    DOWNLOAD_DIR="${RADMIN_DATA_DIR:-$HOME/.local/share/radmin-vpn-linux}"
    mkdir -p "$DOWNLOAD_DIR"
    INSTALLER="$DOWNLOAD_DIR/Radmin_VPN_2.0.4899.9.exe"
    if [ ! -f "$INSTALLER" ]; then
        _http_get "$INSTALLER" "$INSTALLER_URL" || { echo "Error: download failed (install curl or wget)"; exit 1; }
    fi
fi

cleanup() {
    [ -n "$FILTER_UI_PID" ] && kill "$FILTER_UI_PID" 2>/dev/null || true
    wineserver -k 2>/dev/null || true
    [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null || true
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null || true
    [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
    sudo ip link delete "$TAP_DEV" 2>/dev/null || true
    rm -f "$CMD_FILE" "${CMD_FILE}.proc" /tmp/rvpn_b2d /tmp/rvpn_d2b /tmp/rvpn_mac /tmp/rvpn_filters.json
    # Collect a debug bundle of everything captured this run.
    if [ "${RVPN_DEBUG:-0}" = "1" ]; then
        BUND="/tmp/rvpn_debug_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BUND" 2>/dev/null || true
        cp /tmp/radmin_*.log "$BUND/" 2>/dev/null || true
        cp /tmp/rvpn_filters.json "$BUND/" 2>/dev/null || true
        iconv -f UTF-16LE -t UTF-8 "$LOG" > "$BUND/service.log.txt" 2>/dev/null || cp "$LOG" "$BUND/service.log" 2>/dev/null || true
        cp "$WINEPREFIX/drive_c/radmin_crash.log"      "$BUND/" 2>/dev/null || true
        cp "$WINEPREFIX/drive_c/radmin_hook_debug.log" "$BUND/" 2>/dev/null || true
        cp "$WINEPREFIX/drive_c/radmin_driver.log" /tmp/radmin_driver.log "$BUND/" 2>/dev/null || true
        {
            echo "== ip addr =="; ip addr 2>&1
            echo; echo "== ip route =="; ip route 2>&1
            echo; echo "== ip -s link show $TAP_DEV =="; ip -s link show "$TAP_DEV" 2>&1
        } > "$BUND/net_state.txt" 2>&1 || true
        { dmesg 2>/dev/null || sudo dmesg 2>/dev/null; } | tail -150 > "$BUND/dmesg_tail.txt" 2>/dev/null || true
        echo ""
        echo "[*] Debug bundle salvo em: $BUND"
        if [ -s "$WINEPREFIX/drive_c/radmin_crash.log" ]; then
            echo "[!] CRASH capturado — resumo:"
            grep -E 'CRASH|code=0x|access-violation|  #0[0-3] ' "$WINEPREFIX/drive_c/radmin_crash.log" | tail -12
        fi
    fi
}
trap cleanup EXIT

echo "Radmin VPN - starting service..."

# Prerequisites
_missing=""
command -v wine       >/dev/null || _missing="$_missing wine"
command -v wineserver >/dev/null || _missing="$_missing wineserver"
command -v python3    >/dev/null || _missing="$_missing python3"
command -v ip         >/dev/null || _missing="$_missing ip(iproute2)"
if [ -n "$_missing" ]; then
    echo "Error: missing dependencies:$_missing"
    _wine_install_hint
    exit 1
fi
if [ -z "${RADMIN_SUDO_PRIMED:-}" ]; then
    sudo -v || { echo "Error: insufficient permissions (sudo required for the TAP device)"; exit 1; }
fi

# Wine version gate: requires >= 11.0 for overlapped I/O semantics.
WINE_VERSION_STR=$(wine_version_str || echo '?')
WINE_MAJOR=$(wine_major || echo 0)
if [ -n "${APPIMAGE:-}" ]; then
    echo "[*] Wine bundled: $WINE_VERSION_STR"
elif ! [ "${WINE_MAJOR:-0}" -ge 11 ] 2>/dev/null; then
    echo "[-] Wine $WINE_VERSION_STR too old — requires Wine >= 11.0."
    echo "    Atualize wine-staging ou use o AppImage com Wine 11.x embutido."
    _wine_install_hint
    exit 1
fi

# Warn about SELinux (Fedora/RHEL) — can silently block tap_bridge and Wine pipes
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    echo "Aviso: SELinux Enforcing detectado. Em caso de falha, tente:"
    echo "  sudo setsebool -P allow_execmod on"
    echo "  sudo chcon -t bin_t \"$BUILD_DIR/tap_bridge\""
fi

# 1. Kill any previous Wine session
# Kill wine processes before the server so they exit cleanly rather than
# crashing mid-cleanup (a crashing wine process can trigger DispatchCleanup
# while Wine's internal state is already being torn down → ntdll crash).
pkill -f "RvControlSvc|RvRvpnGui|rvpn_launcher" 2>/dev/null || true
sleep 0.3
wineserver -k 2>/dev/null || true
# Configure wineserver to use less memory
wineserver -p 2>/dev/null || true

# 2. Install Radmin if not present
if [ ! -f "$RADMIN/RvControlSvc.exe" ]; then
    if [ -z "$INSTALLER" ] || [ ! -f "$INSTALLER" ]; then
        echo "Error: installer not found"
        exit 1
    fi
    mkdir -p "$WINEPREFIX"
    wineboot --init 2>/dev/null
    if command -v winetricks >/dev/null 2>&1; then
        winetricks -q d3dcompiler_47 d3dx11_43 dxvk 2>/dev/null || true
    fi
    wineserver -k 2>/dev/null || true
    wine "$INSTALLER" /VERYSILENT /NORESTART 2>/dev/null || true
    for _ in $(seq 1 30); do
        sleep 0.5
        [ -f "$RADMIN/RvControlSvc.exe" ] && break
    done
    if [ ! -f "$RADMIN/RvControlSvc.exe" ]; then
        echo "Error: installation failed"
        exit 1
    fi
    wineserver -k 2>/dev/null || true
    wine reg delete "HKLM\\SYSTEM\\CurrentControlSet\\Services\\RvNetMP60" /f > /dev/null 2>&1 || true
    rm -f "$WINEPREFIX/drive_c/windows/system32/drivers/RvNetMP60.sys"
    wine reg add "HKLM\\SYSTEM\\CurrentControlSet\\Services\\RvControlSvc" /v Start /t REG_DWORD /d 4 /f > /dev/null 2>&1 || true
    wineserver -k 2>/dev/null || true
fi

chmod +x "$BUILD_DIR/tap_bridge" 2>/dev/null || true
cp "$BUILD_DIR/rvpnnetmp.sys" "$WINEPREFIX/drive_c/windows/system32/drivers/"
cp "$BUILD_DIR/adapter_hook.dll" "$RADMIN/"
cp "$BUILD_DIR/rvpn_launcher.exe" "$RADMIN/"
cp "$BUILD_DIR/netsh.exe" "$WINEPREFIX/drive_c/windows/syswow64/netsh.exe"
cp "$BUILD_DIR/netsh64.exe" "$WINEPREFIX/drive_c/windows/system32/netsh.exe"
# Replace Radmin's real NDIS driver installer with a no-op stub.
# RvControlSvc runs drvinst.exe at runtime to load NetMP60_1_1_64.sys, which
# aborts Wine 11.x via NdisInitializeReadWriteLock (issue #12). Our rvpnnetmp.sys
# replaces that adapter, so the real NDIS driver must never load.
cp "$BUILD_DIR/drvinst.exe" "$RADMIN/drvinst.exe"

# Scrub any real NDIS driver left behind on a poisoned prefix (run every launch
# so an already-poisoned prefix recovers without reinstall).
wine reg delete "HKLM\\SYSTEM\\CurrentControlSet\\Services\\RvNetMP60" /f > /dev/null 2>&1 || true
rm -f "$WINEPREFIX/drive_c/windows/system32/drivers/RvNetMP60.sys"

if [ -f "$MAC_FILE" ]; then
    ADAPTER_MAC=$(cat "$MAC_FILE")
else
    ADAPTER_MAC=$(printf '02:%02x:%02x:%02x:%02x:%02x' \
        $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    echo "$ADAPTER_MAC" > "$MAC_FILE"
fi
# Write raw 6 bytes for driver to read
printf '%b' "$(echo "$ADAPTER_MAC" | sed 's/://g; s/../\\x&/g')" > /tmp/rvpn_mac

sudo modprobe tun 2>/dev/null || true
sudo ip link delete "$TAP_DEV" 2>/dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap user "$(whoami)"
sudo ip link set "$TAP_DEV" address "$ADAPTER_MAC"
sudo ip link set "$TAP_DEV" up
# Enable multicast support for IGMP/Minecraft LAN
sudo ip link set "$TAP_DEV" multicast on
sudo ip link set "$TAP_DEV" allmulticast on
# Disable reverse-path filtering — VPN peers have IPs from 26.x.x.x but
# the kernel may not find a matching route back, causing it to drop replies.
sudo sysctl -w "net.ipv4.conf.$TAP_DEV.rp_filter=0" >/dev/null 2>&1 || true
sudo sysctl -w "net.ipv4.conf.$TAP_DEV.accept_local=1" >/dev/null 2>&1 || true
sudo ip maddr add 224.0.2.60 dev "$TAP_DEV" 2>/dev/null || true
# Prevent NetworkManager/avahi from cycling the VPN adapter's addresses.
# NM treats the TAP as an external device and periodically re-configures it;
# each address cycle triggers an NDIS adapter-removal event inside Wine,
# which causes DispatchCleanup to fire and crash (0xc0000005 in ntdll).
sudo nmcli device set "$TAP_DEV" managed no 2>/dev/null || true

pkill -f tap_bridge 2>/dev/null || true
rm -f /tmp/rvpn_b2d /tmp/rvpn_d2b /tmp/rvpn_d2b_high /tmp/rvpn_d2b_low
"$BUILD_DIR/tap_bridge" > /tmp/radmin_bridge.log 2>&1 &
BRIDGE_PID=$!
for _ in $(seq 1 10); do
    [ -p /tmp/rvpn_b2d ] && [ -p /tmp/rvpn_d2b_low ] && break
    sleep 0.1
done
if [ ! -p /tmp/rvpn_b2d ] || [ ! -p /tmp/rvpn_d2b_low ]; then
    echo "Error: failed to start bridge"
    exit 1
fi

TAP_GUID=$(timeout 10 wine wmic path Win32_NetworkAdapter get Name,GUID \
    | grep "$TAP_DEV" | awk '{print $1}' | tr -d '\r')
if [ -z "$TAP_GUID" ]; then
    TAP_GUID="{$(echo "$ADAPTER_MAC" | sed 's/://g' | md5sum | cut -c1-8)-$(echo "$ADAPTER_MAC" | sed 's/://g' | md5sum | cut -c9-12)-4$(echo "$ADAPTER_MAC" | sed 's/://g' | md5sum | cut -c13-16)-$(echo "$ADAPTER_MAC" | sed 's/://g' | md5sum | cut -c17-20)-$(echo "$ADAPTER_MAC" | sed 's/://g' | md5sum | cut -c21-32)}"
fi

{
wine reg add "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\0099" /v NetCfgInstanceId /t REG_SZ /d "$TAP_GUID" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\0099" /v MatchingDeviceId /t REG_SZ /d "${TAP_GUID}\\RvNetMP60" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Control\Network\{4d36e972-e325-11ce-bfc1-08002be10318}\\${TAP_GUID}\Connection" /v Name /t REG_SZ /d "Radmin VPN" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Control\Network\{4d36e972-e325-11ce-bfc1-08002be10318}\\${TAP_GUID}\Connection" /v PnpInstanceID /t REG_SZ /d "ROOT\NET\0099" /f
wine reg add "HKLM\Software\Wow6432Node\Famatech\RadminVPN\1.0\Firewall" /v AdapterId /t REG_SZ /d "$TAP_GUID" /f
wine reg add "HKLM\SOFTWARE\Famatech\RadminVPN\1.0\Registration" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v DisplayName /t REG_SZ /d "Radmin VPN TAP Bridge" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v ImagePath /t REG_EXPAND_SZ /d "C:\windows\system32\drivers\rvpnnetmp.sys" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v Start /t REG_DWORD /d 2 /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v Type /t REG_DWORD /d 1 /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v Group /t REG_SZ /d "NDIS" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v ErrorControl /t REG_DWORD /d 0 /f
} > /dev/null 2>&1

wineserver -k 2>/dev/null || true
wine reg add "HKLM\\System\\CurrentControlSet\\Control\\Session Manager\\Memory Management" /v SystemPages /t REG_DWORD /d 0xFFFFFFFF /f > /dev/null 2>&1
wine reg add "HKLM\\System\\CurrentControlSet\\Control\\Session Manager\\Memory Management" /v ClearPageFileAtShutdown /t REG_DWORD /d 0 /f > /dev/null 2>&1
wine reg add "HKLM\\System\\CurrentControlSet\\Control\\Session Manager\\Memory Management" /v LargeSystemCache /t REG_DWORD /d 1 /f > /dev/null 2>&1

# 8. Start netsh relay
rm -f "$CMD_FILE" "${CMD_FILE}.proc"
(
    while true; do
        if [ -f "$CMD_FILE" ]; then
            mv "$CMD_FILE" "${CMD_FILE}.proc" 2>/dev/null || continue
            while IFS= read -r cmd; do
                cmd=$(printf '%s' "$cmd" | tr -d '\r')
                [ -z "$cmd" ] && continue
                sudo sh -c "$cmd" 2>/dev/null
            done < "${CMD_FILE}.proc"
            rm -f "${CMD_FILE}.proc"
        fi
        sleep 0.1
    done
) &
RELAY_PID=$!

# 9. Clear old logs
rm -f "$LOG" "$WINEPREFIX/drive_c/radmin_driver.log" /tmp/radmin_driver.log

# Maximum-logging debug mode (RVPN_DEBUG=1): capture service + GUI crash
# backtraces and a full state bundle on exit. Negligible normal-path overhead
# (no +relay), so the crash still reproduces with original timing.
RVPN_DEBUG="${RVPN_DEBUG:-0}"
if [ "$RVPN_DEBUG" = "1" ]; then
    rm -f "$WINEPREFIX/drive_c/radmin_crash.log" "$WINEPREFIX/drive_c/radmin_hook_debug.log"
    # AeDebug: auto-attach winedbg on any unhandled crash (belt-and-suspenders
    # alongside the in-process vectored handler in adapter_hook.dll).
    wine reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug" /v Auto     /t REG_SZ /d 1                    /f >/dev/null 2>&1 || true
    wine reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug" /v Debugger /t REG_SZ /d "winedbg --auto %ld %ld" /f >/dev/null 2>&1 || true
    # Force GUI under winedbg so RvRvpnGui faults dump a full symbolized bt.
    RVPN_GUI_WINEDBG=1
    echo "[*] RVPN_DEBUG=1 — maximum logging active (service+GUI crash capture + bundle no exit)"
fi

# Force native netsh.exe: wine-staging 11.x prefers its builtin stub even when a
# native PE sits in syswow64, so our wrapper would be skipped. Deferred to here
# so the install-phase firewall CA can use Wine's builtin stub (our wrapper
# doesn't exist until step 3 copies it).
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree=;mshtml=};netsh.exe=n"

# Note: the CSetupAdapter dangling-INetwork crash (joining a network with many
# networks active) is fixed at runtime by adapter_hook.dll's release guard
# (install_release_guard), injected before RvControlSvc starts. No static patch
# of RvControlSvc.exe is needed.

cd "$RADMIN"
# Service Wine debug channels: silent by default, +seh backtrace when debugging.
_svc_winedebug="-all"
[ "$RVPN_DEBUG" = "1" ] && _svc_winedebug="+seh,+tid,+pid"
WINEDEBUG="$_svc_winedebug" WINE_LARGE_ADDRESS_AWARE=1 wine rvpn_launcher.exe /run > /tmp/radmin_service.log 2>&1 &

SERVICE_START=$(date +%s)
for _ in $(seq 1 60); do
    sleep 0.5
    if [ -f "$LOG" ]; then
        log_txt=$(iconv -f UTF-16LE -t UTF-8 "$LOG" 2>/dev/null || true)
        # Radmin VPN 1.4 registers the adapter but never reaches "ready" under
        # our shim — detect early and bail with a clear message.
        if printf '%s' "$log_txt" | grep -qE 'Service version: *1\.4'; then
            ver=$(printf '%s' "$log_txt" | grep -oE 'Service version: *[0-9.]+' | head -n1)
            echo ""
            echo "[-] Unsupported version ($ver). Use Radmin VPN 2.0.x."
            echo "    rm -rf \"$WINEPREFIX\" && ./run.sh --installer /path/to/Radmin_VPN_2.0.*.exe"
            exit 1
        fi
        vpn_ip=$(printf '%s' "$log_txt" | python3 -c "
import sys, re
lines = sys.stdin.read().strip().split('\n')
has_ready = any('adapter ready' in l for l in lines)
if has_ready:
    for l in reversed(lines):
        if 'Registered as' in l or ('IP:' in l and '0.0.0.0' not in l):
            m = re.search(r'26\.\d+\.\d+\.\d+', l)
            if m: print(m.group()); break
" 2>/dev/null)
        if [ -n "$vpn_ip" ]; then
            break
        fi
    fi
    pgrep -f RvControlSvc >/dev/null || {
        dump_diagnostics "Service started then died (waited $(( $(date +%s) - SERVICE_START ))s)"
        echo "Error: service exited"
        exit 1
    }
done

if [ -z "${vpn_ip:-}" ]; then
    dump_diagnostics "Service alive but never became ready (timed out after $(( $(date +%s) - SERVICE_START ))s)"
    echo "[-] Service never reported ready — see diagnostics above."
    exit 1
fi

if [ -n "$vpn_ip" ]; then
    sudo ip addr add "$vpn_ip/8" dev "$TAP_DEV" 2>/dev/null || true
    sudo ip link set "$TAP_DEV" up 2>/dev/null || true
fi
sudo ip route replace 26.0.0.0/8 dev "$TAP_DEV"
if [ "$NO_BCAST_ROUTES" = "0" ]; then
    sudo ip route append 255.255.255.255/32 dev "$TAP_DEV" metric 0 2>/dev/null || true
    sudo ip route append 224.0.0.0/4        dev "$TAP_DEV" metric 0 2>/dev/null || true
    echo "[+] Routes: broadcast + multicast IPv4 → $TAP_DEV (use --no-broadcast-routes to disable)"
fi

# Patch Qt's qwindows.dll to survive malformed font name-table offsets that Wine
# returns for some host fonts (the chat-crash root cause). Idempotent: re-running
# detects an already-patched dll. Opt-in via --fix-chat.
if [ "$FIX_CHAT" -eq 1 ]; then
    if [ -f "$DIR/patch_qwindows_font.py" ] && [ -f "$RADMIN/platforms/qwindows.dll" ]; then
        python3 "$DIR/patch_qwindows_font.py" "$RADMIN/platforms/qwindows.dll" >/dev/null 2>&1 \
            && echo "[+] chat fix applied (qwindows.dll patched)" \
            || echo "[!] warning: qwindows.dll patch failed — chat may crash"
    fi
fi

# GUI launch.
#
# Chat crash root cause (confirmed via Wine backtrace + IAT disasm): the crash is
# an access violation (0xc0000005) inside Qt5Core!QString::fromUtf16 at +0x1D, the
# size<0 NUL-scan path (cmp word [ecx],ax). It is NOT the OpenGL scenegraph -- the
# app calls fromUtf16/fromWCharArray on a UTF-16 pointer that is non-NULL but
# points to freed/garbage memory. On Windows that page stays committed (garbage,
# no crash); under Wine it is unmapped -> fault. See debug knobs below to capture
# the exact caller.
#
#   RVPN_GUI_DEBUG=1    -> un-silence Wine; unhandled exception backtrace to
#                          /tmp/radmin_gui.log (WINE_GUI_DEBUG overrides channels).
#   RVPN_GUI_WINEDBG=1  -> run the GUI under `winedbg --auto` so the crash prints a
#                          FULL symbolized backtrace (module+offset+return addrs)
#                          to /tmp/radmin_gui.log before run.sh cleanup tears Wine
#                          down. Use this to identify the crashing call site.
#   QT_QUICK_BACKEND    -> e.g. "software" to force raster (unrelated to this bug,
#                          left unset by default now).
GUI_PID=""
if [ "$NO_UI" -eq 0 ]; then
    [ -n "${QT_QUICK_BACKEND:-}" ] && export QT_QUICK_BACKEND
    _gui_winedebug="-all"
    if [ "${RVPN_GUI_DEBUG:-0}" = "1" ]; then
        _gui_winedebug="${WINE_GUI_DEBUG:-+seh,+tid}"
    fi
    if [ "${RVPN_GUI_WINEDBG:-0}" = "1" ]; then
        # Batch-drive winedbg over stdin: "c" runs the GUI; on an unhandled fault
        # winedbg regains control and we dump backtraces, then quit. Captures the
        # crashing call site (module+offset+return addresses) to /tmp/radmin_gui.log.
        printf 'c\ninfo share\nbt\nbt all\nquit\n' \
            | WINEDEBUG=-all winedbg "C:\\Program Files (x86)\\Radmin VPN\\RvRvpnGui.exe" \
            > /tmp/radmin_gui.log 2>&1 &
    else
        LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
            WINEDEBUG="$_gui_winedebug" \
            wine RvRvpnGui.exe > /tmp/radmin_gui.log 2>&1 &
    fi
    GUI_PID=$!
else
    echo "[*] --no-ui: GUI not launched (service runs headless)"
fi

# Packet-filter UI is opt-in via --filter-ui (and never with --no-ui).
if [ "$FILTER_UI" -eq 1 ] && [ "$NO_UI" -eq 0 ] && [ -x "$BUILD_DIR/rvpn_filter_ui" ]; then
    "$BUILD_DIR/rvpn_filter_ui" > /tmp/radmin_filter_ui.log 2>&1 &
    FILTER_UI_PID=$!
fi

echo "Radmin VPN - service active"


if [ -n "$GUI_PID" ]; then
    wait "$GUI_PID" || true
else
    # Headless: no GUI to wait on — block on the service instead so cleanup
    # (trap) still fires on Ctrl+C / service exit.
    wait || true
fi
