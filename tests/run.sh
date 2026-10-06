#!/bin/sh
# Exercises sslh-tproxy.sh against fake netfilter tools: proves apply is idempotent and
# that check mode actually detects drift. Runs anywhere, needs no root and no netfilter.
set -eu

cd "$(dirname "$0")"
SCRIPT="../sslh-tproxy.sh"

PATH="$PWD/fake-bin:$PATH"
export PATH
FAKE_STATE=$(mktemp)
export FAKE_STATE
export SSLH_IFACE=eth0
export SSLH_PORTS="22 8443"

trap 'rm -f "$FAKE_STATE" "$FAKE_STATE.tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
snapshot() { sort "$FAKE_STATE"; }
netfilter_state() { grep -v '^SYSCTL ' "$FAKE_STATE" || :; }

: > "$FAKE_STATE"

sh "$SCRIPT" apply >/dev/null
first=$(snapshot)
[ -n "$first" ] || fail "apply produced no rules"
echo "ok   apply creates rules"

for key in net.ipv4.conf.all.route_localnet net.ipv4.conf.default.route_localnet; do
    [ "$(sysctl -n "$key")" = "1" ] || fail "apply did not set $key=1"
done
echo "ok   apply sets route_localnet on all and default"

unscoped=$(grep '^RULE ip6\{0,1\}tables mangle OUTPUT ' "$FAKE_STATE" | grep -v -e '-s 127\.0\.0\.1 ' -e '-s ::1 ' || :)
[ -z "$unscoped" ] || fail "OUTPUT jumps not limited to loopback replies: $unscoped"
echo "ok   apply marks only replies sourced from loopback"

sh "$SCRIPT" check || fail "check failed immediately after apply"
echo "ok   check passes after apply"

sh "$SCRIPT" apply >/dev/null
sh "$SCRIPT" apply >/dev/null
[ "$first" = "$(snapshot)" ] || fail "state drifted across repeated applies"
echo "ok   apply is idempotent across 3 runs"

iptables -t mangle -D OUTPUT -p tcp -s 127.0.0.1 -o eth0 --sport 22 -j SSLH
if sh "$SCRIPT" check; then fail "check passed with an OUTPUT jump missing"; fi
echo "ok   check detects a removed OUTPUT jump"

sh "$SCRIPT" apply >/dev/null
iptables -t mangle -F SSLH
if sh "$SCRIPT" check; then fail "check passed with the SSLH chain flushed"; fi
echo "ok   check detects a flushed SSLH chain"

sh "$SCRIPT" apply >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null
if sh "$SCRIPT" check; then fail "check passed with route_localnet reset to 0"; fi
echo "ok   check detects route_localnet reset to 0"

sh "$SCRIPT" apply >/dev/null
sh "$SCRIPT" check || fail "apply did not repair the drift"
[ "$first" = "$(snapshot)" ] || fail "repaired state differs from the original"
echo "ok   apply repairs drift back to the original state"

iptables -t mangle -A OUTPUT -p tcp -o eth0 --sport 22 -j SSLH
sh "$SCRIPT" apply >/dev/null
[ "$first" = "$(snapshot)" ] || fail "apply left a pre-upgrade unscoped jump in place"
echo "ok   apply removes unscoped jumps left by an older version"

sh "$SCRIPT" flush >/dev/null
[ -z "$(netfilter_state)" ] || fail "flush left rules behind: $(netfilter_state)"
echo "ok   flush removes every rule and route"

: > "$FAKE_STATE"
if SSLH_IFACE=eno9 sh "$SCRIPT" apply 2>/dev/null; then
    fail "apply succeeded against an interface that does not exist"
fi
[ ! -s "$FAKE_STATE" ] || fail "apply wrote state for a missing interface: $(snapshot)"
echo "ok   apply refuses a missing interface and writes nothing"

: > "$FAKE_STATE"
SSLH_IFACE= FAKE_DEFAULT_ROUTES="default via 10.0.0.1 dev eth0 proto static" sh "$SCRIPT" apply >/dev/null \
    || fail "apply failed to detect the interface from the default route"
[ "$first" = "$(snapshot)" ] || fail "detected interface produced different rules than SSLH_IFACE=eth0"
echo "ok   apply detects the interface from the default route"

: > "$FAKE_STATE"
if SSLH_IFACE= sh "$SCRIPT" apply 2>/dev/null; then
    fail "apply succeeded with no SSLH_IFACE and no default route"
fi
[ ! -s "$FAKE_STATE" ] || fail "apply wrote state with no interface to use: $(snapshot)"
echo "ok   apply refuses to guess when there is no default route"

two_routes="default via 10.0.0.1 dev eth0 proto static
default via 192.0.2.1 dev eno2 proto static"
if SSLH_IFACE= FAKE_IFACES="lo eth0 eno2" FAKE_DEFAULT_ROUTES="$two_routes" sh "$SCRIPT" apply 2>/dev/null; then
    fail "apply picked one of two default-route interfaces"
fi
[ ! -s "$FAKE_STATE" ] || fail "apply wrote state despite ambiguous default routes: $(snapshot)"
echo "ok   apply refuses to guess between two default-route interfaces"

echo
echo "PASS 15/15"
