# PNF Linux Client

**A purpose-built OpenVPN client and watchdog for [Prototype Network Fabric (PNF)](https://github.com/chrisstolz1312/PNF).**

This project is the Linux desktop companion to PNF, **not** a general-purpose VPN manager. It uses NetworkManager, OpenVPN and a systemd timer to select a VPN transport, check that the PNF tunnel actually works, detect changes in the underlying network and recover from failures. The current implementation targets **KDE Plasma and Cinnamon**.

> **Status: alpha / proof of concept.** Designed for the matching PNF server setup; not security-audited or broadly tested across Linux distributions.

## What it does

- **UDP preferred, TCP fallback:** tests the network path before attempting UDP; switches to TCP when the probe, UDP activation or UDP tunnel health fails.
- **End-to-end PNF health check:** checks the VPN interface, its IPv6 configuration and a PNF gateway HTTP endpoint—not just whether an OpenVPN process exists.
- **Network-change detection:** observes the selected physical IPv4 and IPv6 default routes, including metric changes, and reassesses the VPN when they change.
- **Self-healing:** reconnects broken tunnels and applies a bounded retry cooldown to repeated TCP activation failures.
- **Desktop session policy:** deliberately disconnects the VPN when no user is logged in or the desktop is locked.
- **Systemd integration:** runs the checks and recovery logic automatically on a timer.

## Design philosophy: Connectivity first

**The goal is a working PNF tunnel as quickly as possible—not keeping UDP alive at any cost.** UDP is the preferred **performance transport**; TCP is the **immediate fallback** whenever UDP cannot meet the client's connectivity requirements.

The default behavior is deliberately decisive:

- **Try UDP only when its preflight passes.** The required packet-size/MTU probe is an early warning that the current path may not be suitable.
- **Do not retry an unsuitable UDP path repeatedly.** If the probe fails, UDP activation fails or an active UDP tunnel becomes unhealthy, switch straight to TCP instead of making the user wait through a series of UDP retries.
- **Keep a working TCP connection.** After UDP fails, a one-hour UDP lock prevents constant reattempts; a relevant change in the underlying network clears that lock so UDP can be reconsidered.
- **Recover TCP when necessary.** TCP is the availability-oriented fallback, not a guarantee against all network failures; repeated TCP start failures have their own bounded backoff.

**Default policy: prioritize connectivity over protocol preference.** This is intentional PNF-specific behavior. Anyone who wants different trade-offs can modify the open-source decision logic; the shipped defaults favor prompt recovery and a usable connection.

## How it works

Each watchdog cycle runs these components in order:

```text
vpn-watchdog.timer
  └─ vpn-watchdog.service
      ├─ healthcheck_vpn.sh       Observe session, tunnel and PNF health
      ├─ network_change_watch.sh  Detect physical route changes
      ├─ sleep 2
      └─ actor_vpn.sh             Select, reconnect or disconnect VPN
```

The timer starts **30 seconds after boot** and schedules subsequent runs with `OnUnitActiveSec=10s` and `AccuracySec=1s`. Actual intervals can vary with execution time and systemd scheduling.

### Health checks

The health monitor writes `/run/vpn-health.state`. It checks:

1. Whether a user is logged in and the desktop appears unlocked.
2. Whether `tun1312` exists and has a global IPv6 address.
3. Whether the tunnel has an IPv6 default gateway and an active `prototype_udp` or `prototype_tcp` NetworkManager profile.
4. Whether `http://[<VPN-IPv6-gateway>]:7000/`, accessed **through `tun1312`**, returns **HTTP 200** with the exact body **`I AM ALIVE`**.
5. System clock synchronization and NetworkManager connectivity status.

The monitor **reports state only**; it does not repair the VPN. The actor makes recovery decisions from that state and the active NetworkManager connection. Clock synchronization is advisory; the session, tunnel/HTTP checks and NetworkManager connectivity affect decisions.

### Transport selection and recovery

```text
No VPN active
  ├─ UDP MTU preflight succeeds → try UDP
  │    ├─ UDP becomes ready      → keep UDP
  │    └─ UDP activation fails   → lock UDP, immediately try TCP
  └─ UDP MTU preflight fails    → lock UDP, try TCP

UDP active
  ├─ Healthy   → keep UDP
  └─ Unhealthy → immediately fall back to TCP

TCP active
  ├─ Unhealthy        → attempt TCP recovery (subject to cooldown)
  ├─ UDP locked       → keep healthy TCP
  └─ UDP lock expired → stop TCP, test UDP, then select UDP or TCP
```

The UDP preflight reads `tun-mtu` from `/opt/vpn/ovpn/udp.ovpn`, adds 100 bytes and runs a **do-not-fragment ICMP ping** against `pnf.klojcnik.de`. This is a **heuristic**, not proof that UDP OpenVPN will work. The probe hostname is currently **hard-coded**.

A failed UDP probe or UDP activation sets `/run/vpn-udp.lock` for **one hour**. A change to the selected physical IPv4 or IPv6 default route clears that lock, even when only a route metric changes. A healthy TCP connection may be interrupted while trying UDP again.

**TCP start failures** use separate transient state in `/run/vpn-start-backoff.tcp`, with delays of **5, 10, 20 and then 30 seconds (capped)**. UDP does not use this TCP backoff mechanism. Initial tunnel readiness has a **5-second timeout for UDP** and a **15-second timeout for TCP**; an established tunnel's ongoing health is checked separately.

**Important:** An absent/unusable desktop session causes the actor to stop the VPN; NetworkManager connectivity other than `full` prevents new connection attempts. This is deliberate PNF desktop-client policy, not a general-purpose always-on VPN or kill switch.

## Requirements

- A working **PNF server installation** with compatible OpenVPN gateways and the expected IPv6 health endpoint on port `7000`.
- Linux desktop using **KDE Plasma or Cinnamon**, **systemd** and **NetworkManager**.
- **OpenVPN**, NetworkManager's **OpenVPN plugin**, `nmcli` and standard utilities used by the scripts (`bash`, `ip`, `ping`, `curl`, `awk`, `grep`, `sed`, `who`, `timedatectl`, etc.).
- A **valid PNF OpenVPN client profile** containing the required `proto`, `tun-mtu` and `mssfix` directives.
- A network on which the configured PNF probe host resolves and responds to the required ICMP test.

The interface name (`tun1312`), NetworkManager profile names (`prototype_udp`, `prototype_tcp`), probe hostname, endpoint and session behavior are **implementation-specific**, not configurable through a supported settings file in this version.

## Install

1. Clone this repository and enter its directory.
2. In `.ovpn/`, **replace the included `dummy.ovpn` placeholder** with **exactly one real PNF client `.ovpn` file** (for example, `.ovpn/client.ovpn`). Do not leave both files there: the profile builder refuses multiple source profiles.
3. Run:

   ```bash
   sudo bash ./install.sh
   ```

The installer:

1. Generates `/opt/vpn/ovpn/udp.ovpn` and `/opt/vpn/ovpn/tcp.ovpn` from the supplied profile, using PNF-specific interface, MTU, MSS and keepalive settings.
2. Imports them into NetworkManager as `prototype_udp` and `prototype_tcp` with automatic connection disabled (the watchdog controls activation).
3. Installs the runtime scripts in `/opt/vpn/`, installs `vpn-watchdog.service` and `vpn-watchdog.timer`, and enables/starts the timer.

**Warning:** Installation replaces NetworkManager connections with the names `prototype_udp` and `prototype_tcp` and also deletes connections named `udp` or `tcp`. Review the scripts before installing on a machine with existing VPN profiles.

**Never commit or upload a real `.ovpn` file containing private keys, client certificates or credentials.** The included `dummy.ovpn` is only a placeholder and is not a usable PNF profile.

## Check status and logs

```bash
systemctl status vpn-watchdog.timer
systemctl status vpn-watchdog.service
journalctl -u vpn-watchdog.service -n 100 --no-pager
cat /run/vpn-health.state
nmcli connection show --active
```

The included `dlw.sh` provides a live view of logs tagged by the three watchdog scripts, when such syslog tags are present.

Runtime decision markers (such as `/run/vpn-udp.lock` and `/run/vpn-gateway-changed`) are temporary and generally reset after reboot. UDP fallback diagnostics are additionally appended to `/var/log/vpn-udp-fallback.log`.

## Uninstall

```bash
sudo bash ./uninstall.sh
```

This stops the watchdog and PNF VPN connections, removes its NetworkManager profiles, installed scripts, systemd units and runtime state. It also removes old `vpn-health` and `vpn-network-watch` units if present. Review the uninstaller first if those names are used for anything else.

## Known limitations

- Tested behavior depends on the matching **PNF gateway health endpoint**, IPv6 tunnel routing and desktop-session detection.
- The MTU probe uses a fixed hostname and is sensitive to ICMP filtering; a failed probe can trigger TCP even where UDP would work.
- Retrying UDP from an otherwise healthy TCP connection temporarily disconnects TCP.
- Changes to route metrics alone can trigger VPN reassessment; frequent route changes may cause extra reconnects.
- This code is an early implementation. Test installation, screen locking, network changes and recovery on your own PNF setup before relying on it.

## License

**GNU Affero General Public License v3.0 (AGPL-3.0).** See `LICENSE` in this repository.
