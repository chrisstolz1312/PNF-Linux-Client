#!/bin/bash
sudo journalctl -f -o cat -t actor_vpn.sh -t healthcheck_vpn.sh -t network_change_watch.sh
exit 0
