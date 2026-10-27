#!/usr/bin/env bash

set -u

###############################################################################
# VPN actor: policy and recovery controller
#
# The actor runs once per watchdog cycle; it is not a long-running daemon.
# The systemd unit executes the health monitor, route watcher, then actor.
# Each component has a separate responsibility:
#
#   healthcheck_vpn.sh        -> reports observed session/VPN health
#   network_change_watch.sh  -> publishes physical default-route changes
#   actor_vpn.sh             -> chooses and activates the VPN profile
#
# NetworkManager is the source of truth for active connection profiles.
# The health state file is the source of truth for tunnel health. Neither
# alone is sufficient: a profile can be active before its tunnel is ready.
#
# Policy overview:
#   * With an unusable login/screen or no full connectivity, do not start VPN.
#   * Prefer UDP if the preflight MTU probe succeeds.
#   * A failed UDP probe OR activation immediately selects TCP and locks UDP
#     for one hour; UDP activation is never retried in the same cycle.
#   * TCP activation failures retry with 5s, 10s, 20s, then 30s cooldown.
#   * Any observed physical default-route change invalidates the UDP lock,
#     even if the difference is only a route metric. This is intentional:
#     the route watcher favors false positives over missed network changes.
#   * Limit repeated failed activation attempts to avoid tight retry loops.
#
# Files in /run are transient, local machine state and disappear on reboot.
# Keep policy changes synchronized with README.md and the systemd unit.
###############################################################################

STATE_FILE="/run/vpn-health.state"
GW_CHANGE_FILE="/run/vpn-gateway-changed"
RESTART_PENDING_FILE="/run/vpn-restart-pending"

UDP_PROFILE="prototype_udp"
TCP_PROFILE="prototype_tcp"

UDP_OVPN="/opt/vpn/ovpn/udp.ovpn"

UDP_LOCK_FILE="/run/vpn-udp.lock"
UDP_LOCK_SECONDS=3600

TUN_DEV="tun1312"

# Only TCP uses activation cooldown; the watchdog must run frequently enough
# to honor it (ideally every 5 seconds). /run state resets on reboot.
START_BACKOFF_PREFIX="/run/vpn-start-backoff"
TCP_BACKOFF_MAX=30
UDP_READY_TIMEOUT=5
TCP_READY_TIMEOUT=15
UDP_FAILURE_LOG="/var/log/vpn-udp-fallback.log"

###############################################################################
# Basic requirements
###############################################################################

if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: State file not found: $STATE_FILE"
    exit 1
fi

if ! command -v nmcli >/dev/null 2>&1; then
    echo "ERROR: nmcli not found."
    exit 1
fi

if ! command -v ping >/dev/null 2>&1; then
    echo "ERROR: ping not found."
    exit 1
fi

. "$STATE_FILE"

###############################################################################
# Output
###############################################################################

echo "========== VPN ACTOR =========="
echo "STATUS          : ${STATUS:-UNKNOWN}"
echo "LOGIN           : ${LOGIN:-UNKNOWN}"
echo "SCREEN          : ${SCREEN:-UNKNOWN}"
echo "VPN_INTERFACE   : ${VPN_INTERFACE:-UNKNOWN}"
echo "VPN_TYPE        : ${VPN_TYPE:-UNKNOWN}"
echo "HEALTHCHECK     : ${HEALTHCHECK:-UNKNOWN}"
echo "CONNECTIVITY    : ${CONNECTIVITY:-UNKNOWN}"
echo

###############################################################################
# NetworkManager helpers
###############################################################################

vpn_is_active()
{
    local profile="$1"

    nmcli -t -f NAME connection show --active \
        | grep -Fxq "$profile"
}

get_active_vpn()
{
    if vpn_is_active "$UDP_PROFILE"; then
        echo "UDP"
        return 0
    fi

    if vpn_is_active "$TCP_PROFILE"; then
        echo "TCP"
        return 0
    fi

    echo "NONE"
}

stop_vpn()
{
    local profile="$1"
    local timeout=15

    echo "ACTION : STOP $profile"

    if vpn_is_active "$profile"; then
        if ! nmcli connection down "$profile"; then
            echo "ERROR: Failed to stop $profile"
            return 1
        fi
    fi

    # Even if NetworkManager already considers the profile down,
    # make sure tun1312 is really gone before continuing.
    while ip link show "$TUN_DEV" >/dev/null 2>&1; do
        if [ "$timeout" -le 0 ]; then
            echo "ERROR: $TUN_DEV did not disappear after stopping $profile"
            return 1
        fi

        sleep 1
        timeout=$((timeout - 1))
    done

    return 0
}

vpn_ready()
{
    local profile="$1"

    # NetworkManager must report the requested VPN profile as active.
    if ! nmcli -t -f NAME,TYPE connection show --active \
        | grep -Fqx "$profile:vpn"; then
        return 1
    fi

    # The OpenVPN process must have created the expected tunnel device.
    if ! ip link show "$TUN_DEV" >/dev/null 2>&1; then
        return 1
    fi

    # The tunnel must have an IPv4 address before we call it ready.
    if ! ip -4 addr show dev "$TUN_DEV" | grep -q "inet "; then
        return 1
    fi

    return 0
}

wait_for_vpn()
{
    local profile="$1"
    local nmcli_pid="$2"
    local timeout_seconds="${3:-20}"
    local elapsed=0
    local nmcli_done=0

    echo "WAIT   : $profile -> VPN READY (timeout ${timeout_seconds}s)"

    while [ "$elapsed" -lt "$timeout_seconds" ]; do
        if vpn_ready "$profile"; then
            echo "VPN READY : $profile ($TUN_DEV)"
            return 0
        fi

        # If nmcli already exited with an error, do not wait the full
        # readiness timeout. A successful nmcli exit is not enough by
        # itself to declare the VPN ready, so keep polling in that case.
        if [ "$nmcli_done" -eq 0 ] && ! kill -0 "$nmcli_pid" 2>/dev/null; then
            if wait "$nmcli_pid" 2>/dev/null; then
                nmcli_done=1
            else
                echo "ERROR: nmcli activation failed for $profile"
                return 1
            fi
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "ERROR: Timeout waiting for $profile / $TUN_DEV"
    return 1
}

###############################################################################
# TCP activation backoff: 5s, 10s, 20s, 30s, 30s...
# UDP failures go straight to TCP (with an hour-long UDP policy lock).
# Return: start_vpn 0=ready, 1=failed, 2=TCP cooldown.
###############################################################################

tcp_backoff_delay()
{
    case "$1" in
        0) echo 0 ;;
        1) echo 5 ;;
        2) echo 10 ;;
        3) echo 20 ;;
        *) echo "$TCP_BACKOFF_MAX" ;;
    esac
}

start_backoff_file()
{
    [ "$1" = "$TCP_PROFILE" ] || return 1
    printf '%s.tcp\n' "$START_BACKOFF_PREFIX"
}

read_start_backoff()
{
    local profile="$1" file
    file=$(start_backoff_file "$profile") || return 1
    BACKOFF_ATTEMPT=0
    BACKOFF_LAST_FAILURE=0
    [ -f "$file" ] || return 0

    read -r BACKOFF_ATTEMPT BACKOFF_LAST_FAILURE < "$file" || true
    if ! [[ "$BACKOFF_ATTEMPT" =~ ^[0-9]+$ && "$BACKOFF_LAST_FAILURE" =~ ^[0-9]+$ ]]; then
        echo "WARNING: Invalid start backoff state for $profile; resetting"
        BACKOFF_ATTEMPT=0
        BACKOFF_LAST_FAILURE=0
        rm -f "$file"
    fi
}

check_start_backoff()
{
    local profile="$1" now delay remaining
    read_start_backoff "$profile" || return 1
    now=$(date +%s)
    delay=$(tcp_backoff_delay "$BACKOFF_ATTEMPT")
    remaining=$((BACKOFF_LAST_FAILURE + delay - now))
    if (( remaining > 0 )); then
        echo "START BACKOFF : $profile attempt=$BACKOFF_ATTEMPT remaining=${remaining}s"
        return 1
    fi
    return 0
}

register_start_failure()
{
    local profile="$1" file tmp delay now
    file=$(start_backoff_file "$profile") || return 1
    read_start_backoff "$profile" || return 1
    BACKOFF_ATTEMPT=$((BACKOFF_ATTEMPT + 1))
    now=$(date +%s)
    delay=$(tcp_backoff_delay "$BACKOFF_ATTEMPT")
    tmp="${file}.$$"
    printf '%s %s\n' "$BACKOFF_ATTEMPT" "$now" > "$tmp"
    mv -f "$tmp" "$file"
    echo "START FAILED  : $profile attempt=$BACKOFF_ATTEMPT"
    echo "NEXT RETRY    : $profile after ${delay}s"
}

reset_start_backoff()
{
    local file
    file=$(start_backoff_file "$1") || return 1
    rm -f "$file"
}

start_vpn()
{
    local profile="$1"
    local wait_timeout="$TCP_READY_TIMEOUT"
    local nmcli_pid activation_log
    [ "$profile" = "$UDP_PROFILE" ] && wait_timeout="$UDP_READY_TIMEOUT"

    # Check BEFORE requesting activation. The cooldown is a scheduling
    # decision, not evidence that this watchdog cycle attempted a start.
    if [ "$profile" = "$TCP_PROFILE" ] && ! check_start_backoff "$profile"; then
        echo "ACTION : SKIP START $profile (retry cooldown)"
        return 2
    fi

    echo "ACTION : START $profile"

    # Do not use a short synchronous nmcli timeout here.
    # NetworkManager/OpenVPN activation is asynchronous: nmcli only
    # requests the activation, while OpenVPN may need several seconds
    # to create the tunnel and obtain its IP configuration.
    activation_log=$(mktemp /run/vpn-activation.XXXXXX) || return 1
    nmcli connection up "$profile" >"$activation_log" 2>&1 &
    nmcli_pid=$!

    # Wait for the actual system state, not merely for nmcli to return.
    if wait_for_vpn "$profile" "$nmcli_pid" "$wait_timeout"; then
        # NetworkManager owns the active connection. The short-lived nmcli
        # client may be stopped; this does not mean taking the VPN down.
        if kill -0 "$nmcli_pid" 2>/dev/null; then
            kill "$nmcli_pid" 2>/dev/null || true
        fi
        wait "$nmcli_pid" 2>/dev/null || true
        rm -f "$activation_log"
        if [ "$profile" = "$TCP_PROFILE" ]; then
            reset_start_backoff "$profile"
        fi
        return 0
    fi

    # Activation did not reach a usable VPN state. Reap the helper first.
    if kill -0 "$nmcli_pid" 2>/dev/null; then
        kill "$nmcli_pid" 2>/dev/null || true
    fi
    wait "$nmcli_pid" 2>/dev/null || true

    echo "ERROR: Failed to start $profile"
    if [ "$profile" = "$UDP_PROFILE" ]; then
        UDP_LAST_ERROR=$(tr '\n' ' ' < "$activation_log" | cut -c1-500)
        echo "UDP FAILURE : $UDP_LAST_ERROR"
    fi
    rm -f "$activation_log"

    # An activation can leave an incomplete profile/tunnel behind. Clean
    # that up before recording failure so the next attempt starts clean.
    nmcli connection down "$profile" >/dev/null 2>&1 || true

    # Give NetworkManager/OpenVPN a short opportunity to remove the tunnel.
    local cleanup_timeout=5
    while ip link show "$TUN_DEV" >/dev/null 2>&1; do
        if [ "$cleanup_timeout" -le 0 ]; then
            echo "ERROR: $TUN_DEV still exists after failed $profile start"
            if [ "$profile" = "$TCP_PROFILE" ]; then
                register_start_failure "$profile"
            fi
            return 1
        fi
        sleep 1
        cleanup_timeout=$((cleanup_timeout - 1))
    done

    if [ "$profile" = "$TCP_PROFILE" ]; then
        register_start_failure "$profile"
    fi
    return 1
}

# Permanent diagnostic log, including successful ping / failed UDP handshake.
# Logging errors must never prevent the TCP fallback.
log_udp_failure()
{
    local reason="$1" timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    if ! printf '%s UDP_FALLBACK reason=%s profile=%s timeout=%ss detail=%s\n' \
        "$timestamp" "$reason" "$UDP_PROFILE" "$UDP_READY_TIMEOUT" "${UDP_LAST_ERROR:-none}" >> "$UDP_FAILURE_LOG"; then
        echo "WARNING: Cannot write UDP fallback log: $UDP_FAILURE_LOG" >&2
    fi
    echo "UDP FALLBACK : $reason (logged to $UDP_FAILURE_LOG)"
}

fallback_to_tcp()
{
    local reason="$1"
    log_udp_failure "$reason"
    UDP_LAST_ERROR=""
    set_udp_lock
    # Stop even partially established/failed UDP, but do not block TCP
    # when the stale tunnel is already gone.
    if vpn_is_active "$UDP_PROFILE" || ip link show "$TUN_DEV" >/dev/null 2>&1; then
        if ! stop_vpn "$UDP_PROFILE"; then
            echo "ERROR: Could not clear UDP before TCP fallback"
            return 1
        fi
    fi
    echo "ACTION : IMMEDIATE TCP FALLBACK"
    start_vpn "$TCP_PROFILE"
}

start_udp_or_fallback()
{
    if start_vpn "$UDP_PROFILE"; then
        return 0
    fi
    fallback_to_tcp "UDP_ACTIVATION_FAILED_OR_TIMEOUT"
}

restart_vpn()
{
    local profile="$1"

    echo "ACTION : RESTART $profile"

    # Guard the stop operation: never tear down a currently active profile
    # just to immediately discover that its replacement is on cooldown.
    if [ "$profile" = "$TCP_PROFILE" ] && ! check_start_backoff "$profile"; then
        echo "ACTION : KEEP $profile (activation cooldown)"
        return 0
    fi

    # A gateway change is the reason for this restart.
    # Reduce an existing UDP lock by five seconds before restarting.
    adjust_udp_lock -5

    if ! stop_vpn "$profile"; then
        return 1
    fi

    if [ "$profile" = "$UDP_PROFILE" ]; then
        start_udp_or_fallback || return $?
    else
        start_vpn "$profile" || return $?
    fi

    # Do not extend the lock yet. The next health check must first
    # prove that the restarted VPN is actually healthy.
    touch "$RESTART_PENDING_FILE"

    return 0
}

###############################################################################
# UDP lock
#
# The file stores an absolute Unix expiry timestamp. This is a policy lock,
# NOT an activation failure cooldown. The policy lock suppresses the UDP MTU
# experiment after a failed probe; route changes deliberately clear it.
###############################################################################

udp_lock_active()
{
    [ -f "$UDP_LOCK_FILE" ] || return 1

    local expires
    local now

    expires=$(cat "$UDP_LOCK_FILE" 2>/dev/null || true)
    now=$(date +%s)

    # Invalid lock -> remove it.
    if ! [[ "$expires" =~ ^[0-9]+$ ]]; then
        echo "WARNING: Invalid UDP lock file."
        rm -f "$UDP_LOCK_FILE"
        return 1
    fi

    if [ "$now" -lt "$expires" ]; then
        echo "UDP LOCK : ACTIVE"
        echo "UDP LOCK : expires $(date -d "@$expires" '+%Y-%m-%d %H:%M:%S')"
        echo "UDP LOCK : remaining $((expires - now)) seconds"
        return 0
    fi

    echo "UDP LOCK : EXPIRED"
    rm -f "$UDP_LOCK_FILE"

    return 1
}

set_udp_lock()
{
    local now
    local expires
    local tmp

    now=$(date +%s)
    expires=$((now + UDP_LOCK_SECONDS))

    # Atomic write so the actor never sees a partially written timestamp.
    tmp="${UDP_LOCK_FILE}.$$"

    printf '%s\n' "$expires" > "$tmp"
    mv -f "$tmp" "$UDP_LOCK_FILE"

    echo "UDP LOCK : SET"
    echo "UDP LOCK : expires $(date -d "@$expires" '+%Y-%m-%d %H:%M:%S')"
}

clear_udp_lock()
{
    if [ -f "$UDP_LOCK_FILE" ]; then
        echo "UDP LOCK : CLEAR"
        rm -f "$UDP_LOCK_FILE"
    fi
}

adjust_udp_lock()
{
    local delta="$1"
    local expires
    local new_expires
    local now
    local tmp

    if [ ! -f "$UDP_LOCK_FILE" ]; then
        return 0
    fi

    expires=$(cat "$UDP_LOCK_FILE" 2>/dev/null || true)

    if ! [[ "$expires" =~ ^[0-9]+$ ]]; then
        echo "WARNING: Invalid UDP lock file."
        rm -f "$UDP_LOCK_FILE"
        return 0
    fi

    now=$(date +%s)
    new_expires=$((expires + delta))

    if [ "$new_expires" -le "$now" ]; then
        echo "UDP LOCK : ADJUST ${delta}s -> EXPIRED"
        rm -f "$UDP_LOCK_FILE"
        return 0
    fi

    tmp="${UDP_LOCK_FILE}.$$"
    printf '%s\n' "$new_expires" > "$tmp"
    mv -f "$tmp" "$UDP_LOCK_FILE"

    echo "UDP LOCK : ADJUST ${delta}s"
    echo "UDP LOCK : expires $(date -d "@$new_expires" '+%Y-%m-%d %H:%M:%S')"
}

gateway_changed()
{
    [ -f "$GW_CHANGE_FILE" ]
}

clear_gateway_changed()
{
    if [ -f "$GW_CHANGE_FILE" ]; then
        echo "GATEWAY CHANGE : CLEAR"
        rm -f "$GW_CHANGE_FILE"
    fi
}

verify_pending_restart()
{
    if [ ! -f "$RESTART_PENDING_FILE" ]; then
        return 0
    fi

    if [ "${HEALTHCHECK:-FAIL}" = "OK" ]; then
        echo "VPN RESTART     : VERIFIED"
        echo "HEALTHCHECK     : OK"
        echo "UDP LOCK        : EXTEND +20s"
        adjust_udp_lock +20
        rm -f "$RESTART_PENDING_FILE"
    else
        echo "VPN RESTART     : WAITING FOR HEALTHCHECK"
    fi
}

###############################################################################
# Read UDP OpenVPN parameters
#
# We deliberately read the configuration rather than guessing values.
###############################################################################

get_udp_tun_mtu()
{
    [ -f "$UDP_OVPN" ] || return 1

    awk '
        $1 == "tun-mtu" {
            print $2
            exit
        }
    ' "$UDP_OVPN"
}

get_udp_gateway()
{
    [ -f "$UDP_OVPN" ] || return 1

    awk '
        $1 == "route-gateway" {
            print $2
            exit
        }
    ' "$UDP_OVPN"
}

###############################################################################
# UDP MTU capability test
#
# Important:
#
# This is a preflight test and is deliberately independent of tun1312.
# A failed probe selects TCP and sets the one-hour UDP policy lock; it is not
# counted as a failed OpenVPN activation (and does not advance its backoff).
# The target and payload rules are existing proof-of-concept policy. A probe
# is a network capability heuristic, not proof that VPN traffic will work.
###############################################################################

test_udp_mtu()
{
    local tun_mtu
    local payload

    tun_mtu=$(get_udp_tun_mtu)

    if [ -z "$tun_mtu" ]; then
        echo "UDP MTU TEST : FAIL"
        echo "ERROR        : tun-mtu not found in $UDP_OVPN"
        return 1
    fi

    if ! [[ "$tun_mtu" =~ ^[0-9]+$ ]]; then
        echo "UDP MTU TEST : FAIL"
        echo "ERROR        : invalid tun-mtu: $tun_mtu"
        return 1
    fi

    payload=$((tun_mtu + 100 ))

    echo "UDP MTU TEST"
    echo "  OVPN      : $UDP_OVPN"
    echo "  tun-mtu   : $tun_mtu"
    echo "  ping size : $payload"
    echo "  target    : pnf.klojcnik.de"
    echo

    if ping \
        -c 1 \
        -W 3 \
        -s "$payload" \
        -M do \
        "pnf.klojcnik.de"
    then
        echo "UDP MTU TEST : OK"
        return 0
    fi

    echo "UDP MTU TEST : FAIL"
    return 1
}

###############################################################################
# Select VPN when nothing is currently active
###############################################################################

select_vpn_when_down()
{
    echo "========================================="
    echo "NO VPN ACTIVE"
    echo "========================================="

    #
    # A UDP lock explicitly prevents another UDP attempt.
    #
    if udp_lock_active; then
        echo "ACTION : UDP locked -> START TCP"
        start_vpn "$TCP_PROFILE"
        return $?
    fi

    #
    # No lock:
    # test UDP capability before selecting a VPN.
    #
    if test_udp_mtu; then
        echo
        echo "ACTION : UDP MTU test passed -> START UDP"

        clear_udp_lock

        start_udp_or_fallback
        return $?
    fi

    #
    # UDP capability failed.
    #
    # TCP is the fallback and UDP is locked for one hour.
    #
    echo
    echo "ACTION : UDP MTU test failed"
    echo "ACTION : START TCP"
    echo "ACTION : LOCK UDP FOR 1 HOUR"

    log_udp_failure "UDP_MTU_PROBE_FAILED"
    set_udp_lock

    start_vpn "$TCP_PROFILE"
}

###############################################################################
# TCP -> UDP transition
###############################################################################

try_udp_from_tcp()
{
    echo "========================================="
    echo "TCP ACTIVE"
    echo "========================================="

    # Do not leave an activated but nonfunctional TCP tunnel unattended.
    # A failed reactivation advances only TCP's staged retry backoff.
    if [ "${VPN_INTERFACE:-FAIL}" != "OK" ] || [ "${HEALTHCHECK:-FAIL}" != "OK" ]; then
        echo "ACTION : TCP UNHEALTHY -> RECOVER TCP"
        if ! check_start_backoff "$TCP_PROFILE"; then
            echo "ACTION : KEEP TCP (retry cooldown)"
            return 0
        fi
        stop_vpn "$TCP_PROFILE" || return 1
        start_vpn "$TCP_PROFILE"
        return $?
    fi

    #
    # If UDP is locked, there is nothing to test.
    #
    if udp_lock_active; then
        echo "ACTION : KEEP TCP (UDP locked)"
        return 0
    fi

    #
    # Stop TCP before performing the UDP path test.
    #
    if ! stop_vpn "$TCP_PROFILE"; then
        return 1
    fi

    #
    # Test UDP capability while no VPN is active.
    #
    if test_udp_mtu; then

        echo
        echo "ACTION : MTU test passed -> START UDP"

        clear_udp_lock

        start_udp_or_fallback
        return $?
    fi

    #
    # UDP path is not usable.
    #
    # Restore TCP so the machine is never intentionally left without VPN.
    #
    echo
    echo "ACTION : MTU test failed"
    echo "ACTION : SET UDP LOCK FOR 1 HOUR"
    echo "ACTION : RESTORE TCP"

    set_udp_lock

    start_vpn "$TCP_PROFILE"
}

###############################################################################
# UDP active handling
###############################################################################

handle_udp()
{
    echo "========================================="
    echo "UDP ACTIVE"
    echo "========================================="

    #
    # If UDP is actually running successfully, an old lock has no purpose.
    #
    clear_udp_lock

    #
    # Health Monitor remains authoritative for the health of the
    # already-established UDP tunnel.
    #
    if [ "${VPN_INTERFACE:-FAIL}" != "OK" ] || [ "${HEALTHCHECK:-FAIL}" != "OK" ]; then
        echo "ACTION : UDP UNHEALTHY -> IMMEDIATE TCP FALLBACK"
        fallback_to_tcp "UDP_TUNNEL_OR_HEALTHCHECK_FAILED"
        return $?
    fi

    echo "ACTION : KEEP UDP UP"
    return 0
}

###############################################################################
# Session policy
###############################################################################

if [ "${LOGIN:-FAIL}" != "OK" ] || [ "${SCREEN:-FAIL}" != "OK" ]; then

    echo "========================================="
    echo "SESSION NOT USABLE"
    echo "========================================="

    if vpn_is_active "$UDP_PROFILE"; then
        stop_vpn "$UDP_PROFILE"
    fi

    if vpn_is_active "$TCP_PROFILE"; then
        stop_vpn "$TCP_PROFILE"
    fi

    echo "ACTION : KEEP VPN DOWN"
    exit 0
fi

###############################################################################
# Network policy
###############################################################################

if [ "${CONNECTIVITY:-UNKNOWN}" != "full" ]; then
    echo "ACTION : WAIT (no full network connectivity)"
    exit 0
fi

###############################################################################
# Determine actual active VPN from NetworkManager
###############################################################################

ACTIVE_VPN=$(get_active_vpn)

echo "ACTIVE VPN      : $ACTIVE_VPN"
echo

###############################################################################
# Verify a previous restart only after the Health Monitor has run again.
###############################################################################

verify_pending_restart

###############################################################################
# Route-change event + VPN-health decision
#
# The route watcher compares the complete selected *physical* default-route
# string, including route metrics, for both IPv4 and IPv6. It ignores tun*
# routes but intentionally treats ANY changed route attribute as an event.
# The file name and existing log label say "gateway change" for historical
# reasons; the detection is deliberately broader than a gateway-IP change.
#
# An event clears the UDP policy lock, permitting a fresh UDP assessment.
# Healthy VPN + event -> reevaluate/restart according to current VPN policy.
# Unhealthy VPN + event -> run the normal recovery state machine instead.
# A healthcheck succeeding does not consume an event from a later route change.
###############################################################################

if gateway_changed; then

    echo "========================================="
    echo "GATEWAY CHANGE DETECTED"
    echo "========================================="
    echo "HEALTHCHECK     : ${HEALTHCHECK:-UNKNOWN}"

    if [ "${HEALTHCHECK:-FAIL}" = "OK" ]; then

        case "$ACTIVE_VPN" in

            UDP)
                if udp_lock_active; then
                    echo "ACTION : GATEWAY CHANGE -> TCP FALLBACK (UDP LOCKED)"
                    if fallback_to_tcp "UDP_LOCKED_ON_GATEWAY_CHANGE"; then
                        clear_gateway_changed
                        exit 0
                    fi
                    exit 1
                else
                    echo "ACTION : GATEWAY CHANGE -> RESTART UDP"
                    if restart_vpn "$UDP_PROFILE"; then
                        clear_gateway_changed
                        exit 0
                    fi
                    exit 1
                fi
                ;;

            TCP)
                if udp_lock_active; then
                    echo "ACTION : GATEWAY CHANGE -> RESTART TCP (UDP LOCKED)"
                    if restart_vpn "$TCP_PROFILE"; then
                        clear_gateway_changed
                        exit 0
                    fi
                    exit 1
                else
                    echo "ACTION : GATEWAY CHANGE -> TRY UDP"
                    if try_udp_from_tcp; then
                        clear_gateway_changed
                        exit 0
                    fi
                    exit 1
                fi
                ;;

            NONE)
                echo "ACTION : GATEWAY CHANGE -> NORMAL VPN SELECTION"
                if select_vpn_when_down; then
                    clear_gateway_changed
                    exit 0
                fi
                exit 1
                ;;

            *)
                echo "ERROR: Unknown VPN state during gateway change: $ACTIVE_VPN"
                exit 1
                ;;

        esac

    else

        # Health is not OK. Let the normal state machine perform its
        # existing recovery logic rather than restarting only because
        # the physical gateway changed.
        echo "ACTION : GATEWAY CHANGE + HEALTHCHECK FAIL -> NORMAL RECOVERY"
        clear_gateway_changed

    fi
fi

###############################################################################
# Main state machine
###############################################################################

case "$ACTIVE_VPN" in

    NONE)
        select_vpn_when_down
        exit $?
        ;;

    TCP)
        try_udp_from_tcp
        exit $?
        ;;

    UDP)
        handle_udp
        exit $?
        ;;

    *)
        echo "ERROR: Unknown VPN state: $ACTIVE_VPN"
        exit 1
        ;;

esac
