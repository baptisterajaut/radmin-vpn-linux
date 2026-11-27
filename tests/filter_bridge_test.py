#!/usr/bin/env python3
"""tap_bridge packet-filter test. No Wine, Radmin, sudo or iptables needed.

tap_bridge enforces the IP, MAC and UDP:4445 filters on its own. This test plays
the Wine driver over the FIFOs and a host UDP socket on the TAP, so it shows the
filters work end to end without any firewall rule.

Run it in a throwaway user + network namespace (nothing touches the real host):

    unshare -Urn python3 -I tests/filter_bridge_test.py build/tap_bridge

It uses the fixed /tmp/rvpn_* FIFO paths, so stop any running Radmin session first.
"""
import json
import os
import queue
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

TAP = "radminvpn0"
HOST_IP = "26.0.0.1"
PEER_IP = "26.0.0.2"
OTHER_IP = "26.0.0.3"
PEER_MAC = "02:00:00:aa:bb:01"
OTHER_MAC = "02:00:00:aa:bb:03"
B2D, D2B_HIGH = "/tmp/rvpn_b2d", "/tmp/rvpn_d2b_high"
LEGACY_FILE = "/tmp/rvpn_filters.json"
SETTLE = 2.5   # tap_bridge reloads the filter file about once a second


def sh(*cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def mac_bytes(m):
    return bytes(int(x, 16) for x in m.split(":"))


def ip_checksum(hdr):
    s = sum(struct.unpack("!10H", hdr))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF


def udp_frame(dst_mac, src_mac, src_ip, dst_ip, sport, dport, payload=b"x"):
    udp = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 1, 0, 64, 17, 0,
                     socket.inet_aton(src_ip), socket.inet_aton(dst_ip))
    ip = ip[:10] + struct.pack("!H", ip_checksum(ip)) + ip[12:]
    return mac_bytes(dst_mac) + mac_bytes(src_mac) + b"\x08\x00" + ip + udp


class Bridge:
    def __init__(self, binary, env_file):
        env = dict(os.environ)
        env.pop("RVPN_FILTER_FILE", None)
        if env_file:
            env["RVPN_FILTER_FILE"] = env_file
        self.log = tempfile.NamedTemporaryFile("w+", suffix=".log")
        self.proc = subprocess.Popen([binary], env=env, stderr=self.log,
                                     stdout=subprocess.DEVNULL)
        for _ in range(100):
            if os.path.exists(D2B_HIGH) and os.path.exists(B2D):
                break
            time.sleep(0.05)
        else:
            self.stop()
            raise RuntimeError("tap_bridge did not create its FIFOs:\n" + self.logtext())
        self.d2b = os.open(D2B_HIGH, os.O_WRONLY)
        self.b2d = os.open(B2D, os.O_RDONLY)   # unblocks the bridge's open()
        self.frames = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        buf = b""
        while True:
            try:
                chunk = os.read(self.b2d, 65536)
            except OSError:
                return
            if not chunk:
                time.sleep(0.02)
                continue
            buf += chunk
            while len(buf) >= 2:
                n = struct.unpack("<H", buf[:2])[0]
                if len(buf) < 2 + n:
                    break
                self.frames.put(buf[2:2 + n])
                buf = buf[2 + n:]

    def logtext(self):
        self.log.flush()
        self.log.seek(0)
        return self.log.read()

    def inject(self, frame):
        os.write(self.d2b, struct.pack("<H", len(frame)) + frame)

    def saw_udp(self, dport, timeout):
        """True if a UDP frame to dport shows up on the TAP->Wine FIFO."""
        end = time.time() + timeout
        while time.time() < end:
            try:
                f = self.frames.get(timeout=0.1)
            except queue.Empty:
                continue
            if len(f) >= 42 and f[12:14] == b"\x08\x00" and f[23] == 17 \
                    and struct.unpack("!H", f[36:38])[0] == dport:
                return True
        return False

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(3)
        except subprocess.TimeoutExpired:
            self.proc.kill()


class Host:
    """UDP endpoints on the host side of the TAP."""

    def __init__(self):
        self.rx = {}
        for port in (9999, 4445):
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.bind((HOST_IP, port))
            self.rx[port] = s
        self.tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.tx.bind((HOST_IP, 0))

    def got(self, port, timeout=1.0):
        r, _, _ = select.select([self.rx[port]], [], [], timeout)
        if r:
            self.rx[port].recv(2048)
            return True
        return False

    def send(self, dst_ip, port):
        self.tx.sendto(b"y", (dst_ip, port))


results = []


def check(name, ok):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    binary = os.path.abspath(sys.argv[1])
    if os.getuid() != 0:
        sys.exit("run inside: unshare -Urn python3 -I tests/filter_bridge_test.py <tap_bridge>")
    sh("ip", "tuntap", "add", "dev", TAP, "mode", "tap")
    sh("ip", "addr", "add", HOST_IP + "/8", "dev", TAP)
    sh("ip", "link", "set", TAP, "up")
    for ip, mac in ((PEER_IP, PEER_MAC), (OTHER_IP, OTHER_MAC)):
        sh("ip", "neigh", "add", ip, "lladdr", mac, "dev", TAP, "nud", "permanent")
    # /sys still shows the parent namespace's interfaces, so ask ip.
    link = subprocess.run(["ip", "-o", "link", "show", TAP], check=True,
                          capture_output=True, text=True).stdout.split()
    tap_mac = link[link.index("link/ether") + 1]

    tmpdir = tempfile.mkdtemp(prefix="rvpn-test.")
    os.chmod(tmpdir, 0o700)
    state = os.path.join(tmpdir, "filters.json")
    tick = [int(time.time())]

    def write_filters(same_second=False, **cfg):
        base = {"block_ips_enabled": False, "blocked_ips": [],
                "block_macs_enabled": False, "blocked_macs": [],
                "block_broadcast_enabled": False, "broadcast_block_ips": []}
        base.update(cfg)
        with open(state + ".new", "w") as f:
            json.dump(base, f)
        os.replace(state + ".new", state)
        if not same_second:
            tick[0] += 10                   # mtime has 1 s granularity: force a reload
        os.utime(state, (tick[0], tick[0]))
        time.sleep(SETTLE)

    host = Host()
    write_filters()
    bridge = Bridge(binary, state)
    time.sleep(1.5)

    def to_host(port, src_ip=PEER_IP, src_mac=PEER_MAC):
        bridge.inject(udp_frame(tap_mac, src_mac, src_ip, HOST_IP, 5000, port))
        return host.got(port)

    def to_wine(port, dst_ip=PEER_IP):
        while not bridge.frames.empty():
            bridge.frames.get_nowait()
        host.send(dst_ip, port)
        return bridge.saw_udp(port, 1.0)

    try:
        # The harness itself: with no filter, traffic flows both ways.
        check("no filter: Wine->TAP passes", to_host(9999))
        check("no filter: TAP->Wine passes", to_wine(9999))

        write_filters(block_ips_enabled=True, blocked_ips=[PEER_IP])
        check("IP block: Wine->TAP from blocked peer dropped", not to_host(9999))
        check("IP block: TAP->Wine to blocked peer dropped", not to_wine(9999))
        check("IP block: other peer still passes (Wine->TAP)",
              to_host(9999, OTHER_IP, OTHER_MAC))
        check("IP block: other peer still passes (TAP->Wine)", to_wine(9999, OTHER_IP))

        write_filters(block_ips_enabled=False, blocked_ips=[PEER_IP])
        check("IP block switched off: traffic resumes", to_host(9999) and to_wine(9999))

        write_filters(block_macs_enabled=True, blocked_macs=[PEER_MAC])
        check("MAC block: Wine->TAP from blocked MAC dropped", not to_host(9999))
        check("MAC block: TAP->Wine to blocked MAC dropped", not to_wine(9999))
        check("MAC block: other MAC still passes", to_host(9999, OTHER_IP, OTHER_MAC))

        write_filters(block_broadcast_enabled=True, broadcast_block_ips=[PEER_IP])
        check("UDP:4445 block: Wine->TAP dropped", not to_host(4445))
        check("UDP:4445 block: TAP->Wine dropped", not to_wine(4445))
        check("UDP:4445 block: other ports from the same peer still pass",
              to_host(9999) and to_wine(9999))

        write_filters()
        check("entries removed: UDP:4445 resumes", to_host(4445) and to_wine(4445))

        # Two writes in the same second (the UI replaces the file each time, so it
        # is a new inode with a mtime the bridge has already seen) must both load.
        write_filters(block_ips_enabled=True, blocked_ips=[PEER_IP])
        check("same-second rewrite: block applied", not to_host(9999))
        write_filters(same_second=True)
        check("same-second rewrite: unblock is picked up", to_host(9999) and to_wine(9999))

        # A symlink where the state file should be must be ignored.
        real = os.path.join(tmpdir, "real.json")
        with open(real, "w") as f:
            json.dump({"block_ips_enabled": True, "blocked_ips": [PEER_IP]}, f)
        os.unlink(state)
        os.symlink(real, state)
        tick[0] += 10
        os.utime(real, (tick[0], tick[0]))
        time.sleep(SETTLE)
        check("state file that is a symlink is ignored", to_host(9999) and to_wine(9999))
    finally:
        bridge.stop()

    # Nobody can plant rules at the old fixed path, and with no
    # RVPN_FILTER_FILE the bridge does not filter at all.
    with open(LEGACY_FILE, "w") as f:
        json.dump({"block_ips_enabled": True, "blocked_ips": [PEER_IP]}, f)
    try:
        bridge = Bridge(binary, None)
        try:
            time.sleep(1.5 + SETTLE)
            check("legacy /tmp/rvpn_filters.json is no longer read",
                  to_host(9999) and to_wine(9999))
        finally:
            bridge.stop()
    finally:
        os.unlink(LEGACY_FILE)

    print(f"\n{sum(results)}/{len(results)} passed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
