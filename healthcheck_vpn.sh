#!/usr/bin/env bash

###############################################################################
#
# VPN Client Health Monitor
#
# Purpose
# -------
# This script performs an end-to-end health assessment of the local VPN client.
#
# It does NOT attempt to repair, restart or reconnect the VPN.
# Its only responsibility is to observe the current system state and publish
# the result for another service (the VPN Actor / Watchdog).
#
###############################################################################

RET=0

STATUS_FILE="/run/vpn-health.state"
UDP_OVPN="/opt/vpn/ovpn/udp.ovpn"

LOGIN="FAIL"
SCREEN="FAIL"
VPN_INTERFACE="FAIL"
VPN_IP=""
VPN_GATEWAY=""
VPN_TYPE="NONE"
HEALTHCHECK="FAIL"
TIME="WARN"
STATUS="UNHEALTHY"
CONNECTIVITY="UNKNOWN"

ok()   { printf " \033[32mOK\033[0m   %s\n" "$1"; }
fail() { printf " \033[31mFAIL\033[0m %s\n" "$1"; RET=1; }
warn() { printf " \033[33mWARN\033[0m %s\n" "$1"; }

echo "========== CLIENT HEALTH CHECK =========="


###############################################################################
# Check 1
# Verify that a real local user is currently logged in.
###############################################################################

echo
echo "[LOGIN]"

if who | grep -q .; then
    ok "User logged in"
    LOGIN="OK"
else
    fail "Kein User logged in"
fi


###############################################################################
# Check 2
# Verify that the active desktop session is unlocked.
#
# Cinnamon:
#   ONLY cinnamon-screensaver-command --query
#
# KDE / other desktops:
#   loginctl LockedHint
###############################################################################

echo
echo "[SCREEN]"

SCREEN="FAIL"

if command -v cinnamon-screensaver-command >/dev/null 2>&1; then

    s=$(env DISPLAY=:0 \
        /usr/bin/cinnamon-screensaver-command --query 2>/dev/null)

    # The screensaver query may return localized text. The German tokens below
    # are input-matching literals only; all operator-facing messages are English.
    # Keep both variants to avoid changing lock-state detection on existing hosts.
    case "$s" in
        *inaktiv*|*inactive*)
            ok "Screen unlocked (Cinnamon)"
            SCREEN="OK"
            ;;
        *aktiv*|*active*)
            fail "Screen locked (Cinnamon)"
            ;;
        *)
            warn "Unknown Cinnamon screen-lock status: $s"
            SCREEN="OK"
            ;;
    esac

elif command -v loginctl >/dev/null 2>&1; then

    SESSION=$(loginctl list-sessions --no-legend 2>/dev/null |
        awk '$4 == "seat0" {print $1; exit}')

    LOCKED=$(loginctl show-session "$SESSION" \
        -p LockedHint --value 2>/dev/null)

    case "$LOCKED" in
        no)
            ok "Screen unlocked"
            SCREEN="OK"
            ;;
        yes)
            fail "Screen locked"
            ;;
        *)
            warn "Unknown screen-lock status"
            SCREEN="OK"
            ;;
    esac

else
    warn "No screen-lock detection method available"
    SCREEN="OK"
fi

###############################################################################
# Check 3
# Verify that the VPN tunnel interface exists and has an IPv6 address.
#
# The VPN gateway is taken from the IPv6 routing table.
#
# IPv4 is intentionally not used here.
###############################################################################

echo
echo "[VPN]"

VPN_GW=""
VPN_TYPE="NONE"

if ip link show tun1312 >/dev/null 2>&1; then

    ok "tun1312 is present"
    VPN_INTERFACE="OK"

    ###########################################################################
    # IPv6 VPN address
    ###########################################################################

    TUN_IP=$(ip -6 -o addr show dev tun1312 scope global \
        | awk 'NR==1 {print $4}' \
        | cut -d/ -f1)

    if [ -n "$TUN_IP" ]; then

        ok "tun1312 IPv6: $TUN_IP"
        VPN_IP="$TUN_IP"

    else
        fail "No global IPv6 address on tun1312"
    fi


    ###########################################################################
    # IPv6 VPN gateway
    #
    # IMPORTANT:
    # There are two default routes:
    #
    #   default proto static
    #   default via fdff:dc59:0:1::1 ...
    #
    # We explicitly require "via".
    ###########################################################################

    VPN_GW=$(ip -6 route show dev tun1312 \
        | awk '$1 == "default" && $2 == "via" {print $3; exit}')

    if [ -n "$VPN_GW" ]; then

        ok "IPv6 Gateway: $VPN_GW"
        VPN_GATEWAY="$VPN_GW"

    else
        fail "No IPv6 gateway found on tun1312"
    fi


    ###########################################################################
    # Identify active VPN profile
    ###########################################################################

    if command -v nmcli >/dev/null 2>&1; then

        if nmcli -t -f NAME connection show --active \
            | grep -Fxq "prototype_udp"; then

            VPN_TYPE="UDP"
            ok "VPN type: UDP"

        elif nmcli -t -f NAME connection show --active \
            | grep -Fxq "prototype_tcp"; then

            VPN_TYPE="TCP"
            ok "VPN type: TCP"

        else
            warn "No recognized VPN profile is active"
            VPN_TYPE="UNKNOWN"
        fi

    else
        warn "nmcli is unavailable"
        VPN_TYPE="UNKNOWN"
    fi

else

    fail "tun1312 does not exist"

fi


###############################################################################
# Check 4
# End-to-end VPN validation over IPv6.
###############################################################################

echo
echo "[HEALTHCHECK]"

if [ -n "$VPN_GW" ]; then

    HTTP_CODE=$(curl \
        --ipv6 \
        --interface tun1312 \
        --connect-timeout 3 \
        --max-time 5 \
        --silent \
        --output "/tmp/vpn_health.$$" \
        --write-out "%{http_code}" \
        "http://[$VPN_GW]:7000/")

    BODY=$(cat "/tmp/vpn_health.$$" 2>/dev/null)
    rm -f "/tmp/vpn_health.$$"

    if [ "$HTTP_CODE" = "200" ] && [ "$BODY" = "I AM ALIVE" ]; then

        ok "VPN health check passed"
        HEALTHCHECK="OK"

    else

        fail "VPN health check failed (HTTP $HTTP_CODE)"
        HEALTHCHECK="FAIL"

    fi

else

    fail "VPN health check skipped (no IPv6 VPN gateway)"
    HEALTHCHECK="FAIL"

fi



###############################################################################
# Check 5
# Verify that the local system clock is synchronized.
###############################################################################

echo
echo "[TIME]"

if command -v timedatectl >/dev/null 2>&1; then

    NTP=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)

    if [ "$NTP" = "yes" ]; then
        ok "System clock synchronized"
        TIME="OK"
    else
        warn "System clock is not synchronized"
    fi

else
    warn "timedatectl is unavailable"
fi


###############################################################################
# Check 6
# Query NetworkManager for overall network connectivity.
###############################################################################

echo
echo "[CONNECTIVITY]"

if command -v nmcli >/dev/null 2>&1; then

    CONNECTIVITY=$(nmcli networking connectivity 2>/dev/null)

    case "$CONNECTIVITY" in
        full)
            ok "Network online (full)"
            ;;
        limited)
            warn "Network connectivity limited (limited)"
            ;;
        portal)
            warn "Captive portal detected"
            ;;
        none)
            fail "No network connection"
            ;;
        *)
            warn "Unknown network connectivity status ($CONNECTIVITY)"
            ;;
    esac

else
    warn "nmcli is unavailable"
fi


###############################################################################
# Summary
###############################################################################

echo
echo "========================================="

if [ "$RET" -eq 0 ]; then
    printf "\033[32mSTATUS: HEALTHY\033[0m\n"
    STATUS="HEALTHY"
else
    printf "\033[31mSTATUS: UNHEALTHY\033[0m\n"
    STATUS="UNHEALTHY"
fi

echo "========================================="


###############################################################################
# Publish current state
###############################################################################

TMP_FILE="${STATUS_FILE}.$$"

cat > "$TMP_FILE" <<EOF
STATUS=$STATUS
LOGIN=$LOGIN
SCREEN=$SCREEN
VPN_INTERFACE=$VPN_INTERFACE
VPN_IP=$VPN_IP
VPN_GATEWAY=$VPN_GATEWAY
VPN_TYPE=$VPN_TYPE
HEALTHCHECK=$HEALTHCHECK
TIME=$TIME
EXITCODE=$RET
TIMESTAMP=$(date +%s)
CONNECTIVITY=$CONNECTIVITY
EOF

mv "$TMP_FILE" "$STATUS_FILE"

exit 0
