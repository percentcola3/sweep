#!/bin/bash
# App bridge: disable one proxy kind on one network service (owner command:
# networksetup). Runs privileged via the GUI's osascript wrapper.
# Usage: app_net_fixproxy.sh <service> <http|https|socks>
set -euo pipefail

svc="${1:?missing service}"
kind="${2:?missing kind}"
case "$kind" in
    http)  networksetup -setwebproxystate "$svc" off ;;
    https) networksetup -setsecurewebproxystate "$svc" off ;;
    socks) networksetup -setsocksfirewallproxystate "$svc" off ;;
    *)
        echo "unknown proxy kind: $kind" >&2
        exit 2
        ;;
esac
printf 'disabled %s proxy on %s\n' "$kind" "$svc"
