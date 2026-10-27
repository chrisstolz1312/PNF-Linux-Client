#!/usr/bin/env bash

set -euo pipefail

###############################################################################
#
# VPN Watchdog Service Installer
#
# Installs:
#
#   /opt/vpn/
#       healthcheck_vpn.sh
#       network_change_watch.sh
#       actor_vpn.sh
#
#   /etc/systemd/system/
#       vpn-watchdog.service
#       vpn-watchdog.timer
#
###############################################################################

TARGET_DIR="/opt/vpn"

SERVICE_NAME="vpn-watchdog.service"
TIMER_NAME="vpn-watchdog.timer"

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
TIMER_FILE="/etc/systemd/system/$TIMER_NAME"

if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Verify required files
###############################################################################

for file in \
    "$SCRIPT_DIR/healthcheck_vpn.sh" \
    "$SCRIPT_DIR/network_change_watch.sh" \
    "$SCRIPT_DIR/actor_vpn.sh" \
    "$SCRIPT_DIR/vpn-watchdog.service" \
    "$SCRIPT_DIR/vpn-watchdog.timer"
do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: Required file not found:"
        echo "  $file"
        exit 1
    fi
done

###############################################################################
# Stop old / existing services
###############################################################################

echo
echo "Stopping existing VPN watchdog..."

systemctl stop "$TIMER_NAME" 2>/dev/null || true
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

echo
echo "Stopping legacy VPN services..."

systemctl stop vpn-health.timer 2>/dev/null || true
systemctl stop vpn-health.service 2>/dev/null || true

systemctl stop vpn-network-watch.timer 2>/dev/null || true
systemctl stop vpn-network-watch.service 2>/dev/null || true

###############################################################################
# Disable legacy timers
###############################################################################

echo
echo "Disabling legacy VPN timers..."

systemctl disable vpn-health.timer 2>/dev/null || true
systemctl disable vpn-network-watch.timer 2>/dev/null || true

###############################################################################
# Install runtime files
###############################################################################

echo
echo "Installing VPN watchdog scripts..."

install -d -m 755 "$TARGET_DIR"

install -m 755 \
    "$SCRIPT_DIR/healthcheck_vpn.sh" \
    "$TARGET_DIR/healthcheck_vpn.sh"

install -m 755 \
    "$SCRIPT_DIR/network_change_watch.sh" \
    "$TARGET_DIR/network_change_watch.sh"

install -m 755 \
    "$SCRIPT_DIR/actor_vpn.sh" \
    "$TARGET_DIR/actor_vpn.sh"

###############################################################################
# Install systemd service FIRST
###############################################################################

echo
echo "Installing VPN watchdog service..."

install -m 644 \
    "$SCRIPT_DIR/vpn-watchdog.service" \
    "$SERVICE_FILE"

###############################################################################
# Install systemd timer SECOND
###############################################################################

echo
echo "Installing VPN watchdog timer..."

install -m 644 \
    "$SCRIPT_DIR/vpn-watchdog.timer" \
    "$TIMER_FILE"

###############################################################################
# Reload systemd
###############################################################################

echo
echo "Reloading systemd..."

systemctl daemon-reload

###############################################################################
# Verify service is loaded
###############################################################################

echo
echo "Verifying VPN watchdog service..."

systemctl cat "$SERVICE_NAME" >/dev/null

echo "Service loaded:"
echo "  $SERVICE_FILE"

###############################################################################
# Enable and start timer
###############################################################################

echo
echo "Enabling VPN watchdog timer..."

systemctl enable "$TIMER_NAME"

echo
echo "Starting VPN watchdog timer..."

systemctl restart "$TIMER_NAME"

###############################################################################
# Result
###############################################################################

echo
echo "----------------------------------------"
echo "VPN Watchdog installed."
echo "----------------------------------------"
echo
echo "Runtime:"
echo "  $TARGET_DIR/healthcheck_vpn.sh"
echo "  $TARGET_DIR/network_change_watch.sh"
echo "  $TARGET_DIR/actor_vpn.sh"
echo
echo "Systemd:"
echo "  $SERVICE_FILE"
echo "  $TIMER_FILE"
echo
echo "Timer status:"
echo

systemctl --no-pager --full status "$TIMER_NAME"
