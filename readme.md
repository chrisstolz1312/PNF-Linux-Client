# Synthetic Payload VPN Service

Linux proof of concept for health-driven VPN selection and recovery using
NetworkManager and OpenVPN. The code intentionally keeps observation,
network-change detection, and recovery policy in separate scripts.

## Setup

Install: `sudo ./install.sh`  
Remove: `sudo ./uninstall.sh`

The systemd oneshot service runs `healthcheck_vpn.sh`, then
`network_change_watch.sh`, waits two seconds, and finally runs
`actor_vpn.sh`. See `vpn-watchdog.service` and its timer for scheduling.

## Responsibilities and state

| Component | Responsibility |
| --- | --- |
| `healthcheck_vpn.sh` | Measure login, screen, tunnel, HTTP health, and connectivity; publish `/run/vpn-health.state`. |
| `network_change_watch.sh` | Compare physical IPv4/IPv6 default routes and publish `/run/vpn-gateway-changed`. |
| `actor_vpn.sh` | Read current health plus NetworkManager state; select, start, stop, or restart UDP/TCP VPNs. |

The route watcher compares the **entire selected default-route string**,
including metric and interface. A metric-only difference is intentionally a
change. It ignores tunnel `tun*` routes and does not overwrite its saved
baseline if a default route is briefly absent. `/run/vpn-gateway-changed` is
named historically: it represents a **physical route change**, not solely a
change to the next-hop IP address. When the route changes the watcher removes
`/run/vpn-udp.lock` to permit a new UDP preflight decision.

### UDP choice and the one-hour policy lock

The actor prefers `prototype_udp` after a successful MTU preflight probe.
If the probe fails it uses `prototype_tcp` and records a one-hour UDP lock in
`/run/vpn-udp.lock`. The file contains a Unix expiration timestamp. An
observed network-route change clears this lock, even if only route metadata
changed. The lock is **not** the activation retry backoff described below.

### Failed activation: bounded retry cooldown

After `nmcli connection up`, the actor polls up to **five seconds** for an
active NetworkManager VPN profile, `tun1312`, and an IPv4 tunnel address.
When that readiness check fails, the actor attempts to clean up the partial
activation and records a failure for that profile:

| Consecutive failed activations | Minimum wait from last failure |
| --- | --- |
| 1 | 10 seconds |
| 2 | 20 seconds |
| 3 or more | 30 seconds (cap) |

This is a **linear, capped backoff**, not exponential. It is enforced by
checking timestamps during subsequent watchdog runs, without sleeping inside
the actor. A skipped activation does **not** count as another failure. A
successful activation resets the counter for that profile.

TCP and UDP have **independent** state files:

- `/run/vpn-start-backoff.tcp`
- `/run/vpn-start-backoff.udp`

Each file contains `<failed_attempt_count> <last_failure_unix_timestamp>`.
These files live across watchdog invocations but disappear at reboot.
Separating profiles prevents failure of one transport from suppressing the
other transport's recovery attempts. Before deliberately stopping an existing
connection for reactivation, the actor checks its target's cooldown so it
does not disconnect merely to perform a start it already knows is blocked.

## Operational examples

A TCP attempt that fails readiness checks produces messages similar to:

```text
WAIT   : prototype_tcp -> VPN READY (timeout 5s)
ERROR: Timeout waiting for prototype_tcp / tun1312
START FAILED  : prototype_tcp attempt=1
NEXT RETRY    : prototype_tcp after 10s
```

If the next watchdog run occurs before the cooldown expires:

```text
START BACKOFF : prototype_tcp attempt=1 remaining=7s
ACTION : SKIP START prototype_tcp (retry cooldown)
```

On a network with unstable router advertisements, a change from `metric
20600` to `metric 600` on the same IPv6 gateway triggers a new route-change
event by design. Consequently, even an otherwise healthy TCP VPN may be
reconsidered for UDP. This favors detecting potential underlay changes over
avoiding extra VPN evaluations.

## Reviewer notes and limitations

- The actor uses system state and file markers across separate executions;
  review ordering and marker consumption together with the systemd service.
- `vpn_ready()` proves initial tunnel readiness, not end-to-end health; the
  independent health monitor performs ongoing verification.
- MTU probing is a heuristic for UDP suitability, not a guarantee.
- The gateway-change flag is an on-disk event marker; concurrent executions
  and rapid repeated route changes warrant integration testing.
- This is a reference architecture / proof of concept, not audited
  production code. Changes to network or recovery policy should be tested
  on real NetworkManager/OpenVPN setups.

## Language and external command output

All messages emitted directly by the project scripts are written in English.
The health monitor still accepts localized Cinnamon screensaver query tokens
when interpreting externally supplied command output; these are not logged as
project status messages except in the unknown-state diagnostic, which may
include the raw external response. Output relayed verbatim from NetworkManager,
`ping`, `curl`, `systemd`, or other system tools may use the host's locale.
This change does not force the host's global locale to English.
