#!/bin/bash
# run_datacenter.sh - Radmin VPN Datacenter Edition
# Runs on headless VPS (no display server) using Xvfb + noVNC for web-based GUI access
# Usage: ./run_datacenter.sh [--installer /path/to/Radmin_VPN_*.exe] [--vnc-port PORT] [--web-port PORT] [--vnc-password PASS] [--web-bind ADDR]
#   --web-bind ADDR  noVNC listen address (default 127.0.0.1; use 0.0.0.0 to expose publicly, only with --vnc-password)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

_distro() {
    if command -v dnf      >/dev/null 2>&1; then printf 'fedora'
    elif command -v apt-get >/dev/null 2>&1; then printf 'debian'
    elif command -v pacman  >/dev/null 2>&1; then printf 'arch'
    elif command -v zypper  >/dev/null 2>&1; then printf 'suse'
    else printf 'unknown'; fi
}

_wine_install_hint() {
    case "$(_distro)" in
        fedora)  echo "  sudo dnf install wine winetricks" ;;
        debian)  echo "  sudo apt install wine winetricks" ;;
        arch)    echo "  sudo pacman -S wine winetricks" ;;
        suse)    echo "  sudo zypper install wine winetricks" ;;
        *)       echo "  Install wine from: https://www.winehq.org/" ;;
    esac
}

export WINEPREFIX="$DIR/wineprefix"
RADMIN="$WINEPREFIX/drive_c/Program Files (x86)/Radmin VPN"
BUILD_DIR="$DIR/build"
TAP_DEV="radminvpn0"
CMD_FILE="/tmp/radmin_netsh_cmd"
LOG="$WINEPREFIX/drive_c/ProgramData/Famatech/Radmin VPN/service.log"
MAC_FILE="$WINEPREFIX/radmin_mac"
GUID_FILE="$WINEPREFIX/radmin_guid"

# Virtual display settings
VNC_DISPLAY=:99
VNC_PORT=5900
WEB_PORT=6080
VNC_PASSWORD=""
NOVNC_PATH=""
# Web (noVNC) bind address. Default 127.0.0.1 = reachable only via SSH tunnel.
# Pass --web-bind 0.0.0.0 to expose it publicly (only with --vnc-password!).
WEB_BIND="127.0.0.1"

# PIDs for cleanup
XVFB_PID=""
X11VNC_PID=""
WEBSOCKIFY_PID=""
RELAY_PID=""
BRIDGE_PID=""
GUI_PID=""

# Parse args
INSTALLER=""
for arg in "$@"; do
    case "$arg" in
        --installer) shift; INSTALLER="$1"; shift ;;
        --installer=*) INSTALLER="${arg#*=}" ;;
        --vnc-port) shift; VNC_PORT="$1"; shift ;;
        --vnc-port=*) VNC_PORT="${arg#*=}" ;;
        --web-port) shift; WEB_PORT="$1"; shift ;;
        --web-port=*) WEB_PORT="${arg#*=}" ;;
        --vnc-password) shift; VNC_PASSWORD="$1"; shift ;;
        --vnc-password=*) VNC_PASSWORD="${arg#*=}" ;;
        --web-bind) shift; WEB_BIND="$1"; shift ;;
        --web-bind=*) WEB_BIND="${arg#*=}" ;;
    esac
done

# Find installer if not specified
if [ -z "$INSTALLER" ]; then
    INSTALLER=$(find "$DIR" -maxdepth 1 -name "Radmin_VPN_*.exe" -print -quit 2>/dev/null || true)
fi

cleanup() {
    echo "[*] Stopping datacenter edition..."
    [ -n "$GUI_PID" ] && kill "$GUI_PID" 2>/dev/null || true
    wineserver -k 2>/dev/null || true
    sleep 1
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null || true
    [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
    [ -n "$WEBSOCKIFY_PID" ] && kill "$WEBSOCKIFY_PID" 2>/dev/null || true
    [ -n "$X11VNC_PID" ] && kill "$X11VNC_PID" 2>/dev/null || true
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
    sudo ip link delete "$TAP_DEV" 2>/dev/null || true
    rm -f "$CMD_FILE" "${CMD_FILE}.proc" /tmp/rvpn_b2d /tmp/rvpn_d2b /tmp/rvpn_mac /tmp/rvpn_filters.json
    rm -f /tmp/rvpn_vnc_password /tmp/.X${VNC_DISPLAY#:}-lock
    echo "[*] Done"
}
trap cleanup EXIT

echo "[*] Radmin VPN Datacenter Edition"
echo "    Virtual display + web-based GUI access"
echo ""

# ── Prerequisites ──
_missing=""
command -v wine       >/dev/null || _missing="$_missing wine"
command -v wineserver >/dev/null || _missing="$_missing wineserver"
command -v python3    >/dev/null || _missing="$_missing python3"
command -v ip         >/dev/null || _missing="$_missing ip(iproute2)"
if [ -n "$_missing" ]; then
    echo "[-] Missing dependencies:$_missing"
    _wine_install_hint
    exit 1
fi
sudo -v || { echo "[-] Need sudo for TAP device."; exit 1; }

if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    echo "[!] SELinux Enforcing detected. If failures occur, try:"
    echo "    sudo setsebool -P allow_execmod on"
    echo "    sudo chcon -t bin_t \"$BUILD_DIR/tap_bridge\""
fi

# Check for virtual display components
MISSING_DC=()
command -v Xvfb >/dev/null || MISSING_DC+=("xvfb")
command -v x11vnc >/dev/null || MISSING_DC+=("x11vnc")
command -v websockify >/dev/null || MISSING_DC+=("websockify")

if [ ${#MISSING_DC[@]} -gt 0 ]; then
    echo "[-] Missing datacenter components: ${MISSING_DC[*]}"
    echo "    Install with:"
    echo "      sudo apt install -y xvfb x11vnc websockify"
    echo "    Or run: make install-datacenter-deps"
    exit 1
fi

# Find noVNC web directory (path varies by distro and version)
for p in \
    /usr/share/novnc \
    /usr/share/novnc/www \
    /usr/share/websockify/novnc \
    /usr/lib/novnc \
    /usr/lib/novnc/web \
    /usr/share/webapps/novnc; do
    if [ -d "$p" ] && { [ -f "$p/vnc.html" ] || [ -f "$p/vnc_lite.html" ]; }; then
        NOVNC_PATH="$p"
        break
    fi
done
if [ -z "$NOVNC_PATH" ]; then
    echo "[-] noVNC web files not found. Install:"
    case "$(_distro)" in
        fedora) echo "    sudo dnf install novnc" ;;
        debian) echo "    sudo apt install -y novnc" ;;
        arch)   echo "    yay -S novnc  # AUR" ;;
        *)      echo "    https://novnc.com" ;;
    esac
    exit 1
fi

# ── 1. Kill any previous session ──
wineserver -k 2>/dev/null || true
# Kill leftover Xvfb on our display
if [ -f "/tmp/.X${VNC_DISPLAY#:}-lock" ]; then
    OLD_XVFB_PID=$(cat "/tmp/.X${VNC_DISPLAY#:}-lock" 2>/dev/null | tr -d ' ')
    [ -n "$OLD_XVFB_PID" ] && kill "$OLD_XVFB_PID" 2>/dev/null || true
    rm -f "/tmp/.X${VNC_DISPLAY#:}-lock"
    sleep 1
fi
sleep 1

# ── 2. Start Xvfb (virtual display) ──
echo "[*] Starting virtual display (Xvfb $VNC_DISPLAY)..."
Xvfb "$VNC_DISPLAY" -screen 0 1280x720x24 -ac +extension GLX +render -noreset > /tmp/radmin_xvfb.log 2>&1 &
XVFB_PID=$!
sleep 1

# Verify Xvfb started
if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    echo "[-] Xvfb failed to start. Check /tmp/radmin_xvfb.log"
    exit 1
fi
echo "[+] Xvfb running (pid=$XVFB_PID, display=$VNC_DISPLAY)"

# Set DISPLAY for all Wine processes
export DISPLAY="$VNC_DISPLAY"

# ── 3. Start x11vnc (VNC server) ──
echo "[*] Starting VNC server on port $VNC_PORT..."
VNC_ARGS=(-display "$VNC_DISPLAY" -forever -shared -rfbport "$VNC_PORT" -nopw)

if [ -n "$VNC_PASSWORD" ]; then
    # Write password file for x11vnc
    x11vnc -storepasswd "$VNC_PASSWORD" /tmp/rvpn_vnc_password 2>/dev/null
    VNC_ARGS+=(-rfbauth /tmp/rvpn_vnc_password)
    echo "[+] VNC password set"
elif [ "$WEB_BIND" != "127.0.0.1" ] && [ "$WEB_BIND" != "localhost" ]; then
    echo "[!] DANGER: no VNC password AND web bind is $WEB_BIND (public)."
    echo "    Anyone reaching :$WEB_PORT gets an unauthenticated root-capable desktop."
    echo "    Set --vnc-password, or drop --web-bind to keep it on 127.0.0.1 (SSH-tunnel only)."
else
    echo "[*] VNC has no password but web is bound to $WEB_BIND (reach via SSH tunnel: ssh -L $WEB_PORT:localhost:$WEB_PORT ...)."
fi

x11vnc "${VNC_ARGS[@]}" > /tmp/radmin_x11vnc.log 2>&1 &
X11VNC_PID=$!
sleep 1

if ! kill -0 "$X11VNC_PID" 2>/dev/null; then
    echo "[-] x11vnc failed to start. Check /tmp/radmin_x11vnc.log"
    exit 1
fi
echo "[+] VNC server running (pid=$X11VNC_PID, port=$VNC_PORT)"

# ── 4. Start noVNC (web-based VNC client) ──
echo "[*] Starting noVNC on port $WEB_PORT..."
websockify --web="$NOVNC_PATH" "$WEB_BIND":"$WEB_PORT" localhost:"$VNC_PORT" > /tmp/radmin_novnc.log 2>&1 &
WEBSOCKIFY_PID=$!
sleep 1

if ! kill -0 "$WEBSOCKIFY_PID" 2>/dev/null; then
    echo "[-] websockify/noVNC failed to start. Check /tmp/radmin_novnc.log"
    exit 1
fi

# Detect the right HTML file
NOVNC_HTML="vnc.html"
[ -f "$NOVNC_PATH/vnc_lite.html" ] && NOVNC_HTML="vnc_lite.html"

echo "[+] noVNC running (pid=$WEBSOCKIFY_PID, port=$WEB_PORT)"
echo ""
EXTERNAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
echo "    ┌──────────────────────────────────────────────────────┐"
echo "    │  Open in browser to access Radmin VPN GUI:         │"
echo "    │  http://$EXTERNAL_IP:$WEB_PORT/$NOVNC_HTML   │"
echo "    └──────────────────────────────────────────────────────┘"
echo ""

# ── 5. Install Radmin if not present ──
if [ ! -f "$RADMIN/RvControlSvc.exe" ]; then
    if [ -z "$INSTALLER" ] || [ ! -f "$INSTALLER" ]; then
        echo "[-] Radmin VPN not installed and no installer found."
        echo "    Download from https://www.radmin-vpn.com/ and run:"
        echo "    ./run_datacenter.sh --installer /path/to/Radmin_VPN_*.exe"
        exit 1
    fi
    echo "[*] Installing Radmin VPN..."
    mkdir -p "$WINEPREFIX"
    wineboot --init 2>/dev/null
    echo "[+] Wine prefix created"
    wineserver -k 2>/dev/null || true
    sleep 2
    echo "[*] Running installer..."
    wine "$INSTALLER" /VERYSILENT /NORESTART 2>/dev/null || true
    echo "[*] Waiting for installer to finish..."
    for _ in $(seq 1 30); do
        sleep 2
        [ -f "$RADMIN/RvControlSvc.exe" ] && break
    done
    if [ ! -f "$RADMIN/RvControlSvc.exe" ]; then
        echo "[-] Installer failed — RvControlSvc.exe not found"
        exit 1
    fi
    wineserver -k 2>/dev/null || true
    sleep 1
    # Remove real NDIS driver (crashes Wine — we replace it with rvpnnetmp.sys)
    wine reg delete "HKLM\\SYSTEM\\CurrentControlSet\\Services\\RvNetMP60" /f > /dev/null 2>&1 || true
    rm -f "$WINEPREFIX/drive_c/windows/system32/drivers/RvNetMP60.sys"
    # Disable SCM auto-start (we launch via rvpn_launcher /run)
    wine reg add "HKLM\\SYSTEM\\CurrentControlSet\\Services\\RvControlSvc" /v Start /t REG_DWORD /d 4 /f > /dev/null 2>&1 || true
    wineserver -k 2>/dev/null || true
    sleep 1
    echo "[+] Radmin VPN installed"
fi

# ── 6. Install our components ──
echo "[*] Installing components..."
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

# ── 7. Generate or load persistent adapter MAC ──
if [ -f "$MAC_FILE" ]; then
    ADAPTER_MAC=$(cat "$MAC_FILE")
else
    # Random locally-administered unicast MAC (02:xx:xx:xx:xx:xx)
    ADAPTER_MAC=$(printf '02:%02x:%02x:%02x:%02x:%02x' \
        $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    echo "$ADAPTER_MAC" > "$MAC_FILE"
    echo "[+] Generated adapter MAC: $ADAPTER_MAC"
fi
# Write raw 6 bytes for driver to read
printf '%b' "$(echo "$ADAPTER_MAC" | sed 's/://g; s/../\\x&/g')" > /tmp/rvpn_mac

# ── 8. Create TAP device ──
echo "[*] Creating TAP device..."
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
# Manually join Minecraft LAN multicast group to trigger IGMP membership reports
sudo ip maddr add 224.0.2.60 dev "$TAP_DEV" 2>/dev/null || true
echo "[+] TAP $TAP_DEV created (MAC=$ADAPTER_MAC)"

# ── 9. Start tap_bridge ──
echo "[*] Starting tap_bridge..."
pkill -f tap_bridge 2>/dev/null || true
sleep 0.3
rm -f /tmp/rvpn_b2d /tmp/rvpn_d2b
"$BUILD_DIR/tap_bridge" > /tmp/radmin_bridge.log 2>&1 &
BRIDGE_PID=$!
for _ in $(seq 1 10); do
    [ -p /tmp/rvpn_b2d ] && [ -p /tmp/rvpn_d2b ] && break
    sleep 0.2
done
if [ ! -p /tmp/rvpn_b2d ] || [ ! -p /tmp/rvpn_d2b ]; then
    echo "[-] tap_bridge failed to create FIFOs"
    exit 1
fi
echo "[+] tap_bridge running (pid=$BRIDGE_PID)"

# ── 10. Generate or load persistent TAP GUID ──
echo "[*] Detecting TAP adapter GUID..."
if [ -f "$GUID_FILE" ]; then
    TAP_GUID=$(cat "$GUID_FILE")
else
    # Generate a random GUID (format: {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx})
    TAP_GUID=$(printf '{%08x-%04x-%04x-%04x-%012x}' \
        $((RANDOM%4294967296)) $((RANDOM%65536)) $((RANDOM%65536)) \
        $((RANDOM%65536)) $((RANDOM%281474976710656)))
    echo "$TAP_GUID" > "$GUID_FILE"
    echo "[+] Generated TAP GUID: $TAP_GUID"
fi
echo "[+] TAP GUID: $TAP_GUID"

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
echo "[+] Registry configured"

# Restart wineserver so it loads the driver on next boot
wineserver -k 2>/dev/null || true
sleep 1

# ── 11. Start netsh relay ──
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
        sleep 0.3
    done
) &
RELAY_PID=$!

# ── 12. Clear old logs ──
rm -f "$LOG" "$WINEPREFIX/drive_c/radmin_driver.log"

# ── 13. Start service ──
echo "[*] Starting Radmin VPN service..."
cd "$RADMIN"
wine rvpn_launcher.exe /run > /tmp/radmin_service.log 2>&1 &

# ── 14. Wait for service ready + extract VPN IP ──
echo "[*] Waiting for service ready..."
for _ in $(seq 1 60); do
    sleep 1
    if [ -f "$LOG" ]; then
        vpn_ip=$(python3 -c "
with open('$LOG', 'rb') as f:
    t = f.read().decode('utf-16-le', errors='replace')
lines = t.strip().split('\n')
has_ready = any('adapter ready' in l for l in lines)
if has_ready:
    for l in reversed(lines):
        if 'Registered as' in l or ('IP:' in l and '0.0.0.0' not in l):
            import re
            m = re.search(r'26\.\d+\.\d+\.\d+', l)
            if m: print(m.group()); break
" 2>/dev/null)
        if [ -n "$vpn_ip" ]; then
            echo "[+] VPN IP: $vpn_ip"
            break
        fi
    fi
    pgrep -f RvControlSvc >/dev/null || { echo "[-] Service died"; exit 1; }
done

# ── 15. Assign VPN IP to TAP device + set up route ──
sleep 2
if [ -n "$vpn_ip" ]; then
    # Explicitly assign the VPN IP (fallback if netsh_wrapper wasn't invoked)
    sudo ip addr add "$vpn_ip/8" dev "$TAP_DEV" 2>/dev/null || true
    sudo ip link set "$TAP_DEV" up 2>/dev/null || true
    echo "[+] TAP IP: $vpn_ip/8"
fi
sudo ip route replace 26.0.0.0/8 dev "$TAP_DEV"
echo "[+] Route: 26.0.0.0/8 dev $TAP_DEV (on-link)"
echo ""
ip addr show "$TAP_DEV" 2>/dev/null | grep -E "inet |state"
echo ""

# ── 16. Launch GUI (on virtual display, accessible via noVNC) ──
echo "[*] Starting Radmin VPN GUI on virtual display..."
wine RvRvpnGui.exe > /tmp/radmin_gui.log 2>&1 &
GUI_PID=$!
echo "[+] GUI running on display $VNC_DISPLAY (pid=$GUI_PID)"


echo ""
echo "[+] ═══════════════════════════════════════════════════════════"
echo "[+]  Radmin VPN Datacenter Edition is running"
echo "[+] "
echo "[+]  VPN IP:  ${vpn_ip:-unknown}"
echo "[+]  Web GUI: http://$EXTERNAL_IP:$WEB_PORT/$NOVNC_HTML"
echo "[+]  VNC:     localhost:$VNC_PORT"
echo "[+] "
echo "[+]  Configure your networks via the web GUI."
echo "[+]  After config, the wineprefix can be exported for"
echo "[+]  headless deployment with run_nogui.sh."
echo "[+] ═══════════════════════════════════════════════════════════"
echo ""

# Wait for GUI to exit (or Ctrl+C)
wait $GUI_PID || true
