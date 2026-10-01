# sslh-tproxy

Netfilter and policy-routing setup for sslh in transparent mode, as a Komodo stack
instead of a systemd unit.

sslh's transparent mode makes backend connections carry the original client IP. The
backends' replies therefore leave with a source address the kernel would route out the
wire, so they have to be marked and sent back to sslh's transparent sockets instead. That
marking is what this stack does.

Backends are host services (sshd, httpd), so everything runs in the host network
namespace. There is no MASQUERADE rule here — that belongs to the setup where sslh and
its backends live in separate namespaces, which this is not.

## Layout

| Path | What it is |
|---|---|
| `sslh-tproxy.sh` | the rule script: `apply`, `check`, `flush`, `run` |
| `Dockerfile` | alpine + iptables, ip6tables, iproute2 |
| `compose.yaml` | the `sslh-tproxy` sidecar, `sslh`, and `nginx-ui` |
| `host/99-sslh-tproxy.conf` | sysctls, installed on the host — not by compose |
| `tests/run.sh` | runs the script against fake netfilter tools |

## Tests

```
./tests/run.sh
```

No root, no netfilter, no container. `tests/fake-bin` stands in for iptables, ip6tables
and ip, recording what the script asks for so repeated applies can be compared. Run this
before pushing; it is what keeps `apply` idempotent.

## Per-host setup

1. `ip -o link` — find the real interface name.
2. Install the sysctls (they are host kernel config, not container state; `/proc/sys` is
   read-only inside an unprivileged container and Docker rejects `net.*` in compose's
   `sysctls:` under host networking):

   ```
   sudo install -m 644 host/99-sslh-tproxy.conf /etc/sysctl.d/99-sslh-tproxy.conf
   sudo sysctl --system
   ```

3. Create the Komodo stack:
   - source: this repo + branch, webhook enabled for redeploy on push
   - `run_directory`: the directory holding `compose.yaml` — also the build context
   - `extra_args`: `--build`, so a push that touches the Dockerfile or script rebuilds.
     Bare `docker compose up` only builds when the image is missing.
   - environment: `SSLH_IFACE`, `SSLH_PORTS`

`sslh` and `sslh-tproxy` must be in the same stack — `depends_on` does not cross compose
projects.

## Knobs

| Variable | Default |
|---|---|
| `SSLH_IFACE` | `eth0` |
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
4. Redeploy three times, re-check 2 and 3. Counts must be identical.
5. `sudo iptables -t mangle -F OUTPUT`, wait 60s, re-check 2. The reconcile loop restores
   them.
6. From an outside client, connect through the sslh port, then confirm on the host that
   sshd sees the real client address rather than 127.0.0.1: `sudo ss -tnp | grep ':22'`
   and `/var/log/auth.log`. A clean ruleset is not proof that transparency works.
7. `sudo reboot`, then re-run 1 through 3 and 6.
8. Only after all of the above: disable the old systemd unit, so the two cannot fight.

## Read this before deploying to a new host

While these rules are loaded, a connection direct to `eth0:22` that did not arrive via
sslh does not work. That is inherent to sslh's transparent design, not something this
stack introduces. The consequence: **if the sslh container is down and the rules are still
loaded, port 22 on that interface is unreachable.** Have a second way in — console,
Tailscale/WireGuard, or an sshd on a port that is not in `SSLH_PORTS` — before you deploy
to a host you cannot walk over to.

Rules stay resident after the stack comes down; no teardown is wired into the container
lifecycle, because a stop-time trap only fires on a graceful stop and is not a guarantee
worth building around. Manual teardown:

```
docker compose run --rm sslh-tproxy flush
```
