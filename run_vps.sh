#!/bin/bash
# run_vps.sh - Radmin VPN on Linux for VPS (headless, hardcoded GUID)
# Starts service, waits for ready, then launches rv_net_enum.exe
# Usage: ./run_vps.sh [--installer /path/to/Radmin_VPN_*.exe]
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Shared diagnostics/health library (colors, check_*, dump_diagnostics).
source "$DIR/lib.sh"

export WINEPREFIX="$DIR/wineprefix"
RADMIN="$WINEPREFIX/drive_c/Program Files (x86)/Radmin VPN"
BUILD_DIR="$DIR/build"
TAP_DEV="radminvpn0"
CMD_FILE="/tmp/radmin_netsh_cmd"
LOG="$WINEPREFIX/drive_c/ProgramData/Famatech/Radmin VPN/service.log"
MAC_FILE="$WINEPREFIX/radmin_mac"
CUSTOM_GUI="$DIR/../rv_net_enum.exe"
RELAY_PID=""
BRIDGE_PID=""
FILTER_UI_PID=""

# Hardcoded TAP GUID for VPS (no Wine WMI required)
TAP_GUID="{0000000B-0000-0000-0000-4E6574446576}"

# Parse args
INSTALLER=""
for arg in "$@"; do
    case "$arg" in
        --installer) shift; INSTALLER="$1"; shift ;;
        --installer=*) INSTALLER="${arg#*=}" ;;
    esac
done

# Find installer if not specified
if [ -z "$INSTALLER" ]; then
    INSTALLER=$(find "$DIR" -maxdepth 1 -name "Radmin_VPN_*.exe" -print -quit 2>/dev/null || true)
fi

cleanup() {
    echo "[*] Stopping..."
    [ -n "$FILTER_UI_PID" ] && kill "$FILTER_UI_PID" 2>/dev/null || true
    wineserver -k 2>/dev/null || true
    sleep 1
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null || true
    [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
    sudo ip link delete "$TAP_DEV" 2>/dev/null || true
    rm -f "$CMD_FILE" "${CMD_FILE}.proc" /tmp/rvpn_b2d /tmp/rvpn_d2b_high /tmp/rvpn_d2b_low /tmp/rvpn_mac /tmp/rvpn_filters.json
    echo "[*] Done"
}
trap cleanup EXIT

echo "[*] Radmin VPN for Linux (headless service + custom GUI)"

# Prerequisites
command -v wine >/dev/null || { echo "[-] Wine not found. Install wine."; exit 1; }
command -v wineserver >/dev/null || { echo "[-] wineserver not found."; exit 1; }
command -v python3 >/dev/null || { echo "[-] python3 not found."; exit 1; }
sudo -v || { echo "[-] Need sudo for TAP device."; exit 1; }

# 1. Kill any previous Wine session
wineserver -k 2>/dev/null || true
sleep 1

# 2. Install Radmin if not present
if [ ! -f "$RADMIN/RvControlSvc.exe" ]; then
    if [ -z "$INSTALLER" ] || [ ! -f "$INSTALLER" ]; then
        echo "[-] Radmin VPN not installed and no installer found."
        echo "    Download from https://www.radmin-vpn.com/ and run:"
        echo "    ./run_vps.sh --installer /path/to/Radmin_VPN_*.exe"
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

# 3. Install our components
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

# 4. Generate or load persistent adapter MAC
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

# 5. Create TAP device
echo "[*] Creating TAP device..."
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

# 6. Start tap_bridge
echo "[*] Starting tap_bridge..."
pkill -f tap_bridge 2>/dev/null || true
sleep 0.3
    rm -f /tmp/rvpn_b2d /tmp/rvpn_d2b_high /tmp/rvpn_d2b_low
    "$BUILD_DIR/tap_bridge" > /tmp/radmin_bridge.log 2>&1 &
    BRIDGE_PID=$!
    for _ in $(seq 1 10); do
        [ -p /tmp/rvpn_b2d ] && [ -p /tmp/rvpn_d2b_high ] && [ -p /tmp/rvpn_d2b_low ] && break
        sleep 0.2
    done
    if [ ! -p /tmp/rvpn_b2d ] || [ ! -p /tmp/rvpn_d2b_high ] || [ ! -p /tmp/rvpn_d2b_low ]; then
    echo "[-] tap_bridge failed to create FIFOs"
    exit 1
fi
echo "[+] tap_bridge running (pid=$BRIDGE_PID)"

# 7. Use hardcoded TAP GUID and update registry
echo "[*] Using hardcoded TAP GUID: $TAP_GUID"

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
        sleep 0.3
    done
) &
RELAY_PID=$!

# 9. Clear old logs
rm -f "$LOG" "$WINEPREFIX/drive_c/radmin_driver.log"

# 10. Start service (no original GUI)
echo "[*] Starting Radmin VPN service (headless)..."
cd "$RADMIN"
wine rvpn_launcher.exe /run > /tmp/radmin_service.log 2>&1 &

# 11. Wait for service ready + extract VPN IP
echo "[*] Waiting for service ready..."
SERVICE_START=$(date +%s)
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
    pgrep -f RvControlSvc >/dev/null || {
        dump_diagnostics "Service started then died (waited $(( $(date +%s) - SERVICE_START ))s)"
        echo "[-] Service died"
        exit 1
    }
done

if [ -z "${vpn_ip:-}" ]; then
    dump_diagnostics "Service alive but never became ready (timed out after $(( $(date +%s) - SERVICE_START ))s)"
    echo "[-] Service never reported ready — see diagnostics above."
    exit 1
fi

# 12. Assign VPN IP to TAP device + set up route
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

# 13. Launch custom GUI (rv_net_enum.exe) instead of original RvRvpnGui.exe
if [ -f "$CUSTOM_GUI" ]; then
    echo "[*] Starting custom GUI (rv_net_enum.exe)..."
    wine "$CUSTOM_GUI" > /tmp/radmin_custom_gui.log 2>&1 &
    GUI_PID=$!
    echo "[+] Custom GUI running (pid=$GUI_PID)"
else
    echo "[-] Custom GUI not found at $CUSTOM_GUI"
    echo "    Build it with: i686-w64-mingw32-gcc -o rv_net_enum.exe rv_net_enum.c -mwindows -lkernel32 -luser32 -lgdi32"
    echo "[*] Service is running headless. Press Ctrl+C to stop."
    # Wait indefinitely for service
    while pgrep -f RvControlSvc >/dev/null; do sleep 2; done
    exit 0
fi

# 14. Launch filter UI (GTK4)
if [ -x "$BUILD_DIR/rvpn_filter_ui" ]; then
    echo "[*] Starting filter UI..."
    "$BUILD_DIR/rvpn_filter_ui" > /tmp/radmin_filter_ui.log 2>&1 &
    FILTER_UI_PID=$!
    echo "[+] Filter UI running (pid=$FILTER_UI_PID)"
fi

echo "[+] Radmin VPN running with custom GUI. Close the GUI or press Ctrl+C to stop."
echo ""

wait $GUI_PID || true
