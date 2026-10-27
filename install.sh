#!/usr/bin/env bash

set -euo pipefail

###############################################################################
#
# Syntetic Payload VPN Service
#
# Complete installer / orchestrator
#
# Steps:
#
#   1. Build / separate OVPN profiles
#   2. Install NetworkManager VPN profiles
#   3. Install unified VPN watchdog
#
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo."
    echo
    echo "Usage:"
    echo "  sudo ./install.sh"
    exit 1
fi

###############################################################################
# Required commands
###############################################################################

for command in \
    bash \
    nmcli \
    systemctl
do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $command"
        exit 1
    fi
done

###############################################################################
# Required installer components
###############################################################################

for file in \
    "$SCRIPT_DIR/build_ovpn.sh" \
    "$SCRIPT_DIR/install_vpn.sh" \
    "$SCRIPT_DIR/install_service.sh" \
    "$SCRIPT_DIR/healthcheck_vpn.sh" \
    "$SCRIPT_DIR/network_change_watch.sh" \
    "$SCRIPT_DIR/actor_vpn.sh"
do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: Required file not found:"
        echo "  $file"
        exit 1
    fi
done

###############################################################################
# Header
###############################################################################

echo
echo "========================================="
echo "   SYNTETIC PAYLOAD VPN SERVICE"
echo "========================================="
echo
echo "Installation directory:"
echo "  $SCRIPT_DIR"
echo

###############################################################################
# Step 1
###############################################################################

echo
echo "========================================="
echo "STEP 1/3 : BUILD OVPN PROFILES"
echo "========================================="
echo

bash "$SCRIPT_DIR/build_ovpn.sh"

###############################################################################
# Step 2
###############################################################################

echo
echo "========================================="
echo "STEP 2/3 : INSTALL VPN PROFILES"
echo "========================================="
echo

bash "$SCRIPT_DIR/install_vpn.sh"

###############################################################################
# Step 3
###############################################################################

echo
echo "========================================="
echo "STEP 3/3 : INSTALL VPN WATCHDOG"
echo "========================================="
echo

bash "$SCRIPT_DIR/install_service.sh"

###############################################################################
# Final verification
###############################################################################

echo
echo "========================================="
echo "INSTALLATION COMPLETE"
echo "========================================="
echo

echo "NetworkManager profiles:"
echo

nmcli connection show | grep -E \
    'prototype_udp|prototype_tcp' || true

echo
echo "VPN watchdog timer:"
echo

systemctl is-enabled vpn-watchdog.timer
systemctl is-active vpn-watchdog.timer

echo
echo "Installed successfully."
echo
