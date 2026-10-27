#!/usr/bin/env bash

set -euo pipefail

###############################################################################
#
# OpenVPN NetworkManager Profile Installer
#
# udp.ovpn -> prototype_udp
# tcp.ovpn -> prototype_tcp
#
# Only installs the VPN profiles.
# No watchdog / actor / systemd configuration.
#
###############################################################################

OVPN_DIR="/opt/vpn/ovpn"

UDP_FILE="$OVPN_DIR/udp.ovpn"
TCP_FILE="$OVPN_DIR/tcp.ovpn"

UDP_PROFILE="prototype_udp"
TCP_PROFILE="prototype_tcp"

if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo."
    exit 1
fi

if ! command -v nmcli >/dev/null 2>&1; then
    echo "ERROR: nmcli not found."
    exit 1
fi

if [[ ! -f "$UDP_FILE" ]]; then
    echo "ERROR: $UDP_FILE not found."
    exit 1
fi

if [[ ! -f "$TCP_FILE" ]]; then
    echo "ERROR: $TCP_FILE not found."
    exit 1
fi

echo
echo "Installing VPN profiles..."
echo

###############################################################################
# Remove old profiles
###############################################################################

echo "Removing existing profiles..."

nmcli connection delete "$UDP_PROFILE" 2>/dev/null || true
nmcli connection delete "$TCP_PROFILE" 2>/dev/null || true

# Also remove profiles previously imported as "udp" or "tcp".
nmcli connection delete "udp" 2>/dev/null || true
nmcli connection delete "tcp" 2>/dev/null || true

###############################################################################
# UDP
###############################################################################

echo
echo "Importing UDP..."

UDP_OUTPUT="$(
    nmcli connection import type openvpn file "$UDP_FILE"
)"

echo "$UDP_OUTPUT"

UDP_UUID="$(
    printf '%s\n' "$UDP_OUTPUT" |
    grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' |
    head -n 1
)"

if [[ -z "$UDP_UUID" ]]; then
    echo "ERROR: Could not determine UDP connection UUID."
    exit 1
fi

echo "UDP UUID: $UDP_UUID"

nmcli connection modify "$UDP_UUID" \
    connection.id "$UDP_PROFILE" \
    connection.autoconnect no

###############################################################################
# TCP
###############################################################################

echo
echo "Importing TCP..."

TCP_OUTPUT="$(
    nmcli connection import type openvpn file "$TCP_FILE"
)"

echo "$TCP_OUTPUT"

TCP_UUID="$(
    printf '%s\n' "$TCP_OUTPUT" |
    grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' |
    head -n 1
)"

if [[ -z "$TCP_UUID" ]]; then
    echo "ERROR: Could not determine TCP connection UUID."
    exit 1
fi

echo "TCP UUID: $TCP_UUID"

nmcli connection modify "$TCP_UUID" \
    connection.id "$TCP_PROFILE" \
    connection.autoconnect no

###############################################################################
# Verification
###############################################################################

echo
echo "Verifying profiles..."
echo

if ! nmcli connection show "$UDP_PROFILE" >/dev/null 2>&1; then
    echo "ERROR: $UDP_PROFILE was not installed."
    exit 1
fi

if ! nmcli connection show "$TCP_PROFILE" >/dev/null 2>&1; then
    echo "ERROR: $TCP_PROFILE was not installed."
    exit 1
fi

echo "UDP profile:"
nmcli connection show "$UDP_PROFILE" | grep -E \
    'connection\.id:|connection\.uuid:|connection\.type:|connection\.autoconnect:'

echo
echo "TCP profile:"
nmcli connection show "$TCP_PROFILE" | grep -E \
    'connection\.id:|connection\.uuid:|connection\.type:|connection\.autoconnect:'

echo
echo "----------------------------------------"
echo "VPN profiles successfully installed."
echo "----------------------------------------"
echo
echo "  $UDP_PROFILE"
echo "  $TCP_PROFILE"
echo
echo "Autoconnect: disabled"
echo "Watchdog:    not installed"
echo
