#!/bin/sh
# Marks reply traffic from sslh's backends so it is delivered back to sslh's transparent
# sockets instead of being sent out the wire. Every mode is safe to re-run: Docker
# restarts this container across reboots, and duplicate rules would stack.
set -eu

IFACE="${SSLH_IFACE:-}"
PORTS="${SSLH_PORTS:-22 8443}"
MARK="${SSLH_MARK:-0x1}"
TABLE="${SSLH_TABLE:-100}"
IPV6="${SSLH_IPV6:-1}"
INTERVAL="${SSLH_RECONCILE_INTERVAL:-60}"

# Backends reply from 127.0.0.1; the kernel drops 127/8 traffic routed off loopback
# unless route_localnet is set.
SYSCTLS="net.ipv4.conf.all.route_localnet net.ipv4.conf.default.route_localnet"

families() {
    if [ "$IPV6" = "1" ]; then
        echo "iptables ip6tables"
    else
        echo "iptables"
    fi
}

require_tools() {
    for tool in ip sysctl $(families); do
        command -v "$tool" >/dev/null || { echo "$tool missing from image" >&2; exit 1; }
    done
}

# Replies to clients leave through the interface carrying the main table's default route.
# Tailscale and wg-quick put theirs in separate tables, so they don't appear here; a host
# with several uplinks does, and is refused rather than guessed at.
detect_iface() {
    found=$(ip -4 route show default \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' | sort -u)
    case $(printf '%s' "$found" | grep -c .) in
        1) IFACE="$found" ;;
        0) echo "no IPv4 default route to detect the interface from; set SSLH_IFACE" >&2; exit 1 ;;
        *) echo "default routes on several interfaces ($(echo $found)); set SSLH_IFACE" >&2; exit 1 ;;
    esac
}

# iptables accepts -o for an interface that doesn't exist and the rule never matches,
# so a wrong SSLH_IFACE would otherwise "apply" cleanly and do nothing.
require_iface() {
    [ -n "$IFACE" ] || detect_iface
    ip link show dev "$IFACE" >/dev/null 2>&1 \
        || { echo "interface $IFACE does not exist; set SSLH_IFACE" >&2; exit 1; }
}

# Replies to connections sslh forwarded come from the loopback backends; replies to
# direct connections come from the public address. Matching the source keeps direct
# ssh to port 22 working.
loopback() {
    if [ "$1" = "ip6tables" ]; then
        echo "::1"
    else
        echo "127.0.0.1"
    fi
}

# Removes every OUTPUT jump into SSLH, whatever it matches, so jumps written by an older
# version of this script or for a different port list don't linger.
drop_jumps() {
    jumps=$("$1" -t mangle -S OUTPUT 2>/dev/null | grep -- '-j SSLH$' | sed 's/^-A //' || :)
    [ -n "$jumps" ] || return 0
    printf '%s\n' "$jumps" | while read -r rule; do
        # shellcheck disable=SC2086
        "$1" -t mangle -D $rule
    done
}

apply() {
    require_iface
    for key in $SYSCTLS; do
        sysctl -w "$key=1" >/dev/null
    done
    for ipt in $(families); do
        "$ipt" -t mangle -N SSLH 2>/dev/null || "$ipt" -t mangle -F SSLH
        "$ipt" -t mangle -A SSLH -j MARK --set-mark "$MARK"
        "$ipt" -t mangle -A SSLH -j ACCEPT
        drop_jumps "$ipt"
        for port in $PORTS; do
            "$ipt" -t mangle -A OUTPUT -p tcp -s "$(loopback "$ipt")" -o "$IFACE" --sport "$port" -j SSLH
        done
    done

    if ! ip rule show | grep -q "fwmark $MARK lookup $TABLE"; then
        ip rule add fwmark "$MARK" lookup "$TABLE"
    fi
    ip route replace local 0.0.0.0/0 dev lo table "$TABLE"

    if [ "$IPV6" = "1" ]; then
        if ! ip -6 rule show | grep -q "fwmark $MARK lookup $TABLE"; then
            ip -6 rule add fwmark "$MARK" lookup "$TABLE"
        fi
        ip -6 route replace local ::/0 dev lo table "$TABLE"
    fi

    echo "applied: iface=$IFACE ports=[$PORTS] mark=$MARK table=$TABLE ipv6=$IPV6"
}

check() {
    require_iface
    for key in $SYSCTLS; do
        [ "$(sysctl -n "$key")" = "1" ] || return 1
    done
    for ipt in $(families); do
        "$ipt" -t mangle -C SSLH -j MARK --set-mark "$MARK" 2>/dev/null || return 1
        for port in $PORTS; do
            "$ipt" -t mangle -C OUTPUT -p tcp -s "$(loopback "$ipt")" -o "$IFACE" --sport "$port" -j SSLH \
                2>/dev/null || return 1
        done
    done
    ip rule show | grep -q "fwmark $MARK lookup $TABLE" || return 1
    ip route show table "$TABLE" | grep -q 'local default' || return 1
    if [ "$IPV6" = "1" ]; then
        ip -6 rule show | grep -q "fwmark $MARK lookup $TABLE" || return 1
        ip -6 route show table "$TABLE" | grep -q 'local default' || return 1
    fi
}

# route_localnet is left as it is: its value before apply is unknown, and other
# services on the host may depend on it.
flush() {
    for ipt in $(families); do
        drop_jumps "$ipt"
        "$ipt" -t mangle -F SSLH 2>/dev/null || true
        "$ipt" -t mangle -X SSLH 2>/dev/null || true
    done
    ip rule del fwmark "$MARK" lookup "$TABLE" 2>/dev/null || true
    ip route flush table "$TABLE" 2>/dev/null || true
    if [ "$IPV6" = "1" ]; then
        ip -6 rule del fwmark "$MARK" lookup "$TABLE" 2>/dev/null || true
        ip -6 route flush table "$TABLE" 2>/dev/null || true
    fi
    echo "flushed"
}

require_tools
case "${1:-run}" in
    apply) apply ;;
    check) check ;;
    flush) flush ;;
    run)
        apply
        # A ufw reload or a manual iptables flush wipes these out from under us.
        # Re-apply on drift rather than leaving transparency silently broken.
        while sleep "$INTERVAL"; do
            check || apply
        done
        ;;
    *) echo "usage: $0 {apply|check|flush|run}" >&2; exit 2 ;;
esac
