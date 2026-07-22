# lib.sh - Shared diagnostic/health library for Radmin VPN on Linux
#
# Sourceable library: ANSI colors, check_pass/warn/fail helpers, sanity-check
# helpers, and dump_diagnostics(). Meant to be sourced from run.sh,
# run_datacenter.sh, run_vps.sh and health_check.sh.
#
# NOTE: no `set -e` here — a sourced lib must not change the caller's shell
# options. Callers set their own `set -euo pipefail`.

# Guard against double-source.
[ -n "${_RVPN_LIB_SOURCED:-}" ] && return 0
_RVPN_LIB_SOURCED=1

# ── ANSI colors ───────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ── check_* helpers (health-check style) ───────────────────────────────────────
check_pass() { echo -e "${GREEN}[✓]${NC} $1"; }
check_fail() { echo -e "${RED}[✗]${NC} $1"; }
check_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# ── Progress reporting (used by run.sh / run_vps.sh / run_datacenter.sh) ─────────
# Step-by-step narration so the user sees what's happening during the ~30s startup.
say()  { echo    "[*] $1"; }                 # step starting / info
good() { echo -e "${GREEN}[+]${NC} $1"; }    # step succeeded
warn() { echo -e "${YELLOW}[!]${NC} $1"; }   # non-fatal warning
die()  { echo -e "${RED}[-]${NC} $1" >&2; exit 1; }  # fatal — prints and exits

# ── Wine version utils ──────────────────────────────────────────────────────────
# AppImage (bundled) sets $APPIMAGE; system Wine does not.
wine_version_str() { wine --version 2>/dev/null | head -n1; }
wine_major() { wine_version_str | sed -n 's/^wine-\([0-9]\+\).*/\1/p'; }

# ── Diagnostic result helpers (dump_diagnostics style) ──────────────────────────
DIAG_FAILS=0
diag_ok()   { echo "  [ok]   $1"; }
diag_miss() { echo "  [MISS] $1"; DIAG_FAILS=$((DIAG_FAILS+1)); }
diag_bad()  { echo "  [BAD]  $1"; DIAG_FAILS=$((DIAG_FAILS+1)); }

# dump_log NAME PATH [transform]
# Failure-tolerant tail of a log file. transform=utf16 → iconv UTF-16LE→UTF-8.
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
        tail -n 40 "$path" 2>/dev/null | sed 's/^/  /'
    fi
    echo ""
}

# ── Sanity checks ───────────────────────────────────────────────────────────────
# Parameterized on $WINEPREFIX, $TAP_DEV, $RADMIN (Radmin install dir). Every
# check is failure-tolerant so this can run on end-user machines mid-crash.
sanity_checks() {
    local tap="${TAP_DEV:-radminvpn0}"
    local radmin="${RADMIN:-${RADMIN_DIR:-}}"

    [ -f "$WINEPREFIX/drive_c/windows/system32/drivers/rvpnnetmp.sys" ] \
        && diag_ok "driver rvpnnetmp.sys installed" \
        || diag_miss "driver rvpnnetmp.sys missing"
    [ -f "$radmin/RvControlSvc.exe" ] \
        && diag_ok "RvControlSvc.exe present" \
        || diag_miss "RvControlSvc.exe missing"
    [ -f "$radmin/adapter_hook.dll" ] \
        && diag_ok "adapter_hook.dll present" \
        || diag_miss "adapter_hook.dll missing"
    [ -f "$radmin/rvpn_launcher.exe" ] \
        && diag_ok "rvpn_launcher.exe present" \
        || diag_miss "rvpn_launcher.exe missing"
    [ -f "$WINEPREFIX/drive_c/windows/syswow64/netsh.exe" ] \
        && diag_ok "netsh.exe wrapper installed" \
        || diag_miss "netsh.exe wrapper missing"
    if [ -p /tmp/rvpn_b2d ] && [ -p /tmp/rvpn_d2b_high ] && [ -p /tmp/rvpn_d2b_low ]; then
        diag_ok "FIFOs /tmp/rvpn_{b2d,d2b_high,d2b_low}"
    else
        diag_miss "FIFOs /tmp/rvpn_{b2d,d2b_high,d2b_low}"
    fi
    if [ -f /tmp/rvpn_mac ] && [ "$(stat -c%s /tmp/rvpn_mac 2>/dev/null)" = "6" ]; then
        diag_ok "/tmp/rvpn_mac (6 bytes)"
    else
        diag_bad "/tmp/rvpn_mac missing or wrong size"
    fi
    if ip link show "$tap" >/dev/null 2>&1; then
        diag_ok "TAP $tap up ($(ip -br link show "$tap" 2>/dev/null | awk '{print $2,$3}'))"
    else
        diag_miss "TAP $tap not found"
    fi
    local rvpn_start
    rvpn_start=$(wine reg query "HKLM\\SYSTEM\\CurrentControlSet\\Services\\rvpnnetmp" /v Start 2>/dev/null \
        | grep -oE '0x[0-9a-f]+' | head -n1)
    [ -n "$rvpn_start" ] \
        && diag_ok "registry rvpnnetmp (Start=$rvpn_start)" \
        || diag_miss "registry rvpnnetmp not found"
}

# ── dump_diagnostics REASON ─────────────────────────────────────────────────────
# Prints a self-contained diagnostics block. Every capture is failure-tolerant:
# a missing file or command must never abort the dump (runs on end-user boxes).
dump_diagnostics() {
    DIAG_FAILS=0
    local tap="${TAP_DEV:-radminvpn0}"
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
    echo "  [info] WINEPREFIX: ${WINEPREFIX:-?}"
    echo "  [info] Kernel: $(uname -srm 2>/dev/null || echo '?')"
    echo ""

    echo "--- Processes ---"
    local name pids
    for name in RvControlSvc.exe rvpn_launcher.exe services.exe wineserver tap_bridge; do
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
    sanity_checks
    echo ""

    # ── Network / protocol layer (the "registers but never ready" bug is a
    #    connectivity/protocol issue, not just an adapter one) ──
    echo "--- Adapter ---"
    ip addr show "$tap" 2>/dev/null | sed 's/^/  /' || echo "  (ip addr failed)"
    local operstate carrier
    operstate=$(cat "/sys/class/net/$tap/operstate" 2>/dev/null || echo '?')
    carrier=$(cat "/sys/class/net/$tap/carrier" 2>/dev/null || echo '?')
    echo "  operstate=$operstate carrier=$carrier"
    echo ""

    echo "--- Outbound connections (service → Famatech) ---"
    # Match only the service process (ss/netstat show its comm truncated to
    # "RvControlSvc.e"); a bare wine/.exe match caught unrelated Proton games.
    if command -v ss >/dev/null 2>&1; then
        ss -tanp 2>/dev/null | grep 'RvControlSvc' | sed 's/^/  /' || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tanp 2>/dev/null | grep 'RvControlSvc' | sed 's/^/  /' || true
    else
        echo "  (neither ss nor netstat available)"
    fi
    echo ""

    echo "--- Firewall ---"
    local fw
    fw=$(command -v nft iptables firewall-cmd 2>/dev/null | sed 's/^/  /')
    if [ -n "$fw" ]; then
        echo "$fw"
    else
        echo "  (no nft/iptables/firewalld found)"
    fi
    if command -v nft >/dev/null 2>&1; then
        echo "  --- nft ruleset (first 40 lines, best-effort; may need root) ---"
        nft list ruleset 2>/dev/null | head -n 40 | sed 's/^/  /' || true
    fi
    echo ""

    dump_log "launcher stdout/stderr" /tmp/radmin_service.log
    dump_log "driver log"             "$WINEPREFIX/drive_c/radmin_driver.log"
    dump_log "adapter_hook log"       "$WINEPREFIX/drive_c/radmin_hook_debug.log"
    dump_log "service log (Famatech)" "${LOG:-$WINEPREFIX/drive_c/ProgramData/Famatech/Radmin VPN/service.log}" utf16
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

# ── health_check ────────────────────────────────────────────────────────────────
# Build/preflight environment check (wine, compilers, kernel TUN/TAP, sudo, build
# artifacts, wineprefix, stray processes). Distinct from sanity_checks() above,
# which validates the *runtime* state of a live session. Honors $WINEPREFIX and
# $BUILD_DIR if already set, else defaults to the repo-relative ./ paths.
health_check() {
    local build="${BUILD_DIR:-./build}"
    local prefix="${WINEPREFIX:-./wineprefix}"

    echo "=== Radmin VPN Linux Health Check ==="
    echo

    echo "Checking Wine installation..."
    if command -v wine >/dev/null 2>&1; then
        local wv wmaj
        wv=$(wine --version)
        check_pass "Wine installed: $wv"
        wmaj=$(echo "$wv" | grep -oP 'wine-\K\d+' || echo "0")
        if [ "$wmaj" -ge 11 ]; then
            check_pass "Wine version >= 11.0"
        else
            check_fail "Wine version < 11.0 (required: >= 11.0)"
        fi
    else
        check_fail "Wine not found"
    fi
    echo

    echo "Checking wineserver..."
    command -v wineserver >/dev/null 2>&1 \
        && check_pass "wineserver found" || check_fail "wineserver not found"
    echo

    echo "Checking mingw-w64 compilers..."
    command -v i686-w64-mingw32-gcc >/dev/null 2>&1 \
        && check_pass "i686-w64-mingw32-gcc found" \
        || check_fail "i686-w64-mingw32-gcc not found (run 'make install-deps')"
    command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 \
        && check_pass "x86_64-w64-mingw32-gcc found" \
        || check_fail "x86_64-w64-mingw32-gcc not found (run 'make install-deps')"
    echo

    echo "Checking native gcc..."
    command -v gcc >/dev/null 2>&1 \
        && check_pass "gcc found" || check_fail "gcc not found"
    echo

    echo "Checking python3..."
    command -v python3 >/dev/null 2>&1 \
        && check_pass "python3 found: $(python3 --version)" || check_fail "python3 not found"
    echo

    echo "Checking TUN/TAP kernel support..."
    modprobe tun 2>/dev/null \
        && check_pass "TUN/TAP module available" || check_fail "TUN/TAP module not available"
    [ -c /dev/net/tun ] \
        && check_pass "/dev/net/tun device exists" || check_fail "/dev/net/tun device not found"
    echo

    echo "Checking sudo access..."
    if sudo -n true 2>/dev/null; then
        check_pass "Sudo access available (no password required)"
    elif sudo -v 2>/dev/null; then
        check_pass "Sudo access available (password required)"
    else
        check_fail "Sudo access not available (required for TAP device)"
    fi
    echo

    echo "Checking build artifacts..."
    if [ -d "$build" ]; then
        check_pass "Build directory exists"
        local f
        for f in tap_bridge rvpnnetmp.sys adapter_hook.dll rvpn_launcher.exe netsh.exe netsh64.exe; do
            [ -f "$build/$f" ] && check_pass "$f built" || check_fail "$f missing"
        done
    else
        check_warn "Build directory not found (run 'make' to build)"
    fi
    echo

    echo "Checking wineprefix..."
    if [ -d "$prefix" ]; then
        check_pass "wineprefix exists"
        [ -f "$prefix/drive_c/Program Files (x86)/Radmin VPN/RvControlSvc.exe" ] \
            && check_pass "Radmin VPN installed" \
            || check_warn "Radmin VPN not installed in wineprefix"
    else
        check_warn "wineprefix not found (will be created on first run)"
    fi
    echo

    echo "Checking for running Radmin VPN processes..."
    pgrep -f "RvControlSvc.exe" >/dev/null 2>&1 \
        && check_warn "RvControlSvc.exe is running" || check_pass "No RvControlSvc.exe process found"
    pgrep -f "tap_bridge" >/dev/null 2>&1 \
        && check_warn "tap_bridge is running" || check_pass "No tap_bridge process found"
    echo

    echo "Checking TAP device..."
    if ip link show radminvpn0 >/dev/null 2>&1; then
        check_pass "radminvpn0 TAP device exists"
        ip link show radminvpn0
    else
        check_pass "No radminvpn0 TAP device found (normal when not running)"
    fi
    echo

    echo "Checking for Radmin VPN installer..."
    local installer
    installer=$(find . -maxdepth 2 -name "Radmin_VPN_*.exe" -print -quit 2>/dev/null || true)
    [ -n "$installer" ] \
        && check_pass "Installer found: $installer" \
        || check_warn "No installer found in current directory"
    echo

    echo "=== Health Check Complete ==="
}
