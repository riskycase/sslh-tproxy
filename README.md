# sslh-tproxy

Netfilter and policy-routing setup for sslh in transparent mode, as a Komodo stack
instead of a systemd unit.

sslh's transparent mode makes backend connections carry the original client IP. The
backends' replies therefore leave with a source address the kernel would route out the
wire, so they have to be marked and sent back to sslh's transparent sockets instead. That
marking is what this stack does, along with setting `route_localnet` — the backends
reply from 127.0.0.1, and the kernel drops 127/8 traffic routed off loopback without it.

Backends are host services (sshd, httpd), so everything runs in the host network
namespace. There is no MASQUERADE rule here — that belongs to the setup where sslh and
its backends live in separate namespaces, which this is not.

## Layout

| Path | What it is |
|---|---|
| `sslh-tproxy.sh` | the rule script: `apply`, `check`, `flush`, `run` |
| `Dockerfile` | alpine + iptables, ip6tables, iproute2 |
| `compose.yaml` | the `sslh-tproxy` sidecar, `sslh`, and `nginx-ui` |
| `tests/run.sh` | runs the script against fake netfilter tools |

## Tests

```
./tests/run.sh
```

No root, no netfilter, no container. `tests/fake-bin` stands in for iptables, ip6tables,
ip and sysctl, recording what the script asks for so repeated applies can be compared. Run this
before pushing; it is what keeps `apply` idempotent.

## Per-host setup

1. Create the Komodo stack:
   - source: this repo + branch, webhook enabled for redeploy on push
   - `run_directory`: the directory holding `compose.yaml` — also the build context
   - `extra_args`: `--build`, so a push that touches the Dockerfile or script rebuilds.
     Bare `docker compose up` only builds when the image is missing.
   - environment: `TZ`; `SSLH_PORTS` only to override the default

`sslh` and `sslh-tproxy` must be in the same stack — `depends_on` does not cross compose
projects.

## Why `sslh-tproxy` is privileged

Writing `route_localnet` needs a writable `/proc/sys`. Docker mounts it read-only, and
compose's `sysctls:` key is rejected under `network_mode: host`. The alternatives were a
host-side `/etc/sysctl.d` file (one manual step per host) or `privileged: true`.

This stack takes `privileged: true`, so that nothing about a host lives outside the
repo and a reboot needs no help. The cost is real and accepted: this container can act as
root on the host. `security_opt: systempaths=unconfined` looks narrower but isn't — with a
writable `/proc/sys`, root can rewrite host-global settings such as `kernel.core_pattern`,
which is a known container escape. Keep the image minimal and its base pinned.

## Knobs

| Variable | Default |
|---|---|
| `SSLH_PORTS` | `22 8443` |
| `SSLH_MARK` | `0x1` |
| `SSLH_TABLE` | `100` |
| `SSLH_IPV6` | `1` |
| `SSLH_RECONCILE_INTERVAL` | `60` |

## Verification, per host

1. `docker compose ps` — `sslh-tproxy` healthy, `sslh` running.
2. `sudo iptables -t mangle -S SSLH` and `-S OUTPUT`; repeat with `ip6tables`. One OUTPUT
   jump per port, no duplicates.
3. `ip rule show | grep fwmark` and `ip route show table 100`; repeat with `ip -6`.
   `sysctl net.ipv4.conf.all.route_localnet net.ipv4.conf.default.route_localnet` — both `= 1`.
4. Redeploy three times, re-check 2 and 3. Counts must be identical.
5. `sudo iptables -t mangle -F OUTPUT`, wait 60s, re-check 2. The reconcile loop restores
   them.
6. From an outside client, connect through the sslh port, then confirm on the host that
   sshd sees the real client address rather than 127.0.0.1: `sudo ss -tnp | grep ':22'`
   and `/var/log/auth.log`. A clean ruleset is not proof that transparency works.
7. `sudo reboot`, then re-run 1 through 3 and 6.
8. Only after all of the above: disable the old systemd unit, so the two cannot fight.

## Direct connections keep working

The OUTPUT jumps only match replies sourced from loopback (`-s 127.0.0.1`, `-s ::1`),
which is what sslh's backends reply from. A direct connection to port 22 on the public
interface replies from the public address, is never marked, and works as normal — so
direct ssh on 22 stays available as a way in even when the sslh container is down.

Older versions of this script marked every reply on these ports and broke direct ssh;
`apply` removes those unscoped jumps on startup, so upgrading needs no manual cleanup.

Rules stay resident after the stack comes down; no teardown is wired into the container
lifecycle, because a stop-time trap only fires on a graceful stop and is not a guarantee
worth building around. Manual teardown:

```
docker compose run --rm sslh-tproxy flush
```
