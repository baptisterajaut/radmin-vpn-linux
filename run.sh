#!/bin/bash
# run.sh - Radmin VPN on Linux
# Usage: ./run.sh [--installer /path/to/Radmin_VPN_*.exe]
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
export WINEDEBUG="-all"
# Disable wine-mono + wine-gecko auto-install dialogs — Radmin VPN needs neither.
# netsh.exe override is set LATER (just before service start) — setting it here breaks
# the Inno Setup firewall CA on fresh prefixes (our netsh wrapper isn't copied yet,
# "n" blocks the builtin fallback, CreateProcess fails with c0000135 → install rolls back).
export WINEDLLOVERRIDES="mscoree=;mshtml="
# Suppress core dumps from expected transient crashes (Radmin's NDIS driver loading under wine).
# Keeps systemd-coredump / DrKonqi / apport quiet.
ulimit -c 0 2>/dev/null || true
export WINEPREFIX="${WINEPREFIX:-$DIR/wineprefix}"
RADMIN_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Radmin VPN"
BUILD_DIR="${BUILD_DIR:-$DIR/build}"
TAP_DEV="radminvpn0"
CMD_FILE="/tmp/radmin_netsh_cmd"
LOG="$WINEPREFIX/drive_c/ProgramData/Famatech/Radmin VPN/service.log"
MAC_FILE="$WINEPREFIX/radmin_mac"
RELAY_PID=""
BRIDGE_PID=""

# GUI fallback helpers: zenity → kdialog → xmessage → stdout/stdin
gui_info() {
    command -v zenity   >/dev/null 2>&1 && { zenity --info --title="$1" --no-wrap --text="$2" 2>/dev/null && return; }
    command -v kdialog  >/dev/null 2>&1 && { kdialog --title "$1" --msgbox "$2" 2>/dev/null && return; }
    command -v xmessage >/dev/null 2>&1 && { xmessage -center -buttons OK "$1: $2" 2>/dev/null && return; }
    echo "[*] $2"
}
gui_pick_installer() {
    command -v zenity  >/dev/null 2>&1 && { zenity --file-selection --title="Select Radmin VPN installer" --file-filter="Radmin VPN installer | Radmin_VPN_*.exe" 2>/dev/null && return; }
    command -v kdialog >/dev/null 2>&1 && { kdialog --title "Select Radmin VPN installer" --getopenfilename "$HOME" "Radmin_VPN_*.exe" 2>/dev/null && return; }
    echo "[?] Enter path to Radmin VPN installer (Radmin_VPN_*.exe):" >&2
    read -r _p && printf '%s\n' "$_p"
}

dump_log() {
    local name="$1" path="$2" transform="${3:-}"
    echo "--- $name ($path) ---"
    if [ ! -e "$path" ]; then
        echo "  (file not found)"
    elif [ ! -s "$path" ]; then
        echo "  (empty)"
    elif [ "$transform" = "utf16" ]; then
        iconv -f UTF-16LE -t UTF-8 "$path" 2>/dev/null | tail -n 40 | sed 's/^/  /'
    else
        tail -n 40 "$path" | sed 's/^/  /'
    fi
    echo ""
}

# Wine version utils. AppImage (bundled) sets $APPIMAGE; system Wine does not.
wine_version_str() { wine --version 2>/dev/null | head -n1; }
wine_major() { wine_version_str | sed -n 's/^wine-\([0-9]\+\).*/\1/p'; }

DIAG_FAILS=0
diag_ok()   { echo "  [ok]   $1"; }
diag_miss() { echo "  [MISS] $1"; DIAG_FAILS=$((DIAG_FAILS+1)); }
diag_bad()  { echo "  [BAD]  $1"; DIAG_FAILS=$((DIAG_FAILS+1)); }

dump_diagnostics() {
    DIAG_FAILS=0
    echo ""
    echo "===================== DIAGNOSTICS ====================="
    echo "[-] $1"
    echo ""

    echo "--- Environment ---"
    local wv wmaj src
    wv=$(wine_version_str || echo '?')
    wmaj=$(wine_major || echo 0)
    if [ -n "${APPIMAGE:-}" ]; then
        src="bundled (AppImage)"
    else
        src="system ($(command -v wine 2>/dev/null || echo '?'))"
    fi
    echo "  [info] Wine: $wv — $src"
    if [ "${wmaj:-0}" -lt 11 ] 2>/dev/null; then
        diag_bad "Wine $wv is older than 11.0 — known to break the driver (overlapped I/O changes)"
    fi
    echo "  [info] WINEPREFIX: $WINEPREFIX"
    echo "  [info] Kernel: $(uname -srm)"
    echo ""

    echo "--- Processes ---"
    for name in RvControlSvc.exe rvpn_launcher.exe services.exe wineserver tap_bridge; do
        local pids
        pids=$(pgrep -af "$name" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            echo "  [alive] $name"
            printf '%s\n' "$pids" | sed 's/^/          /'
        else
            echo "  [dead]  $name"
        fi
    done
    echo ""

    echo "--- Sanity checks ---"
    [ -f "$WINEPREFIX/drive_c/windows/system32/drivers/rvpnnetmp.sys" ] \
        && diag_ok "driver rvpnnetmp.sys installed" \
        || diag_miss "driver rvpnnetmp.sys missing"
    [ -f "$RADMIN_DIR/RvControlSvc.exe" ] \
        && diag_ok "RvControlSvc.exe present" \
        || diag_miss "RvControlSvc.exe missing"
    [ -f "$RADMIN_DIR/adapter_hook.dll" ] \
        && diag_ok "adapter_hook.dll present" \
        || diag_miss "adapter_hook.dll missing"
    [ -f "$RADMIN_DIR/rvpn_launcher.exe" ] \
        && diag_ok "rvpn_launcher.exe present" \
        || diag_miss "rvpn_launcher.exe missing"
    [ -f "$WINEPREFIX/drive_c/windows/syswow64/netsh.exe" ] \
        && diag_ok "netsh.exe wrapper installed" \
        || diag_miss "netsh.exe wrapper missing"
    if [ -p /tmp/rvpn_b2d ] && [ -p /tmp/rvpn_d2b ]; then
        diag_ok "FIFOs /tmp/rvpn_{b2d,d2b}"
    else
        diag_miss "FIFOs /tmp/rvpn_{b2d,d2b}"
    fi
    if [ -f /tmp/rvpn_mac ] && [ "$(stat -c%s /tmp/rvpn_mac 2>/dev/null)" = "6" ]; then
        diag_ok "/tmp/rvpn_mac (6 bytes)"
    else
        diag_bad "/tmp/rvpn_mac missing or wrong size"
    fi
    if ip link show "$TAP_DEV" >/dev/null 2>&1; then
        diag_ok "TAP $TAP_DEV up ($(ip -br link show "$TAP_DEV" | awk '{print $2,$3}'))"
    else
        diag_miss "TAP $TAP_DEV not found"
    fi
    local rvpn_start
    rvpn_start=$(wine reg query "HKLM\\SYSTEM\\CurrentControlSet\\Services\\rvpnnetmp" /v Start 2>/dev/null \
        | grep -oE '0x[0-9a-f]+' | head -n1)
    [ -n "$rvpn_start" ] \
        && diag_ok "registry rvpnnetmp (Start=$rvpn_start)" \
        || diag_miss "registry rvpnnetmp not found"
    echo ""

    dump_log "launcher stdout/stderr" /tmp/radmin_service.log
    dump_log "driver log"             "$WINEPREFIX/drive_c/radmin_driver.log"
    dump_log "service log (Famatech)" "$LOG" utf16
    dump_log "tap_bridge log"         /tmp/radmin_bridge.log

    echo "--- Summary ---"
    if [ "$DIAG_FAILS" -eq 0 ]; then
        echo "  All sanity checks passed."
    else
        echo "  $DIAG_FAILS check(s) failed — see [MISS]/[BAD] above."
    fi
    echo "======================================================="
    echo ""
    echo "Please attach the block above when reporting a bug:"
    echo "  https://github.com/baptisterajaut/radmin-vpn-linux/issues"
    echo ""
}

# Retry the service once with Wine err-channel logging enabled. Called only when
# dump_diagnostics found nothing wrong — gives us a hope of catching the crash
# cause when the launcher log is empty (service dies before writing anything).
retry_verbose() {
    echo "[*] All sanity checks passed — retrying with WINEDEBUG=err+all to capture the crash..."
    echo ""
    wineserver -k 2>/dev/null || true
    sleep 1
    ( cd "$RADMIN_DIR" && \
        WINEDEBUG="err+all,fixme-all" timeout 15 wine rvpn_launcher.exe /run \
        > /tmp/radmin_service_verbose.log 2>&1 ) || true
    wineserver -k 2>/dev/null || true
    sleep 1
    dump_log "verbose launcher output (WINEDEBUG=err+all)" /tmp/radmin_service_verbose.log
}

# Parse args
INSTALLER=""
for arg in "$@"; do
    case "$arg" in
        --installer) shift; INSTALLER="$1"; shift ;;
        --installer=*) INSTALLER="${arg#*=}" ;;
    esac
done

# Find installer if not specified (search common locations)
if [ -z "$INSTALLER" ]; then
    for p in "$DIR" "${RADMIN_DATA_DIR:-}" "$HOME/Downloads" "$PWD"; do
        [ -n "$p" ] && [ -d "$p" ] || continue
        INSTALLER=$(find "$p" -maxdepth 1 -name "Radmin_VPN_*.exe" -print -quit 2>/dev/null || true)
        [ -n "$INSTALLER" ] && break
    done
fi
# No installer found + Radmin not installed → prompt user
if [ -z "$INSTALLER" ] && [ ! -f "$RADMIN_DIR/RvControlSvc.exe" ]; then
    gui_info "Radmin VPN — installer needed" \
        "Radmin VPN installer not found.\n\nDownload Radmin_VPN_*.exe from https://www.radmin-vpn.com/\nand select it in the next window."
    INSTALLER=$(gui_pick_installer || true)
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
command -v iconv >/dev/null || { echo "[-] iconv not found."; exit 1; }
# Wine version gate: we require >= 11.0 for overlapped I/O semantics. Bundled Wine
# in the AppImage is 11.6, so this only trips on system Wine installs.
WINE_VERSION_STR=$(wine_version_str || echo '?')
WINE_MAJOR=$(wine_major || echo 0)
if [ -n "${APPIMAGE:-}" ]; then
    echo "[*] Using bundled Wine ($WINE_VERSION_STR)"
elif ! [ "${WINE_MAJOR:-0}" -ge 11 ] 2>/dev/null; then
    echo "[-] Wine $WINE_VERSION_STR is too old — Radmin VPN requires Wine >= 11.0."
    echo "    Upgrade wine-staging on your distro, or use the AppImage release"
    echo "    (https://github.com/baptisterajaut/radmin-vpn-linux/releases) which"
    echo "    bundles Wine 11.6."
    exit 1
fi
# Skip sudo validation if AppRun already primed it (avoids a second password prompt).
if [ "${RADMIN_SUDO_PRIMED:-}" != "1" ]; then
    sudo -v || { echo "[-] Need sudo for TAP device."; exit 1; }
fi

# 1. Kill any previous Wine session
wineserver -k 2>/dev/null || true
sleep 1

# 2. Install Radmin if not present
if [ ! -f "$RADMIN_DIR/RvControlSvc.exe" ]; then
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
        [ -f "$RADMIN_DIR/RvControlSvc.exe" ] && break
    done
    if [ ! -f "$RADMIN_DIR/RvControlSvc.exe" ]; then
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
cp "$BUILD_DIR/adapter_hook.dll" "$RADMIN_DIR/"
cp "$BUILD_DIR/rvpn_launcher.exe" "$RADMIN_DIR/"
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
# Force native netsh.exe: wine-staging 11.x prefers its builtin stub even when a native
# PE sits in syswow64, so our wrapper would be skipped. "n" (native only) is the one-flag
# fix that restored IP assignment. Deferred to here so the install-phase firewall CA
# can use Wine's builtin stub (our wrapper doesn't exist until step 3 runs).
export WINEDLLOVERRIDES="mscoree=;mshtml=;netsh.exe=n"
echo "[*] Starting Radmin VPN service..."
cd "$RADMIN_DIR"
wine rvpn_launcher.exe /run > /tmp/radmin_service.log 2>&1 &

# 11. Wait for service ready + extract VPN IP
echo "[*] Waiting for service ready..."
SERVICE_START=$(date +%s)
SERVICE_SEEN=0
for _ in $(seq 1 60); do
    sleep 1
    if [ -f "$LOG" ]; then
        log_txt=$(iconv -f UTF-16LE -t UTF-8 "$LOG" 2>/dev/null || true)
        if printf '%s' "$log_txt" | grep -q 'adapter ready'; then
            vpn_ip=$(printf '%s' "$log_txt" \
                | grep -E 'Registered as|IP:' \
                | grep -v '0\.0\.0\.0' \
                | grep -oE '26\.[0-9]+\.[0-9]+\.[0-9]+' \
                | tail -n1)
            if [ -n "$vpn_ip" ]; then
                echo "[+] VPN IP: $vpn_ip"
                break
            fi
        fi
    fi
    if pgrep -f RvControlSvc >/dev/null; then
        SERVICE_SEEN=1
    else
        elapsed=$(( $(date +%s) - SERVICE_START ))
        if [ "$SERVICE_SEEN" = "1" ]; then
            dump_diagnostics "Service started then died after ${elapsed}s"
            [ "$DIAG_FAILS" -eq 0 ] && retry_verbose
            exit 1
        elif [ "$elapsed" -ge 5 ]; then
            dump_diagnostics "Service never started (waited ${elapsed}s — launcher or injection failed)"
            [ "$DIAG_FAILS" -eq 0 ] && retry_verbose
            exit 1
        fi
    fi
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
wine "$RADMIN_DIR/RvRvpnGui.exe" > /tmp/radmin_gui.log 2>&1 &
GUI_PID=$!

echo "[+] Radmin VPN running. Close the GUI or press Ctrl+C to stop."
echo ""

wait $GUI_PID || true
