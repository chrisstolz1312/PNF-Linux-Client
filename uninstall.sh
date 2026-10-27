#!/usr/bin/env bash

set -euo pipefail

###############################################################################
#
# Syntetic Payload VPN Service
#
# Complete uninstaller
#
###############################################################################

UDP_PROFILE="prototype_udp"
TCP_PROFILE="prototype_tcp"

TARGET_DIR="/opt/vpn"
OVPN_DIR="/opt/vpn/ovpn"

###############################################################################
# systemd units
###############################################################################

WATCHDOG_SERVICE_FILE="/etc/systemd/system/vpn-watchdog.service"
WATCHDOG_TIMER_FILE="/etc/systemd/system/vpn-watchdog.timer"

# Legacy units - remove them as well
HEALTH_SERVICE_FILE="/etc/systemd/system/vpn-health.service"
HEALTH_TIMER_FILE="/etc/systemd/system/vpn-health.timer"

NETWORK_SERVICE_FILE="/etc/systemd/system/vpn-network-watch.service"
NETWORK_TIMER_FILE="/etc/systemd/system/vpn-network-watch.timer"

###############################################################################
# Runtime state
###############################################################################

STATE_FILE="/run/vpn-health.state"
UDP_LOCK="/run/vpn-udp.lock"
GW_CHANGE_FILE="/run/vpn-gateway-changed"
RESTART_PENDING_FILE="/run/vpn-restart-pending"

STATE_FILE_V4="/run/vpn-default-route-v4"
STATE_FILE_V6="/run/vpn-default-route-v6"

###############################################################################
# Root check
###############################################################################

if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo."
    echo
    echo "Usage:"
    echo "  sudo ./uninstall.sh"
    exit 1
fi

###############################################################################
# Required commands
###############################################################################

for command in nmcli systemctl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $command"
        exit 1
    fi
done

###############################################################################
# Header
###############################################################################

echo
echo "========================================="
echo "   SYNTETIC PAYLOAD VPN SERVICE"
echo "   COMPLETE UNINSTALL"
echo "========================================="
echo

###############################################################################
# Stop active VPN connections
###############################################################################

echo "Stopping active VPN profiles..."
echo

nmcli connection down "$UDP_PROFILE" 2>/dev/null || true
nmcli connection down "$TCP_PROFILE" 2>/dev/null || true

###############################################################################
# Stop watchdog
###############################################################################

echo
echo "Stopping VPN watchdog..."

systemctl disable --now vpn-watchdog.timer 2>/dev/null || true
systemctl stop vpn-watchdog.service 2>/dev/null || true

###############################################################################
# Stop legacy services
###############################################################################

echo
echo "Stopping legacy VPN services..."

systemctl disable --now vpn-health.timer 2>/dev/null || true
systemctl stop vpn-health.service 2>/dev/null || true

systemctl disable --now vpn-network-watch.timer 2>/dev/null || true
systemctl stop vpn-network-watch.service 2>/dev/null || true

###############################################################################
# Remove NetworkManager profiles
###############################################################################

echo
echo "Removing NetworkManager VPN profiles..."
echo

if nmcli connection show "$UDP_PROFILE" >/dev/null 2>&1; then
    echo "Removing: $UDP_PROFILE"
    nmcli connection delete "$UDP_PROFILE"
else
    echo "Not found: $UDP_PROFILE"
fi

if nmcli connection show "$TCP_PROFILE" >/dev/null 2>&1; then
    echo "Removing: $TCP_PROFILE"
    nmcli connection delete "$TCP_PROFILE"
else
    echo "Not found: $TCP_PROFILE"
fi

###############################################################################
# Remove systemd units
###############################################################################

echo
echo "Removing systemd units..."

rm -f "$WATCHDOG_SERVICE_FILE"
rm -f "$WATCHDOG_TIMER_FILE"

rm -f "$HEALTH_SERVICE_FILE"
rm -f "$HEALTH_TIMER_FILE"

rm -f "$NETWORK_SERVICE_FILE"
rm -f "$NETWORK_TIMER_FILE"

systemctl daemon-reload

systemctl reset-failed \
    vpn-watchdog.service \
    vpn-watchdog.timer \
    vpn-health.service \
    vpn-health.timer \
    vpn-network-watch.service \
    vpn-network-watch.timer \
    2>/dev/null || true

###############################################################################
# Remove installed VPN files
###############################################################################

echo
echo "Removing installed VPN files..."

rm -f "$TARGET_DIR/healthcheck_vpn.sh"
rm -f "$TARGET_DIR/network_change_watch.sh"
rm -f "$TARGET_DIR/actor_vpn.sh"

rm -f "$OVPN_DIR/udp.ovpn"
rm -f "$OVPN_DIR/tcp.ovpn"

###############################################################################
# Remove runtime state
###############################################################################

echo
echo "Removing runtime state..."

rm -f "$STATE_FILE"
rm -f "$UDP_LOCK"
rm -f "$GW_CHANGE_FILE"
rm -f "$RESTART_PENDING_FILE"

rm -f "$STATE_FILE_V4"
rm -f "$STATE_FILE_V6"

###############################################################################
# Remove empty directories
###############################################################################

echo
echo "Removing empty installation directories..."

rmdir "$OVPN_DIR" 2>/dev/null || true
rmdir "$TARGET_DIR" 2>/dev/null || true

###############################################################################
# Verification
###############################################################################

echo
echo "========================================="
echo "VERIFICATION"
echo "========================================="
echo

echo "NetworkManager profiles:"

if nmcli connection show "$UDP_PROFILE" >/dev/null 2>&1; then
    echo "WARNING: $UDP_PROFILE still exists."
else
    echo "OK: $UDP_PROFILE removed."
fi

if nmcli connection show "$TCP_PROFILE" >/dev/null 2>&1; then
    echo "WARNING: $TCP_PROFILE still exists."
else
    echo "OK: $TCP_PROFILE removed."
fi

echo
echo "systemd units:"

for file in \
    "$WATCHDOG_SERVICE_FILE" \
    "$WATCHDOG_TIMER_FILE" \
    "$HEALTH_SERVICE_FILE" \
    "$HEALTH_TIMER_FILE" \
    "$NETWORK_SERVICE_FILE" \
    "$NETWORK_TIMER_FILE"
do
    if [[ -e "$file" ]]; then
        echo "WARNING: $file still exists."
    else
        echo "OK: $(basename "$file") removed."
    fi
done

echo
echo "Runtime files:"

for file in \
    "$STATE_FILE" \
    "$UDP_LOCK" \
    "$GW_CHANGE_FILE" \
    "$RESTART_PENDING_FILE" \
    "$STATE_FILE_V4" \
    "$STATE_FILE_V6"
do
    if [[ -e "$file" ]]; then
        echo "WARNING: $file still exists."
    else
        echo "OK: $(basename "$file") removed."
    fi
done

echo
echo "Installation directory:"

if [[ -e "$TARGET_DIR" ]]; then
    echo "INFO: $TARGET_DIR still exists."
    echo "      It was not empty and was therefore preserved."
else
    echo "OK: $TARGET_DIR removed."
fi

echo
echo "========================================="
echo "UNINSTALL COMPLETE"
echo "========================================="
echo
