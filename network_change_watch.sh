#!/usr/bin/env bash

set -euo pipefail

STATE_FILE_V4="/run/vpn-default-route-v4"
STATE_FILE_V6="/run/vpn-default-route-v6"

GW_CHANGE_FILE="/run/vpn-gateway-changed"
UDP_LOCK_FILE="/run/vpn-udp.lock"

###############################################################################
# Physical default-route observer
#
# Runs after the health check and before the actor. For each address family,
# select the lowest-metric non-tunnel default route and compare the ENTIRE
# route string with the last observed value. Detect metric, gateway, interface,
# and other attribute changes; do not narrow this to just the gateway address.
#
# Detection is deliberately sensitive: even a metric-only change may signal
# network settling/instability and should invalidate a stale UDP MTU result.
# One changed family is enough to publish the shared change marker. The actor
# subsequently consumes the marker and chooses how to recover.
#
# A temporarily missing default route is NOT stored as the new baseline; the
# next visible route is compared against the last known one. This is existing
# behavior and deserves review if requirements for route-loss events change.
#
# Get best default route for one address family (lowest metric wins).
###############################################################################

get_default_route()
{
    local family="$1"

    ip "-$family" route show default 2>/dev/null |
        awk '
            $0 ~ /(^|[[:space:]])dev[[:space:]]tun[0-9]+([[:space:]]|$)/ {
                next
            }

            {
                metric=32767

                for (i=1; i<=NF; i++) {
                    if ($i == "metric" && (i+1) <= NF) {
                        metric=$(i+1)
                        break
                    }
                }

                print metric "\t" $0
            }
        ' |
        sort -n -k1,1 |
        head -n1 |
        cut -f2-
}

###############################################################################
# Atomic state write
###############################################################################

write_state()
{
    local state_file="$1"
    local state="$2"
    local tmp_file

    tmp_file="$(mktemp)"

    printf '%s\n' "$state" > "$tmp_file"
    chmod 600 "$tmp_file"
    chown root:root "$tmp_file"

    mv -f "$tmp_file" "$state_file"
}

###############################################################################
# Check one address family
###############################################################################

check_route()
{
    local family="$1"
    local state_file="$2"
    local current_route
    local previous_route

    current_route="$(get_default_route "$family")"

    ###########################################################################
    # Debug: always show current configuration
    ###########################################################################

    echo "Current IPv${family} default route:"
    if [[ -n "$current_route" ]]; then
        printf '%s\n' "$current_route"
    else
        echo "<none>"
    fi

    ###########################################################################
    # No default route for this family.
    #
    # Do not change the stored state. This is important for transient
    # IPv6 Router Advertisement changes.
    ###########################################################################

    if [[ -z "$current_route" ]]; then
        return 0
    fi

    ###########################################################################
    # First observation.
    ###########################################################################

    if [[ ! -f "$state_file" ]]; then
        write_state "$state_file" "$current_route"
        return 0
    fi

    previous_route="$(cat "$state_file")"

    ###########################################################################
    # Nothing changed.
    ###########################################################################

    if [[ "$current_route" == "$previous_route" ]]; then
        return 0
    fi

    ###########################################################################
    # Any change to the selected full route is significant, including metric.
    ###########################################################################

    echo
    echo "IPv${family} default route changed."

    echo
    echo "Previous:"
    printf '%s\n' "$previous_route"

    echo
    echo "Current:"
    printf '%s\n' "$current_route"

    ###########################################################################
    # Publish a physical-route change (historically named "gateway change").
    # The route has been changed, so the previous UDP MTU policy lock is no
    # longer trusted. Notify the actor to reconsider current VPN policy.
    ###########################################################################

    echo
    echo "Gateway change detected."

    echo "Removing UDP lock..."
    rm -f "$UDP_LOCK_FILE"

    echo "Signaling gateway change..."
    touch "$GW_CHANGE_FILE"

    ###########################################################################
    # Store new route state
    ###########################################################################

    write_state "$state_file" "$current_route"

    echo
    echo "IPv${family} network change handled."
}

###############################################################################
# Main
###############################################################################

check_route 4 "$STATE_FILE_V4"
check_route 6 "$STATE_FILE_V6"
