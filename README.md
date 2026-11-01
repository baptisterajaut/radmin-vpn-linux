# Radmin VPN for Linux

Run [Radmin VPN](https://www.radmin-vpn.com/) on Linux through Wine: join networks, see peers, host and join game servers, no Windows VM.

> I did not build this because it was easier than a VM. I built it because I thought it was easier than a VM.

Written by a human and Claude (Anthropic), with a lot of AI-assisted reverse engineering in Ghidra. It works, with no guarantees. Not affiliated with Famatech; Radmin VPN itself is downloaded from Famatech's servers, never shipped here.

## Audit it yourself instead of claiming it's a RAT

It asks for your sudo password and runs a closed-source Windows binary, so be suspicious. Then check, it takes less time than writing the accusation.

- Everything is in this repo: shell scripts and C. The release files are built by GitHub Actions from the tagged commit ([`build.yml`](.github/workflows/build.yml)), and the build logs are public. GitHub records the sha256 of each release file: `gh api repos/baptisterajaut/radmin-vpn-linux/releases/latest --jq '.assets[] | .name + " " + .digest'`.
- `./RadminVPN-Linux-x86_64.AppImage --appimage-extract` unpacks the AppImage into `squashfs-root/`: the launch scripts in `usr/bin/`, our binaries in `usr/lib/radmin-vpn/`, and a stock Wine build ([Kron4ek](https://github.com/Kron4ek/Wine-Builds)) in `wine/`. Or skip all that and [build it yourself](docs/building.md).
- What runs as root: `ip` (the `radminvpn0` adapter, its addresses and routes), `sysctl` (two settings on that adapter only), `modprobe tun`, `nmcli` (tells NetworkManager to leave the adapter alone) and `firewall-cmd`, `nft` or `iptables` (the firewall rule, removed on exit). Grep the scripts for `sudo` to check the list. Radmin's own request to configure its address goes through a relay that only accepts the exact `ip` commands it expects, never a shell.
- What gets downloaded: the Radmin installer, from `download.radmin-vpn.com`, checked against a sha256 pinned in [`lib.sh`](lib.sh). Nothing else, unless `winetricks` is installed, which then fetches a few DirectX libraries for the GUI.
- What Radmin itself sends is Famatech's business, not ours. For the record, reverse engineering shows that Radmin 2.1 puts "this is Wine" and your kernel version in the client information it sends.

## Install

Download `RadminVPN-Linux-x86_64.AppImage` from the [latest release](https://github.com/baptisterajaut/radmin-vpn-linux/releases/latest). Wine is bundled, nothing else to install.

```bash
chmod +x RadminVPN-Linux-x86_64.AppImage
./RadminVPN-Linux-x86_64.AppImage
```

The first launch opens a terminal, downloads the Radmin installer this project is tested against, installs it and asks for your sudo password (needed for the network adapter). It takes a few minutes. Later launches only ask for the password and open the Radmin window. Closing that window stops the VPN.

If something goes wrong, a terminal opens on the log. You can also start the AppImage from a terminal to always see what it does. Everything it keeps (Wine prefix, adapter MAC, `run.log`) is in `~/.local/share/radmin-vpn-linux/`.

Other ways to run it: [from source](docs/building.md), [on NixOS](NIX.md), [on a headless server](docs/headless.md). How it works inside: [docs/architecture.md](docs/architecture.md).

## Options

| Option | What it does |
|---|---|
| `--update` | Upgrade Radmin to the version this release is tested against. Keeps your prefix and your Radmin ID. |
| `--installer <path>` | Use this `Radmin_VPN_*.exe` instead of downloading one (first install only). |
| `--no-ui` | Run the VPN without the Radmin window. |
| `--no-firewall` | Leave your firewall alone. By default incoming traffic on the VPN adapter is allowed while Radmin runs. |
| `--no-fix-chat` | Don't patch the Qt library that crashes Radmin when a chat message arrives. |
| `--no-broadcast-routes` | Don't send broadcast and multicast traffic through the VPN (see LAN games below). |
| `--filter-ui` | Open a small packet-filter window next to Radmin. |

## Troubleshooting

When you open an issue, attach `~/.local/share/radmin-vpn-linux/run.log`. It contains a diagnostics block whenever the start goes wrong.

**"Another app is blocking the connection. Check if you have a VPN or security program running."** On Linux that "security program" is your firewall (firewalld, ufw, nftables), and the symptom is that you can reach your friends but they can't join anything you host. Since 1.1.1 the launcher allows incoming traffic on the VPN adapter for the session. If the banner stays, it is another VPN or tunnel (Tailscale, WireGuard, a work VPN, a proxy like sing-box or clash): stop it, or exclude `26.0.0.0/8` from it.

**Radmin closes by itself.** Two known causes. Someone sent you a chat message: fixed by default since 1.1.1, update. Or Radmin's own updater installed a newer version inside the running prefix: run the AppImage with `--update` once, then turn off "Automatic updates" in Radmin's settings.

**Radmin stays offline after an update or a restart.** Look for `Service was powered off before shutdown` in the log: Radmin remembers that you switched it off. Click the power button in the Radmin window.

**Registered, but never "ready".** The log shows `Registered as #…` and then the start times out. Usual causes: a proxy or tunnel that intercepts outgoing connections (same fix as above), or a DNS resolver that never answers reverse lookups of private addresses (a `docker0` interface is the usual trigger). For the second one, [`contrib/run-in-netns.sh`](contrib/run-in-netns.sh) works around it; read its header first, it keeps the VPN inside a network namespace.

**LAN games don't see each other.** Games find each other with broadcast and multicast, so the launcher routes `255.255.255.255` and `224.0.0.0/4` through the VPN while it runs. The side effect: Chromecast, printers or smart TVs on your home network may not be discovered during that time. `--no-broadcast-routes` turns it off.

**Your other Wine apps broke after running Radmin** (`unimplemented function ndis.sys.NdisInitializeReadWriteLock`). Versions up to 1.0.0 let Wine take over Windows file associations, so other `.exe` files started in the Radmin prefix. Run any version from 1.0.1 on once and it repairs both. To clean it by hand:

```bash
grep -rl 'WINEPREFIX=[^"]*radmin' ~/.local/share/applications --include='*.desktop' | xargs -r rm
rm -rf ~/.local/share/applications/wine/Programs/"Radmin VPN"
update-desktop-database ~/.local/share/applications
```

## Credits

Reverse engineering and the Wine shim: [@baptisterajaut](https://github.com/baptisterajaut).

- [@ayozetr](https://github.com/ayozetr) tracked the "registers but never ready" hang down to a reverse-DNS lookup black-holed by the host resolver, after four wrong theories (mine included), and wrote the original `src/rvpn_dnsfix.c` and `contrib/run-in-netns.sh`.
- [@gringoestrangeiro](https://github.com/gringoestrangeiro): packet filters, ARP cache, crash recovery, headless and datacenter modes, the chat crash fix.
- [@yuxiaole-bili](https://github.com/yuxiaole-bili) found that Wine's service manager starts a second, unhooked copy of the service that fights the real one for the adapter.
- [@Makaroshka1973](https://github.com/Makaroshka1973): NixOS support.
- [@D1spell-tech](https://github.com/D1spell-tech), [@Milkiway13](https://github.com/Milkiway13) and everyone who pasted a full diagnostics block. Two independent machines is what makes a bug findable.

## License

GPL-3.0, see [LICENSE](LICENSE). In spirit this is public domain; the GPL is there because it explicitly protects reverse engineering for interoperability, which is what this project does.

Radmin VPN is proprietary software by Famatech Corp. This project ships interoperability tools only, no Famatech code.
