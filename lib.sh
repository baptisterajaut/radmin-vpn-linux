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

# Boot wineserver explicitly, with rvpn_reuseport.so preloaded.
#
# Radmin 2.1 binds its outbound peer sockets to the same local port as its NAT
# listener (SO_REUSEADDR, which Windows allows). Wine never translates that into a
# Unix SO_REUSEPORT for TCP, so the kernel refuses the second bind and the service
# sees WSAEACCES: every peer connect aborts and the GUI shows peers spinning
# forever (issue #24). See src/rvpn_reuseport.c for the full mechanism.
#
# The Unix sockets belong to wineserver, not to the service process, so the shim
# has to be preloaded HERE and not alongside rvpn_dnsfix.so in the service launch.
# There is exactly one wineserver per prefix, so this must run after the last
# `wineserver -k` and before the first `wine` command that would boot an
# unpreloaded one. -p keeps it alive across the gaps between wine invocations;
# every launcher's cleanup() kills it on exit.
boot_wineserver() {
    if [ -f "$BUILD_DIR/rvpn_reuseport.so" ]; then
        # Copy to /tmp: LD_PRELOAD cannot express a path containing spaces.
        cp -f "$BUILD_DIR/rvpn_reuseport.so" /tmp/rvpn_reuseport.so
        # Prepend, never overwrite: gamemode/mangohud users have their own.
        LD_PRELOAD="/tmp/rvpn_reuseport.so${LD_PRELOAD:+:$LD_PRELOAD}" wineserver -p
    else
        warn "rvpn_reuseport.so missing — Radmin 2.1 peer connections will fail (issue #24)"
        wineserver -p
    fi
}

# ── Radmin version pinning ──────────────────────────────────────────────────────
# The Radmin build this project is validated against. Everything derives from it:
# the download URL, the cached installer name, and the --update target. Bump this
# single constant after testing a new Radmin release end to end (service reaches
# "ready" AND a peer ping runs at 0% loss).
#
# Radmin's own in-app updater will otherwise push a newer build into a live
# prefix mid-session, which kills the GUI and crashes the running service.
# Shipping the current build is what keeps that updater with nothing to do.
RADMIN_DEFAULT_VERSION="2.1.4951.1"
RADMIN_VERSION="${RADMIN_VERSION:-$RADMIN_DEFAULT_VERSION}"
radmin_installer_name() { printf 'Radmin_VPN_%s.exe' "$RADMIN_VERSION"; }
radmin_installer_url() {
    printf 'https://download.radmin-vpn.com/download/files/Radmin_VPN_%s.exe' "$RADMIN_VERSION"
}

# ── Installer integrity ─────────────────────────────────────────────────────────
# sha256 of Radmin_VPN_2.1.4951.1.exe (54277224 bytes) as published on
# download.radmin-vpn.com. Confirmed to be the genuine vendor build: the file
# carries an Authenticode signature whose embedded SHA-256 digest matches the
# PE content, signed by "Famatech Corp." (C=VG) under DigiCert Trusted Root G4.
#
# Pinning the version without pinning the bytes leaves TLS as the only thing
# standing between the prefix and a substituted installer, so this constant and
# RADMIN_VERSION must be bumped as a pair.
RADMIN_SHA256_PINNED="e16711e2e3e59f6603f51f437197215b1914a3d8316e1f633260178b959921f7"

# Resolve which hash (if any) applies to the build we are about to run. Someone
# testing a different release supplies RADMIN_SHA256 alongside RADMIN_VERSION;
# without it there is nothing to check an unknown build against, and refusing to
# run would break the documented RADMIN_VERSION override.
if [ -n "${RADMIN_SHA256:-}" ]; then
    :
elif [ "$RADMIN_VERSION" = "$RADMIN_DEFAULT_VERSION" ]; then
    RADMIN_SHA256="$RADMIN_SHA256_PINNED"
else
    RADMIN_SHA256=""
fi

# sha256 of $1 on stdout. Tries the three tools that realistically exist on a
# host that can already build this project; returns non-zero when none do.
_sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$1" | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | sed 's/.*= *//'
    else
        return 1
    fi
}

# Check $1 before Wine executes it. Non-zero ONLY when the file claims to be the
# pinned build and its hash disagrees — every other case warns and passes, so an
# explicit --installer and a user-set RADMIN_VERSION keep working. The installer
# runs unsandboxed under Wine with sudo already primed, so this is the last point
# at which a substituted .exe can still be stopped cheaply.
verify_installer() {
    local f="$1" got name
    [ -f "$f" ] || return 0
    name="$(basename -- "$f")"
    if [ -z "$RADMIN_SHA256" ]; then
        warn "No pinned sha256 for Radmin $RADMIN_VERSION — installer NOT verified."
        warn "  Set RADMIN_SHA256 to check it, or unset RADMIN_VERSION for the validated build."
        return 0
    fi
    if [ "$name" != "$(radmin_installer_name)" ]; then
        warn "$name is not the validated $RADMIN_VERSION build — installer NOT verified."
        return 0
    fi
    if ! got="$(_sha256_of "$f")"; then
        warn "No sha256sum/shasum/openssl on PATH — installer NOT verified."
        return 0
    fi
    if [ "$got" != "$RADMIN_SHA256" ]; then
        warn "Installer sha256 MISMATCH — refusing to run it."
        warn "  file:     $f"
        warn "  expected: $RADMIN_SHA256"
        warn "  actual:   $got"
        return 1
    fi
    good "Installer sha256 verified ($RADMIN_VERSION)"
    return 0
}

# Version installed in $WINEPREFIX, read offline from the registry (no wine call).
# Empty when nothing is installed or the prefix predates the uninstall entry.
radmin_installed_version() {
    local reg="$WINEPREFIX/system.reg"
    [ -f "$reg" ] || return 0
    grep -a -A4 '"DisplayName"="Radmin VPN' "$reg" 2>/dev/null \
        | sed -n 's/^"DisplayVersion"="\([0-9.]*\)".*/\1/p' | head -n1
    return 0  # no match under pipefail must not kill a set -e caller (issue #22)
}

# ---- netsh relay ----
# netsh.exe (src/netsh_wrapper.c) cannot run Linux commands from inside Wine, so
# it appends them to a file in /tmp and this loop runs them with sudo. Any process
# of the user can write that file, Windows ones included (Z:\tmp), so nothing in
# it is trusted: only the exact lines netsh_wrapper.c emits are accepted, and they
# run as `ip` with separate arguments, never through a shell.
netsh_relay_line() {   # $1 = line, $2 = TAP device
    local l=$1 dev=$2
    local v4="^ip addr add (([0-9]{1,3}\.){3}[0-9]{1,3})/([0-9]{1,2}) dev $dev 2>/dev/null; ip link set $dev up 2>/dev/null$"
    local v6="^ip -6 addr add ([0-9a-fA-F:]+)/128 dev $dev 2>/dev/null$"
    if [[ $l =~ $v4 ]]; then
        sudo ip addr add "${BASH_REMATCH[1]}/${BASH_REMATCH[3]}" dev "$dev" 2>/dev/null || true
        sudo ip link set "$dev" up 2>/dev/null || true
    elif [[ $l =~ $v6 ]]; then
        sudo ip -6 addr add "${BASH_REMATCH[1]}/128" dev "$dev" 2>/dev/null || true
    elif [ "$l" = "ip link set $dev up" ]; then
        sudo ip link set "$dev" up 2>/dev/null || true
    elif [ "$l" = "ip addr flush dev $dev" ]; then
        sudo ip addr flush dev "$dev" 2>/dev/null || true
    else
        echo "[!] netsh relay: rejected $(printf '%q' "${l:0:160}")" >&2
    fi
    return 0
}

netsh_relay() {   # $1 = command file, $2 = TAP device, $3 = poll interval (s)
    local f=$1 dev=$2 cmd
    rm -f "$f" "$f.proc"
    while true; do
        # -O: a file another user planted in /tmp is never read.
        if [ -f "$f" ] && [ -O "$f" ] && mv "$f" "$f.proc" 2>/dev/null; then
            while IFS= read -r cmd || [ -n "$cmd" ]; do
                cmd=${cmd%$'\r'}   # Wine writes \r\n
                [ -z "$cmd" ] || netsh_relay_line "$cmd" "$dev"
            done < "$f.proc"
            rm -f "$f.proc"
        fi
        sleep "$3"
    done
}

# ---- Host firewall (issues #34, #35) ----
# On Linux, Radmin's "Another app is blocking the connection" banner is the host
# firewall dropping inbound traffic on the TAP: peers can ping out but nobody can
# join a server you host. We accept inbound on the TAP for the session only:
# runtime state, every rule tagged with FW_TAG, removed by firewall_close.
FW_TAG="radmin-vpn-linux"
FW_STATE=/tmp/rvpn_fw_firewalld   # firewalld zone change made by us

# "family table chain" for every nft filter base chain on the input hook.
_nft_input_chains() {
    sudo nft list chains 2>/dev/null | awk '
        $1 == "table" { fam = $2; tbl = $3 }
        $1 == "chain" { ch = $2 }
        /type filter hook input/ && fam ~ /^(ip|ip6|inet)$/ { print fam, tbl, ch }'
}

# Prints what it opened (empty when there was nothing to open).
firewall_open() {
    local dev=$1 fam tbl ch done=""
    firewall_close "$dev"   # leftovers from a run killed before its cleanup
    # firewalld owns the nft ruleset when it runs: go through its API, not nft.
    if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
        [ "$(sudo firewall-cmd --get-zone-of-interface="$dev" 2>/dev/null)" = "trusted" ] && return 0
        sudo firewall-cmd --zone=trusted --change-interface="$dev" >/dev/null 2>&1 \
            && echo "$dev" > "$FW_STATE" && echo "firewalld zone trusted"
        return 0
    fi
    # nft also sees ufw and iptables-nft rules (table ip filter). An accept only
    # ends its own base chain, so every input chain gets one.
    if command -v nft >/dev/null 2>&1; then
        while read -r fam tbl ch; do
            sudo nft insert rule "$fam" "$tbl" "$ch" iifname "$dev" accept comment "\"$FW_TAG\"" \
                >/dev/null 2>&1 && done="$done $fam/$tbl/$ch"
        done < <(_nft_input_chains)
    fi
    # iptables-legacy rules are invisible to nft.
    if command -v iptables >/dev/null 2>&1 && { ! command -v nft >/dev/null 2>&1 \
            || iptables --version 2>/dev/null | grep -q legacy; }; then
        sudo iptables  -I INPUT -i "$dev" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null && done="$done iptables"
        sudo ip6tables -I INPUT -i "$dev" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null || true
    fi
    [ -z "$done" ] || echo "${done# }"
}

firewall_close() {
    local dev=$1 fam tbl ch h
    if [ -f "$FW_STATE" ]; then
        sudo firewall-cmd --zone=trusted --remove-interface="$(cat "$FW_STATE")" >/dev/null 2>&1 || true
        rm -f "$FW_STATE"
    fi
    if command -v nft >/dev/null 2>&1; then
        while read -r fam tbl ch; do
            for h in $(sudo nft -a list chain "$fam" "$tbl" "$ch" 2>/dev/null \
                    | sed -n "s/.*comment \"$FW_TAG\" # handle \([0-9]\+\).*/\1/p"); do
                sudo nft delete rule "$fam" "$tbl" "$ch" handle "$h" >/dev/null 2>&1 || true
            done
        done < <(_nft_input_chains)
    fi
    if command -v iptables >/dev/null 2>&1; then
        while sudo iptables  -D INPUT -i "$dev" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null; do :; done
        while sudo ip6tables -D INPUT -i "$dev" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null; do :; done
    fi
    return 0
}

# True when $1 is strictly newer than $2 (dotted numeric versions).
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# ── Component installation ──────────────────────────────────────────────────────
# Copy our build artifacts into the prefix. Shared by run.sh, run_vps.sh and
# run_datacenter.sh, which all set $BUILD_DIR, $WINEPREFIX and $RADMIN first.
# cp -f matters: a read-only $BUILD_DIR (Nix store, 0444) makes the copies
# read-only too, and a plain cp then fails on the second run.
install_components() {
    say "Installing components..."
    chmod +x "$BUILD_DIR/tap_bridge" 2>/dev/null || true
    cp -f "$BUILD_DIR/rvpnnetmp.sys" "$WINEPREFIX/drive_c/windows/system32/drivers/"
    cp -f "$BUILD_DIR/adapter_hook.dll" "$RADMIN/"
    cp -f "$BUILD_DIR/rvpn_launcher.exe" "$RADMIN/"
    cp -f "$BUILD_DIR/netsh.exe" "$WINEPREFIX/drive_c/windows/syswow64/netsh.exe"
    cp -f "$BUILD_DIR/netsh64.exe" "$WINEPREFIX/drive_c/windows/system32/netsh.exe"
    # Replace Radmin's real NDIS driver installer with a no-op stub.
    # RvControlSvc runs drvinst.exe at runtime to load NetMP60_1_1_64.sys, which
    # aborts Wine 11.x via NdisInitializeReadWriteLock (issue #12). Our rvpnnetmp.sys
    # replaces that adapter, so the real NDIS driver must never load.
    cp -f "$BUILD_DIR/drvinst.exe" "$RADMIN/drvinst.exe"
}

# ── Wine desktop-integration hygiene ────────────────────────────────────────────
# winemenubuilder.exe rewrites the HOST's desktop file associations (.exe, .msi,
# .lnk, .reg, .chm, ...) so they open in whatever prefix spawned it. Left enabled,
# our prefix hijacks the user's entire Wine desktop integration: their other
# Windows apps then launch inside the Radmin prefix. Disable it for every wine
# invocation — this is exported at source time, before the first one.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}mscoree=;mshtml=;winemenubuilder.exe=d"

# Purge desktop entries a previous run's winemenubuilder wrote for a Radmin
# prefix. Conservative on purpose: an entry is removed only when its Exec line
# pins a WINEPREFIX that is either the prefix we are about to use, or a path that
# looks like a Radmin prefix (source checkout, AppImage data dir, older layouts).
# Entries belonging to the user's own prefixes are left alone.
purge_hijacked_desktop_entries() {
    local apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    [ -d "$apps" ] || return 0

    # Two Exec spellings in the wild, depending on the Wine version that wrote
    # the entry: env "WINEPREFIX=/path" (recent) and env WINEPREFIX="/path"
    # (older). The optional quote after '=' matches both.
    local list purged=0 f
    list=$( { grep -rlsE 'WINEPREFIX="?[^"]*[Rr]admin' "$apps" --include='*.desktop' 2>/dev/null || true
              [ -n "${WINEPREFIX:-}" ] && grep -rlsF -e "WINEPREFIX=$WINEPREFIX" \
                  -e "WINEPREFIX=\"$WINEPREFIX" "$apps" --include='*.desktop' 2>/dev/null
              true; } | sort -u )
    [ -n "$list" ] || return 0

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f "$f" && purged=$((purged + 1))
    done <<< "$list"

    # winemenubuilder leaves empty Start Menu folders behind.
    [ -d "$apps/wine" ] && find "$apps/wine" -type d -empty -delete 2>/dev/null
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$apps" 2>/dev/null
    # CBA: the matching x-wine-extension-*.xml mime packages and .xpm icons are
    # prefix-agnostic and shared with the user's other prefixes — left in place.

    good "Purged $purged hijacked Wine desktop entries (file associations restored)"
    return 0
}

# Radmin's real NDIS miniport (service RvNetMP60) aborts Wine 11.x inside
# DriverEntry via ndis.sys!NdisInitializeReadWriteLock (issue #12), so it must
# never stay registered in the prefix: Wine loads driver services at wineserver
# boot, which makes EVERY app in that prefix crash, not just ours.
#
# Removing it with `wine reg delete` is a trap — that command boots the prefix,
# which loads the very driver we are trying to remove, and the abort can take the
# delete down with it, leaving the prefix poisoned forever. Edit system.reg
# offline instead, with the wineserver down.
scrub_ndis_driver() {
    local reg="$WINEPREFIX/system.reg"
    rm -f "$WINEPREFIX/drive_c/windows/system32/drivers/RvNetMP60.sys" \
          "$WINEPREFIX/drive_c/windows/system32/drivers/NetMP60_1_1_64.sys"
    [ -f "$reg" ] || return 0
    grep -qa 'Services\\\\RvNetMP60' "$reg" || return 0

    wineserver -k 2>/dev/null || true
    if awk '/^\[/ { drop = ($0 ~ /Services\\\\RvNetMP60(\\\\|\])/) } !drop' "$reg" > "$reg.rvpn"; then
        mv "$reg.rvpn" "$reg"
        good "Removed poisoned RvNetMP60 driver service from the prefix (issue #12)"
    else
        rm -f "$reg.rvpn"
        warn "Could not scrub RvNetMP60 from $reg — Wine crashes are expected"
    fi
    return 0
}

# ── Diagnostic result helpers (dump_diagnostics style) ──────────────────────────
DIAG_FAILS=0
diag_ok()   { echo "  [ok]   $1"; }
diag_miss() { echo "  [MISS] $1"; DIAG_FAILS=$((DIAG_FAILS+1)); }
diag_bad()  { echo "  [BAD]  $1"; DIAG_FAILS=$((DIAG_FAILS+1)); }
# Something worth reporting that is NOT necessarily a fault — must not inflate
# the failure count, or the summary sends triage after the wrong thing.
diag_warn() { echo "  [warn] $1"; }

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
    # `|| true` is load-bearing, not defensive noise: dump_diagnostics runs under
    # the caller's `set -euo pipefail`, and grep exits 1 when the key is absent —
    # pipefail propagates it and the failed assignment kills the whole dump right
    # here, silently truncating the block reporters paste into issues. `timeout`
    # for the same reason: this runs after a crash, wineserver may be wedged.
    local rvpn_start
    rvpn_start=$(timeout 10 wine reg query "HKLM\\SYSTEM\\CurrentControlSet\\Services\\rvpnnetmp" /v Start 2>/dev/null \
        | grep -oE '0x[0-9a-f]+' | head -n1) || true
    [ -n "$rvpn_start" ] \
        && diag_ok "registry rvpnnetmp (Start=$rvpn_start)" \
        || diag_miss "registry rvpnnetmp not found"
    # Start != 4 means Wine's SCM can auto-spawn an unhooked second instance (#16).
    local svc_start
    svc_start=$(timeout 10 wine reg query "HKLM\\SYSTEM\\CurrentControlSet\\Services\\RvControlSvc" /v Start 2>/dev/null \
        | grep -oE '0x[0-9a-f]+' | head -n1) || true
    # Numeric compare: Wine prints 0x4 today, but a 0x00000004 would fall through
    # to the catch-all and cry duplicate-service at someone whose setup is fine.
    if [ -z "$svc_start" ]; then
        diag_miss "registry RvControlSvc Start not found"
    elif [ "$((svc_start))" -eq 4 ] 2>/dev/null; then
        diag_ok "registry RvControlSvc (Start=$svc_start, SCM auto-start off)"
    else
        diag_bad "registry RvControlSvc Start=$svc_start — SCM will spawn an unhooked duplicate"
    fi
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

    # ── Transparent proxy / policy routing (issue #19) ──────────────────────────
    # `ip route show` only reads table main. A transparent proxy (sing-box, clash/
    # mihomo, v2ray, tun2socks…) puts its routes in a dedicated table reached by an
    # `ip rule` whose priority beats main's 32766 — sing-box defaults to table 2022
    # at priority 9000 — so none of it appears in `ip route show default` and the
    # host looks perfectly normal. `ip route get` runs a real FIB lookup *through*
    # the rules, so it reports the device the traffic actually leaves by.
    # Worth its own section because `ss` cannot tell you: sing-box's default
    # `system` TCP stack completes the handshake locally, in the kernel, before it
    # even dials upstream — the service's socket shows ESTABLISHED while not one
    # byte is relayed. Registered-but-never-ready with a healthy-looking ESTAB.
    echo "--- Transparent proxy / policy routing ---"
    local srv_ip route_srv route_peer egress_dev alt_rules proxies
    # timeout: resolving inside a diagnostics dump, on a bug class that is often a
    # DNS stall in the first place, is asking for the dump itself to hang.
    srv_ip=$(timeout 5 getent ahostsv4 proxy.radminte.com 2>/dev/null | awk 'NR==1{print $1}') || true
    [ -n "$srv_ip" ] || srv_ip="148.113.190.78"   # fail.radminte.com, last known
    # `uid` makes the lookup honour uid-range rules; older iproute2 rejects it.
    route_srv=$(ip route get "$srv_ip" uid "$(id -u)" 2>/dev/null | head -n1) || true
    [ -n "$route_srv" ] || route_srv=$(ip route get "$srv_ip" 2>/dev/null | head -n1) || true
    route_peer=$(ip route get 26.0.0.1 uid "$(id -u)" 2>/dev/null | head -n1) || true
    [ -n "$route_peer" ] || route_peer=$(ip route get 26.0.0.1 2>/dev/null | head -n1) || true
    echo "  [info] to Famatech ($srv_ip): ${route_srv:-<unknown>}"
    echo "  [info] to VPN peers (26.0.0.1): ${route_peer:-<unknown>}"

    egress_dev=$(printf '%s\n' "$route_srv" \
        | sed -n 's/.*[[:space:]]dev[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p') || true
    alt_rules=$(ip rule show 2>/dev/null | grep -vE '^0:|lookup (local|main|default)') || true
    # -x on the executable NAME, never -f on the cmdline: a full-cmdline match
    # hits any shell, editor or browser that merely mentions one of these words.
    proxies=$(pgrep -a -x 'sing-box|mihomo|clash|clash-meta|v2ray|xray|hysteria|tun2socks|nekobox' \
        2>/dev/null | head -n 5) || true

    if [ -n "$alt_rules" ]; then
        diag_warn "policy-routing rules beyond the standard three:"
        printf '%s\n' "$alt_rules" | sed 's/^/           /'
    fi
    if [ -n "$proxies" ]; then
        diag_warn "proxy core running:"
        printf '%s\n' "$proxies" | sed 's/^/           /'
    fi
    # The verdict is the routing fact, not the presence of a proxy: a tun whose
    # exclusions are already correct sends Famatech out the default interface and
    # must not be blamed. Egress != default-route device = actually intercepted.
    local main_dev
    main_dev=$(ip route show default 2>/dev/null \
        | sed -n 's/.*[[:space:]]dev[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' | head -n1) || true
    if [ -n "$egress_dev" ] && [ -n "$main_dev" ] && [ "$egress_dev" != "$main_dev" ]; then
        diag_bad "traffic to Famatech leaves via '$egress_dev', not the default-route interface '$main_dev'."
        echo "         Something is redirecting it — a transparent proxy or a tunnel with its"
        echo "         own routing policy. Radmin's control channel rarely survives one: such"
        echo "         stacks answer the TCP handshake locally, so the socket reads ESTABLISHED"
        echo "         while nothing is relayed, and the service registers but never gets ready."
        echo "         In its routing config, exclude at least 26.0.0.0/8 (VPN peer traffic is"
        echo "         local to $tap and has no business in a tunnel), and *.radminte.com too if"
        echo "         you can reach it directly. Disabling it is the quickest way to confirm."
    fi
    # Canary, useful even with no proxy in sight: our 26.0.0.0/8 route lives in
    # table main, so any policy rule at a priority below 32766 silently wins.
    # Only meaningful once run.sh has actually installed that route — it does so
    # *after* the ready gate, so on a "never became ready" dump it is legitimately
    # absent and judging it there would fail every single bug report.
    local peer_route_set
    peer_route_set=$(ip route show 26.0.0.0/8 dev "$tap" 2>/dev/null) || true
    if [ -n "$peer_route_set" ]; then
        case "$route_peer" in
            ""|*" dev $tap"|*" dev $tap "*) : ;;
            *) diag_bad "VPN peer traffic (26.0.0.0/8) does not leave via $tap — another routing policy wins" ;;
        esac
    fi
    echo ""

    # ── Radmin 2.1 shims (issue #24) ────────────────────────────────────────────
    # Both 2.1 fixes are invisible in every other section: the service reaches
    # ONLINE, joins its networks and lists its peers whether or not they are in
    # place. What breaks is only the peer sessions, and the code Radmin reports for
    # that (0x700000000) is the generic give-up at the end of its error cascade —
    # it carries no information at all. So this section checks the shims directly.
    echo "--- Radmin 2.1 peer-session shims ---"
    local ws_pids ws_pid reuse_seen perf_seen hooklog svclog peer_fail
    hooklog="$WINEPREFIX/drive_c/radmin_hook_debug.log"
    svclog="${LOG:-$WINEPREFIX/drive_c/ProgramData/Famatech/Radmin VPN/service.log}"

    # rvpn_reuseport.so has to be mapped into *wineserver*, not into the service:
    # the Unix sockets belong to wineserver. The trap this catches is a wineserver
    # that was already running when the launcher started (a stray one from another
    # Wine app, or a `wine` command that beat boot_wineserver to it) — nothing else
    # looks wrong, and every peer connect fails with WSAEACCES.
    ws_pids=$(pgrep -x wineserver 2>/dev/null) || true
    if [ -z "$ws_pids" ]; then
        echo "  [info] wineserver not running — cannot check rvpn_reuseport.so"
    else
        reuse_seen=""
        for ws_pid in $ws_pids; do
            if grep -q 'rvpn_reuseport' "/proc/$ws_pid/maps" 2>/dev/null; then
                reuse_seen=1
            fi
        done
        if [ -n "$reuse_seen" ]; then
            echo "  [ok]   rvpn_reuseport.so mapped into wineserver"
        else
            diag_bad "rvpn_reuseport.so is NOT loaded in wineserver — every peer connect will fail (WSAEACCES)"
            echo "         2.1 binds its outbound peer sockets to the same local port as its NAT"
            echo "         listener; without the shim the kernel refuses that second bind. Usual"
            echo "         cause: a wineserver was already up before the launcher booted its own."
            echo "         Fix: quit other Wine apps, then \`wineserver -k\` and re-run."
        fi
    fi

    # The hook logs one line per name it fills in. Absent is not automatically a
    # fault — a Wine that exports the four functions natively needs no stub — so
    # this is reported as info and only turns into a verdict below, combined with
    # an actual peer failure.
    perf_seen=""
    if [ -f "$hooklog" ] && grep -q 'perflib counterset' "$hooklog" 2>/dev/null; then
        perf_seen=1
        echo "  [ok]   perflib stubs handed out by adapter_hook.dll"
    else
        echo "  [info] no perflib stub lines in the hook log (fine if Wine exports them itself)"
    fi

    peer_fail=""
    if [ -f "$svclog" ]; then
        peer_fail=$(iconv -f UTF-16LE -t UTF-8 "$svclog" 2>/dev/null | grep -c '0x700000000') || true
        [ -n "$peer_fail" ] || peer_fail=0
        if [ "$peer_fail" -gt 0 ] 2>/dev/null; then
            diag_bad "$peer_fail peer connection(s) failed with error 0x700000000"
            echo "         That code is contentless — don't read a subsystem out of it. It means the"
            echo "         peer handshake was abandoned before being sent. If the two checks above"
            if [ -z "$perf_seen" ]; then
                echo "         are green this is new; here the perflib stubs never fired, which is the"
                echo "         known cause on a Wine that exports neither the four Perf* functions nor"
                echo "         a replacement — check that build/adapter_hook.dll is from 1.1.0 or later."
            else
                echo "         are green this is a new failure mode, not the known 1.1.0 one — please"
                echo "         report it with this whole block."
            fi
        fi
    fi
    echo ""

    echo "--- Firewall ---"
    local fw
    fw=$(command -v nft iptables firewall-cmd 2>/dev/null | sed 's/^/  /') || true
    if [ -n "$fw" ]; then
        echo "$fw"
    else
        echo "  (no nft/iptables/firewalld found)"
    fi
    local svc
    for svc in firewalld ufw nftables iptables; do
        systemctl is-active --quiet "$svc" 2>/dev/null && echo "  active service: $svc" || true
    done
    if command -v nft >/dev/null 2>&1; then
        echo "  --- nft ruleset (first 40 lines, best-effort; may need root) ---"
        nft list ruleset 2>/dev/null | head -n 40 | sed 's/^/  /' || true
    fi
    echo ""

    dump_log "launcher stdout/stderr" /tmp/radmin_service.log
    # The driver writes to \??\unix\tmp\radmin_driver.log (src/rvpnnetmp.c), i.e.
    # /tmp — never inside the prefix. Pointing at the prefix made this section say
    # "(file not found)" on every single report (#16, yuxiaole-bili).
    dump_log "driver log"             /tmp/radmin_driver.log
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
    installer=$(find . "${RADMIN_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/radmin-vpn-linux}" \
                     -maxdepth 2 -name "Radmin_VPN_*.exe" -print -quit 2>/dev/null || true)
    [ -n "$installer" ] \
        && check_pass "Installer found: $installer" \
        || check_pass "No installer cached — $(radmin_installer_name) will be downloaded on first run"
    echo

    echo "=== Health Check Complete ==="
}
