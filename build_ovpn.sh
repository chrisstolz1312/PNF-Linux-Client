#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_DIR="$SCRIPT_DIR/.ovpn"
INSTALL_DIR="/opt/vpn/ovpn"

###############################################################################
# Root required
###############################################################################

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this script with sudo."
    echo
    echo "Example:"
    echo "  sudo ./build_ovpn.sh"
    exit 1
fi

###############################################################################
# Source directory
###############################################################################

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: Source directory not found:"
    echo "  $SOURCE_DIR"
    exit 1
fi

###############################################################################
# Find exactly one source OVPN
###############################################################################

sources=()

for file in "$SOURCE_DIR"/*.ovpn; do
    [[ -f "$file" ]] || continue

    case "$(basename "$file")" in
        udp.ovpn|tcp.ovpn)
            continue
            ;;
        *)
            sources+=("$file")
            ;;
    esac
done

if [[ "${#sources[@]}" -eq 0 ]]; then
    echo "ERROR: No source .ovpn file found."
    echo
    echo "Expected:"
    echo "  $SOURCE_DIR/*.ovpn"
    exit 1
fi

if [[ "${#sources[@]}" -gt 1 ]]; then
    echo "ERROR: Multiple source .ovpn files found:"
    printf '  %s\n' "${sources[@]}"
    exit 1
fi

SOURCE="${sources[0]}"

echo
echo "Source:"
echo "  $SOURCE"

###############################################################################
# Check required parameters
###############################################################################

for param in proto tun-mtu mssfix; do
    if ! grep -Eq "^[[:space:]]*${param}[[:space:]]+" "$SOURCE"; then
        echo "ERROR: Required parameter '$param' is missing from $(basename "$SOURCE")."
        exit 1
    fi
done

###############################################################################
# Create installation directory
###############################################################################

install -d -m 700 "$INSTALL_DIR"

###############################################################################
# Build UDP profile
###############################################################################

TMP_UDP="$(mktemp)"

cp "$SOURCE" "$TMP_UDP"

sed -i \
    -e 's/^[[:space:]]*proto[[:space:]].*/proto udp/' \
    -e 's/^[[:space:]]*dev[[:space:]].*/dev tun1312/' \
    -e 's/^[[:space:]]*tun-mtu[[:space:]].*/tun-mtu 1300/' \
    -e 's/^[[:space:]]*mssfix[[:space:]].*/mssfix 1200/' \
    -e '/^[[:space:]]*keepalive[[:space:]]/d' \
    "$TMP_UDP"

echo "keepalive 5 20" >> "$TMP_UDP"

mv -f "$TMP_UDP" "$INSTALL_DIR/udp.ovpn"

chown root:root "$INSTALL_DIR/udp.ovpn"
chmod 600 "$INSTALL_DIR/udp.ovpn"

###############################################################################
# Build TCP profile
###############################################################################

TMP_TCP="$(mktemp)"

cp "$SOURCE" "$TMP_TCP"

sed -i \
    -e 's/^[[:space:]]*proto[[:space:]].*/proto tcp/' \
    -e 's/^[[:space:]]*dev[[:space:]].*/dev tun1312/' \
    -e 's/^[[:space:]]*tun-mtu[[:space:]].*/tun-mtu 1500/' \
    -e 's/^[[:space:]]*mssfix[[:space:]].*/mssfix 1400/' \
    -e '/^[[:space:]]*keepalive[[:space:]]/d' \
    "$TMP_TCP"

echo "keepalive 60 180" >> "$TMP_TCP"

mv -f "$TMP_TCP" "$INSTALL_DIR/tcp.ovpn"

chown root:root "$INSTALL_DIR/tcp.ovpn"
chmod 600 "$INSTALL_DIR/tcp.ovpn"

###############################################################################
# Result
###############################################################################

echo
echo "Done."
echo

echo "UDP:"
grep -E '^[[:space:]]*(proto|tun-mtu|mssfix|keepalive)[[:space:]]+' \
    "$INSTALL_DIR/udp.ovpn"

echo
echo "TCP:"
grep -E '^[[:space:]]*(proto|tun-mtu|mssfix|keepalive)[[:space:]]+' \
    "$INSTALL_DIR/tcp.ovpn"

echo
echo "Installed to:"
echo "  $INSTALL_DIR/udp.ovpn"
echo "  $INSTALL_DIR/tcp.ovpn"

echo
echo "File permissions:"
ls -l "$INSTALL_DIR/udp.ovpn" "$INSTALL_DIR/tcp.ovpn"
