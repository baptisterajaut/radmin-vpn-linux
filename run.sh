#!/bin/bash
# run.sh - Radmin VPN on Linux
# Usage: ./run.sh [--installer /path/to/Radmin_VPN_*.exe]
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

export WINEDEBUG="-all"
export WINEPREFIX="$HOME/.local/share/wineprefixes/radmin_vpn"

export RADMIN="$WINEPREFIX/drive_c/Program Files (x86)/Radmin VPN"
export BUILD_DIR="$DIR/build"
export TAP_DEV="radminvpn0"
export CMD_FILE="/tmp/radmin_netsh_cmd"
export LOG="$WINEPREFIX/drive_c/ProgramData/Famatech/Radmin VPN/service.log"
export MAC_FILE="$WINEPREFIX/radmin_mac"
export RELAY_PID=""
export BRIDGE_PID=""

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
    wineserver -k 2>/dev/null || true
    sleep 1
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null || true
    [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
    sudo ip link delete "$TAP_DEV" 2>/dev/null || true
    rm -f "$CMD_FILE" "${CMD_FILE}.proc" /tmp/rvpn_b2d /tmp/rvpn_d2b /tmp/rvpn_mac
    echo "[*] Done"
}
trap cleanup EXIT

echo "[*] Radmin VPN for Linux"

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
        echo "    ./run.sh --installer /path/to/Radmin_VPN_*.exe"
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
echo "[+] TAP $TAP_DEV created (MAC=$ADAPTER_MAC)"

# 6. Start tap_bridge
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

# 7. Get TAP GUID from Wine and update registry
echo "[*] Detecting TAP adapter GUID..."
TAP_GUID=$(wine wmic path Win32_NetworkAdapter get Name,GUID 2>/dev/null \
    | grep "$TAP_DEV" | awk '{print $1}' | tr -d '\r')
if [ -z "$TAP_GUID" ]; then
    echo "[-] Could not read TAP GUID from Wine WMI"
    exit 1
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

# 10. Start service
echo "[*] Starting Radmin VPN service..."
cd "$RADMIN"
wine rvpn_launcher.exe /run > /tmp/radmin_service.log 2>&1 &

# 11. Wait for service ready + extract VPN IP
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

# 12. Set up on-link route
sleep 2
sudo ip route replace 26.0.0.0/8 dev "$TAP_DEV"
echo "[+] Route: 26.0.0.0/8 dev $TAP_DEV (on-link)"
echo ""
ip addr show "$TAP_DEV" 2>/dev/null | grep -E "inet |state"
echo ""

# 13. Launch GUI
echo "[*] Starting GUI..."
wine RvRvpnGui.exe > /tmp/radmin_gui.log 2>&1 &
GUI_PID=$!

echo "[+] Radmin VPN running. Close the GUI or press Ctrl+C to stop."
echo ""

wait $GUI_PID || true
