#!/usr/bin/env bash
# run-in-netns.sh — Run Radmin VPN inside an isolated network namespace.
#
# Contributed by ayozetr (https://github.com/ayozetr), who diagnosed the whole
# host-network-conflict class in issue #16. Provided as-is in contrib/: it is not
# part of the normal launch path and run.sh never calls it.
#
# Most of what motivated it is fixed natively now (interface filtering, and
# rvpn_dnsfix.so for the black-holed private PTR lookups). Keep this for the cases
# the shim cannot reach — a Wine built as old-wow64 ignores a 64-bit LD_PRELOAD,
# and some host stacks simply resist every in-process fix.
#
# Workaround for hosts where Radmin hangs on "waiting for adapter" / never reaches
# ready, caused by a conflict with the host's network stack (multiple VPNs / bridges /
# sysctls / netfilter). In a clean network namespace Radmin connects and works
# normally, same kernel and bundled Wine.
#
# ---------------------------------------------------------------------------
# READ THIS FIRST — the VPN stays inside the namespace.
#
# The TAP device (radminvpn0) and the 26.0.0.0/8 route are created *inside* the
# namespace, because that is where run.sh runs. Radmin will reach "ready", the
# GUI will show your networks, chat and peer discovery work — but no process on
# the host can talk to 26.0.0.0/8. Your game, launched normally, sees nothing.
#
# This is a diagnostic tool and a fallback for hosts where nothing else works,
# not a gaming setup. To actually use the VPN, the application has to join the
# namespace too:
#
#     sudo ip netns exec radminvpn runuser -u "$USER" -- <your app>
#
# which means carrying DISPLAY/XAUTHORITY/XDG_RUNTIME_DIR/PulseAudio into it as
# well — workable for a dedicated server binary, painful for a Steam game.
# ---------------------------------------------------------------------------
#
# Usage:   sudo bash run-in-netns.sh [/path/to/RadminVPN-Linux-*.AppImage]
# Close the Radmin window to exit; the namespace + NAT rules are torn down automatically.
set -u

NS=radminvpn
VETH_H=rvpn-h ; VETH_N=rvpn-n
SUBNET=10.201.0 ; HOST_IP=$SUBNET.1 ; NS_IP=$SUBNET.2
USER_NAME="${SUDO_USER:-$(id -un)}"
UID_N="$(id -u "$USER_NAME")"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
# Look where an AppImage plausibly landed, in the invoking user's home — any
# locale's download directory, and the XDG one if it is configured.
APP="${1:-}"
if [ -z "$APP" ]; then
    XDG_DL="$(runuser -u "$USER_NAME" -- xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    for d in "$XDG_DL" "$HOME_DIR/Downloads" "$HOME_DIR/Descargas" \
             "$HOME_DIR/Téléchargements" "$HOME_DIR/Загрузки" "$HOME_DIR"; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        APP="$(find "$d" -maxdepth 1 -name 'RadminVPN-Linux-*.AppImage' \
               -print 2>/dev/null | sort -V | tail -n1)"
        [ -n "$APP" ] && break
    done
fi

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
command -v iptables >/dev/null || { echo "iptables required (NAT out of the netns)."; exit 1; }
if [ -z "$APP" ] || [ ! -f "$APP" ]; then
    echo "AppImage not found. Pass it explicitly:"
    echo "  sudo bash $0 /path/to/RadminVPN-Linux-x86_64.AppImage"
    exit 1
fi
echo "[*] using $APP"

cleanup() {
    echo; echo "[*] tearing down netns..."
    ip netns pids "$NS" 2>/dev/null | xargs -r kill 2>/dev/null
    ip netns del "$NS" 2>/dev/null
    ip link del "$VETH_H" 2>/dev/null
    iptables -t nat -D POSTROUTING -s "$SUBNET.0/24" -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -s "$SUBNET.0/24" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -d "$SUBNET.0/24" -j ACCEPT 2>/dev/null
    rm -rf "/etc/netns/$NS"
    echo "[+] done."
}
trap cleanup EXIT INT TERM

# Radmin is single-instance (shared FIFOs in /tmp); kill any stray instance first.
pkill -f "RvControlSvc|rvpn_launcher|tap_bridge" 2>/dev/null && sleep 1

echo "[*] setting up isolated netns '$NS'..."
ip netns del "$NS" 2>/dev/null ; ip link del "$VETH_H" 2>/dev/null ; sleep 0.3
ip netns add "$NS"
ip link add "$VETH_H" type veth peer name "$VETH_N"
ip link set "$VETH_N" netns "$NS"
ip addr add "$HOST_IP/24" dev "$VETH_H" ; ip link set "$VETH_H" up
ip netns exec "$NS" ip addr add "$NS_IP/24" dev "$VETH_N"
ip netns exec "$NS" ip link set "$VETH_N" up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip route add default via "$HOST_IP"
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s "$SUBNET.0/24" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$SUBNET.0/24" -j MASQUERADE
iptables -I FORWARD 1 -s "$SUBNET.0/24" -j ACCEPT   # win over ufw's default-deny FORWARD
iptables -I FORWARD 1 -d "$SUBNET.0/24" -j ACCEPT
# Inherit the host's resolvers rather than imposing one: a hardcoded public
# resolver is exactly what fails for users behind national filtering, and Radmin's
# servers are the thing they need to resolve. Loopback entries (systemd-resolved's
# 127.0.0.53) are dropped — that stub does not exist inside the namespace.
mkdir -p "/etc/netns/$NS"
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null \
  | grep -vE '^nameserver[[:space:]]+(127\.|::1)' > "/etc/netns/$NS/resolv.conf" || true
[ -s "/etc/netns/$NS/resolv.conf" ] || echo "nameserver 1.1.1.1" > "/etc/netns/$NS/resolv.conf"

ip netns exec "$NS" ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 \
  && echo "[+] netns has internet" || echo "[!] warning: no internet inside netns"

# On X11, DISPLAY alone is not enough: display managers keep the cookie in
# XDG_RUNTIME_DIR, not ~/.Xauthority, and sudo strips XAUTHORITY on distros that
# do not env_keep it. Without it neither the GUI nor the AppImage's sudo askpass
# dialog can open, and the script just hangs with no visible prompt.
XAUTH="${XAUTHORITY:-}"
if [ ! -r "$XAUTH" ]; then
    XAUTH="$(find "/run/user/$UID_N" -maxdepth 1 -name 'xauth_*' 2>/dev/null | head -n1)"
    [ -n "$XAUTH" ] && [ -r "$XAUTH" ] || XAUTH="$HOME_DIR/.Xauthority"
fi

echo "[*] launching Radmin VPN (close its window to exit)..."
ip netns exec "$NS" runuser -u "$USER_NAME" -- \
  env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
      XAUTHORITY="$XAUTH" XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-x11}" \
      XDG_RUNTIME_DIR="/run/user/$UID_N" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
  "$APP"
# on exit, the EXIT trap cleans up
