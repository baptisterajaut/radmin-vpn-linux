#!/bin/bash
# health_check.sh - Diagnostic script for Radmin VPN Linux
# This script checks system prerequisites and common issues

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_pass() {
    echo -e "${GREEN}[✓]${NC} $1"
}

check_fail() {
    echo -e "${RED}[✗]${NC} $1"
}

check_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

echo "=== Radmin VPN Linux Health Check ==="
echo

# Check Wine
echo "Checking Wine installation..."
if command -v wine >/dev/null 2>&1; then
    WINE_VERSION=$(wine --version)
    check_pass "Wine installed: $WINE_VERSION"
    # Extract version number for comparison
    WINE_MAJOR=$(echo "$WINE_VERSION" | grep -oP 'wine-\K\d+' || echo "0")
    if [ "$WINE_MAJOR" -ge 11 ]; then
        check_pass "Wine version >= 11.0"
    else
        check_fail "Wine version < 11.0 (required: >= 11.0)"
    fi
else
    check_fail "Wine not found"
fi
echo

# Check wineserver
echo "Checking wineserver..."
if command -v wineserver >/dev/null 2>&1; then
    check_pass "wineserver found"
else
    check_fail "wineserver not found"
fi
echo

# Check mingw-w64 compilers
echo "Checking mingw-w64 compilers..."
if command -v i686-w64-mingw32-gcc >/dev/null 2>&1; then
    check_pass "i686-w64-mingw32-gcc found"
else
    check_fail "i686-w64-mingw32-gcc not found (run 'make install-deps')"
fi

if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    check_pass "x86_64-w64-mingw32-gcc found"
else
    check_fail "x86_64-w64-mingw32-gcc not found (run 'make install-deps')"
fi
echo

# Check gcc for native builds
echo "Checking native gcc..."
if command -v gcc >/dev/null 2>&1; then
    check_pass "gcc found"
else
    check_fail "gcc not found"
fi
echo

# Check python3
echo "Checking python3..."
if command -v python3 >/dev/null 2>&1; then
    PYTHON_VERSION=$(python3 --version)
    check_pass "python3 found: $PYTHON_VERSION"
else
    check_fail "python3 not found"
fi
echo

# Check TUN/TAP support
echo "Checking TUN/TAP kernel support..."
if modprobe tun 2>/dev/null; then
    check_pass "TUN/TAP module available"
else
    check_fail "TUN/TAP module not available"
fi

if [ -c /dev/net/tun ]; then
    check_pass "/dev/net/tun device exists"
else
    check_fail "/dev/net/tun device not found"
fi
echo

# Check sudo access
echo "Checking sudo access..."
if sudo -n true 2>/dev/null; then
    check_pass "Sudo access available (no password required)"
elif sudo -v 2>/dev/null; then
    check_pass "Sudo access available (password required)"
else
    check_fail "Sudo access not available (required for TAP device)"
fi
echo

# Check build artifacts
echo "Checking build artifacts..."
BUILD_DIR="./build"
if [ -d "$BUILD_DIR" ]; then
    check_pass "Build directory exists"
    
    [ -f "$BUILD_DIR/tap_bridge" ] && check_pass "tap_bridge built" || check_fail "tap_bridge missing"
    [ -f "$BUILD_DIR/rvpnnetmp.sys" ] && check_pass "rvpnnetmp.sys built" || check_fail "rvpnnetmp.sys missing"
    [ -f "$BUILD_DIR/adapter_hook.dll" ] && check_pass "adapter_hook.dll built" || check_fail "adapter_hook.dll missing"
    [ -f "$BUILD_DIR/rvpn_launcher.exe" ] && check_pass "rvpn_launcher.exe built" || check_fail "rvpn_launcher.exe missing"
    [ -f "$BUILD_DIR/netsh.exe" ] && check_pass "netsh.exe built" || check_fail "netsh.exe missing"
    [ -f "$BUILD_DIR/netsh64.exe" ] && check_pass "netsh64.exe built" || check_fail "netsh64.exe missing"
else
    check_warn "Build directory not found (run 'make' to build)"
fi
echo

# Check wineprefix
echo "Checking wineprefix..."
WINEPREFIX="./wineprefix"
if [ -d "$WINEPREFIX" ]; then
    check_pass "wineprefix exists"
    
    if [ -f "$WINEPREFIX/drive_c/Program Files (x86)/Radmin VPN/RvControlSvc.exe" ]; then
        check_pass "Radmin VPN installed"
    else
        check_warn "Radmin VPN not installed in wineprefix"
    fi
else
    check_warn "wineprefix not found (will be created on first run)"
fi
echo

# Check for running processes
echo "Checking for running Radmin VPN processes..."
if pgrep -f "RvControlSvc.exe" >/dev/null 2>&1; then
    check_warn "RvControlSvc.exe is running"
else
    check_pass "No RvControlSvc.exe process found"
fi

if pgrep -f "tap_bridge" >/dev/null 2>&1; then
    check_warn "tap_bridge is running"
else
    check_pass "No tap_bridge process found"
fi
echo

# Check TAP device
echo "Checking TAP device..."
if ip link show radminvpn0 >/dev/null 2>&1; then
    check_pass "radminvpn0 TAP device exists"
    ip link show radminvpn0
else
    check_pass "No radminvpn0 TAP device found (normal when not running)"
fi
echo

# Check for installer
echo "Checking for Radmin VPN installer..."
INSTALLER=$(find . -maxdepth 2 -name "Radmin_VPN_*.exe" -print -quit 2>/dev/null || true)
if [ -n "$INSTALLER" ]; then
    check_pass "Installer found: $INSTALLER"
else
    check_warn "No installer found in current directory"
fi
echo

echo "=== Health Check Complete ==="
