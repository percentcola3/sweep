#!/bin/bash
# ForgeSweep per-app network traffic observation (read-only).
#
# Four modes feeding the Traffic tab. All output is TSV on stdout; errors and
# diagnostics go to stderr. No mode mutates anything, escalates or inspects
# file content beyond routing tables and the local proxy controller.
#
#   bytes     nettop per-process cumulative counters
#             `proc<TAB>pid<TAB>bytes_in<TAB>bytes_out<TAB>comm`
#   flows     lsof snapshot of connected sockets (listeners excluded)
#             `flow<TAB>pid<TAB>comm<TAB>proto<TAB>local<TAB>remote`
#   routes    route lookup for IPs read from stdin (one per line)
#             `route<TAB>address<TAB>interface`
#   clash     GET /connections from the Clash/mihomo controller; raw JSON on
#             stdout. Endpoint from CLASH_ENDPOINT (`http://host:port` or
#             `unix:/path/to.sock`), optional CLASH_SECRET (env, never argv).
#   discover  best-effort local Clash core discovery from running processes
#             and their config: `endpoint<TAB>…`, `secret<TAB>…`,
#             `mixedport<TAB>N`, `proxyport<TAB>N` lines. Prints nothing when nothing is found.
#
# Test seams: MOLE_TEST_NETTOP_BIN / MOLE_TEST_LSOF_BIN / MOLE_TEST_ROUTE_BIN /
# MOLE_TEST_PS_BIN / MOLE_TEST_CURL_BIN replace the real binaries when
# MOLE_TEST_MODE=1.
set -euo pipefail
export LC_ALL=C

mode="${1:?usage: app_netmon.sh bytes|flows|routes|clash|discover}"

is_test_mode() { [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; }

nettop_bytes() {
    local nettop_bin="/usr/bin/nettop"
    is_test_mode && nettop_bin="${MOLE_TEST_NETTOP_BIN:-/usr/bin/nettop}"
    [[ -x "$nettop_bin" ]] || return 0
    "$nettop_bin" -P -x -l 1 2>/dev/null | /usr/bin/awk '
        /^time[ \t]/ { next }
        {
            i = 1
            if ($1 ~ /^[0-9][0-9]*:[0-9][0-9]:[0-9][0-9]/) i = 2
            name = ""; pid_token = ""
            for (; i <= NF; i++) {
                token = $i
                sub(/\*+$/, "", token)
                if (token ~ /\.[0-9]+$/) {
                    pid_token = token
                    sub(/\.[0-9]+$/, "", token)
                    name = name == "" ? token : name " " token
                    i++
                    break
                }
                name = name == "" ? token : name " " token
            }
            if (pid_token == "" || i + 1 > NF) next
            pid = pid_token
            sub(/^.*\./, "", pid)
            pid += 0
            if (pid <= 0) next
            bytes_in = $i; bytes_out = $(i + 1)
            if (bytes_in !~ /^[0-9]+$/ || bytes_out !~ /^[0-9]+$/) next
            printf "proc\t%s\t%s\t%s\t%s\n", pid, bytes_in, bytes_out, name
        }
    ' | /usr/bin/sort -t "$(printf '\t')" -k2,2n -u
}

lsof_flows() {
    local lsof_bin="/usr/sbin/lsof"
    is_test_mode && lsof_bin="${MOLE_TEST_LSOF_BIN:-/usr/sbin/lsof}"
    [[ -x "$lsof_bin" ]] || return 0
    # P is the transport protocol; t would be the socket family (IPv4/IPv6).
    "$lsof_bin" -nP -FpcnP -iTCP -iUDP 2>/dev/null | /usr/bin/awk '
        /^p[0-9]+/ { pid = substr($0, 2); next }
        /^c/ { comm = substr($0, 2); next }
        /^f/ { proto = ""; next }
        /^P/ { proto = substr($0, 2); next }
        /^n/ {
            endpoint = substr($0, 2)
            arrow = index(endpoint, "->")
            if (arrow == 0) next
            remote = substr(endpoint, arrow + 2)
            if (remote == "" || pid == "") next
            local_addr = substr(endpoint, 1, arrow - 1)
            printf "flow\t%s\t%s\t%s\t%s\t%s\n", pid, comm, proto, local_addr, remote
            next
        }
    '
}

route_lookups() {
    local route_bin="/sbin/route"
    is_test_mode && route_bin="${MOLE_TEST_ROUTE_BIN:-/sbin/route}"
    [[ -x "$route_bin" ]] || return 0
    local address interface count=0
    while IFS= read -r address; do
        [[ "$address" =~ ^[0-9a-fA-F.:]+$ ]] || continue
        count=$((count + 1))
        [[ "$count" -gt 200 ]] && break
        # IPv6 字面量必须显式声明地址族，否则 route 报 bad address。
        if [[ "$address" == *:* ]]; then
            interface=$("$route_bin" -n get -inet6 "$address" 2>/dev/null \
                | /usr/bin/awk '/interface:/{print $2; exit}') || interface=""
        else
            interface=$("$route_bin" -n get "$address" 2>/dev/null \
                | /usr/bin/awk '/interface:/{print $2; exit}') || interface=""
        fi
        printf 'route\t%s\t%s\n' "$address" "${interface:-unknown}"
    done
}

clash_connections() {
    local curl_bin="/usr/bin/curl"
    is_test_mode && curl_bin="${MOLE_TEST_CURL_BIN:-/usr/bin/curl}"
    local endpoint="${CLASH_ENDPOINT:-}" secret="${CLASH_SECRET:-}"
    [[ -n "$endpoint" ]] || { echo "CLASH_ENDPOINT is empty" >&2; return 2; }
    [[ -x "$curl_bin" ]] || { echo "curl is unavailable" >&2; return 1; }
    local -a args=()
    if [[ "$endpoint" == unix:* ]]; then
        args+=(--unix-socket "${endpoint#unix:}" "http://localhost/connections")
    else
        args+=("${endpoint%/}/connections")
    fi
    # 密钥只经环境与 HTTP 头传递，绝不进入 argv。
    [[ -n "$secret" ]] && args+=(-H "Authorization: Bearer $secret")
    "$curl_bin" -m 4 -s "${args[@]}" || {
        echo "clash controller unreachable: $endpoint" >&2
        return 1
    }
}

discover_clash() {
    local ps_bin="/bin/ps"
    is_test_mode && ps_bin="${MOLE_TEST_PS_BIN:-/bin/ps}"
    local processes config endpoint secret port port_value
    processes=$("$ps_bin" -axo command= 2>/dev/null) || return 0

    while IFS= read -r endpoint; do
        [[ -n "$endpoint" ]] && printf 'endpoint\tunix:%s\n' "$endpoint"
    done < <(printf '%s\n' "$processes" | /usr/bin/grep -E 'mihomo|clash' \
        | /usr/bin/sed -nE 's/.*-ext-ctl-unix[ =]([^ ]+).*/\1/p' | /usr/bin/sort -u)

    while IFS= read -r config; do
        [[ -f "$config" ]] || continue
        endpoint=$(/usr/bin/sed -nE \
            "s/^external-controller:[[:space:]]*['\"]?([^'\"[:space:]]+)['\"]?[[:space:]]*$/\1/p" \
            "$config" | /usr/bin/head -n 1)
        if [[ -n "$endpoint" ]]; then
            case "$endpoint" in
                http://*|https://*) printf 'endpoint\t%s\n' "$endpoint" ;;
                *) printf 'endpoint\thttp://%s\n' "$endpoint" ;;
            esac
        fi
        secret=$(/usr/bin/sed -nE \
            "s/^secret:[[:space:]]*['\"]?([^'\"[:space:]]+)['\"]?[[:space:]]*$/\1/p" \
            "$config" | /usr/bin/head -n 1)
        [[ -n "$secret" ]] && printf 'secret\t%s\n' "$secret"
        for port in mixed-port socks-port port; do
            port_value=$(/usr/bin/sed -nE \
                "s/^${port}:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p" "$config" \
                | /usr/bin/head -n 1)
            if [[ -n "$port_value" ]]; then
                printf 'proxyport\t%s\n' "$port_value"
                if [[ "$port" == mixed-port ]]; then
                    printf 'mixedport\t%s\n' "$port_value"
                fi
            fi
        done
    done < <(printf '%s\n' "$processes" | /usr/bin/grep -E 'mihomo|clash' \
        | /usr/bin/sed -nE 's/.* -f (.*)$/\1/p' | /usr/bin/sed -E 's/ -[a-zA-Z][a-zA-Z0-9_-]* .*$//; s/ -[a-zA-Z][a-zA-Z0-9_-]*$//' \
        | /usr/bin/sort -u)
    return 0
}

case "$mode" in
    bytes) nettop_bytes ;;
    flows) lsof_flows ;;
    routes) route_lookups ;;
    clash) clash_connections ;;
    discover) discover_clash ;;
    *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac
