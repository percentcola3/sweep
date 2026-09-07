#!/bin/bash
# App bridge: network config audit. Read-only.
# proxy TSV: proxy \t service \t kind(http|https|socks) \t server:port
# hosts TSV: hosts \t <raw line from /etc/hosts>
set -euo pipefail
export LC_ALL=C

# 系统代理按网络服务枚举（读取状态无需管理员）
services=$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 || true)
while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    case "$svc" in \**) continue ;; esac
    check() {
        networksetup -get"$2"proxy "$svc" 2>/dev/null \
            | awk -v kind="$1" -v svc="$svc" '
                /^Enabled: Yes/{e=1} /^Server:/{s=$2} /^Port:/{p=$2}
                END { if (e && s != "" && p != "") printf "proxy\t%s\t%s\t%s:%s\n", svc, kind, s, p }'
    }
    check http web
    check https secureweb
    check socks socksfirewall
done <<< "$services"

# /etc/hosts 自定义条目（排除注释、localhost、broadcasthost、空行）
awk 'NF && $1 !~ /^#/ && $2 !~ /^(localhost|broadcasthost)$/ { print "hosts\t" $0 }' /etc/hosts 2>/dev/null || true
