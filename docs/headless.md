# Headless and server modes

Two extra launchers run Radmin without a local desktop, for a VPS or a datacenter host. They install and configure exactly like `run.sh` (same prefix, same `--installer` first run, same TAP bridge) and only differ in how you reach the GUI.

## `run_datacenter.sh`: the GUI in a browser

Runs the real Radmin GUI on a virtual display (Xvfb) and serves it through VNC and noVNC, so you configure your networks from a browser and leave it running.

```bash
sudo apt install -y xvfb x11vnc websockify novnc   # or: make install-datacenter-deps
./run_datacenter.sh --installer ~/Downloads/Radmin_VPN_*.exe
```

| Option | Default | What it does |
|---|---|---|
| `--vnc-port <n>` | `5900` | Port of the x11vnc server. |
| `--web-port <n>` | `6080` | Port of the noVNC web endpoint. |
| `--vnc-password <pw>` | none | Password for the VNC and web session. |
| `--web-bind <addr>` | `127.0.0.1` | Address noVNC listens on. |

noVNC binds to `127.0.0.1` by default, so you reach it through an SSH tunnel:

```bash
ssh -L 6080:localhost:6080 your-vps    # then open http://localhost:6080/vnc.html
```

To expose it publicly, pass `--web-bind 0.0.0.0` together with `--vnc-password`. Without a password, anyone who reaches the port lands on a root-capable desktop; the script warns loudly if you try. Set `NOVNC_PATH` if your noVNC web root is not in a standard location.

## `run_vps.sh`: service only

Starts the service with a hardcoded TAP GUID (no Wine WMI needed) and no GUI at all. If a network enumerator `rv_net_enum.exe` (not shipped here) sits one directory up, it is launched; otherwise the service runs until Ctrl+C. Only `--installer` is accepted.

```bash
./run_vps.sh --installer ~/Downloads/Radmin_VPN_*.exe
```

Neither launcher opens the host firewall the way `run.sh` does: on a server you manage that yourself.
