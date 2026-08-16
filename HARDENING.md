# Hardening Guide — Docker, UFW & Firewalls

> **Read this first, even if you skip the rest:**
> Docker-published ports are **NOT** protected by normal `ufw allow/deny`
> rules. A host can show a perfectly healthy firewall (`ufw status`) while its
> Dockerized services are open to the entire internet. This page explains why,
> how to fix it, and what this project does about it.

---

## The trap: Docker routes around your firewall's INPUT rules

When Docker publishes a port (`ports:` in compose, `-p` in `docker run`), it:

1. Inserts **its own iptables rules** that DNAT traffic from the published
   port to the container's internal IP.
2. Because the packet now terminates *inside a container*, it travels the
   `FORWARD` chain — **not `INPUT`**, where `ufw allow/deny` rules live.
3. Adds an explicit `ACCEPT` for every published port in its `DOCKER` chain.

So `ufw deny 8080` is meaningless for a Docker-published 8080: the packet
never asks UFW's INPUT rules. Worse, Docker inserts its jumps **above** UFW's
chains in `FORWARD` (and container restarts can re-order them), so even
UFW *route* rules and UFW's `FORWARD` DROP policy can be outrun by Docker's
per-port ACCEPTs.

**The failure is silent.** `ufw status` looks correct, your rules exist, and
the port is still open. The only proof is testing from an outside network.

```bash
# From a device on a DIFFERENT network (e.g. phone on mobile data):
curl -m 5 http://<public-ip>:8080    # if this answers, it is open — no matter
                                     # what ufw status says
```

## The fix: the DOCKER-USER chain

Docker jumps to a chain named `DOCKER-USER` **first** in `FORWARD` and
**never manages its contents**. It is the single place where admin
restrictions on published ports actually take effect. This is Docker's own
documented hook — it's just buried in the docs.

Rules (order matters — allowances first, catch-all DROP last):

```bash
iptables -F DOCKER-USER                       # Docker never touches it; rebuild freely

# 1) Return traffic for connections containers started.
#    WITHOUT THIS, outbound traffic breaks: replies from the internet arrive
#    on the WAN interface and would be caught by the DROP below
#    (symptom: "Temporary failure resolving ..." on apt, APIs failing).
iptables -A DOCKER-USER -i eno1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 2) One public port — e.g. HTTPS from anywhere:
iptables -A DOCKER-USER -i eno1 -p tcp -m tcp --dport 443 -j ACCEPT

# 3) LAN can reach every Docker-published port (e.g. the proxy on 8080):
iptables -A DOCKER-USER -i eno1 -s 10.1.1.0/24 -j ACCEPT

# 4) Everything else arriving from the internet:
iptables -A DOCKER-USER -i eno1 -j DROP
```

`-i eno1` limits all of this to internet ingress — container egress and
inter-container traffic are untouched.

**Persistence:** Docker may rebuild its own rules on daemon restarts, so
re-apply after every Docker start. This project's deployment uses a systemd
drop-in:

```ini
# /etc/systemd/system/docker.service.d/docker-firewall.conf
[Service]
ExecStartPost=/usr/local/sbin/docker-firewall.sh
```

The script flushes and rebuilds `DOCKER-USER` idempotently. Both it and a
complete UFW + DOCKER-USER lockdown installer are kept **outside this repo**
(as host-specific configuration): `/home/docker/ufw-lan-rules.sh`.

> The same trap exists with firewalld and with any tool that manages
> iptables — the underlying truth is always: *published Docker ports are
> governed by `FORWARD` rules, host ports by `INPUT` rules.*

## What this project already does about it

| Concern | Behavior |
|---|---|
| HTTP proxy (8080) | Bound to **localhost by default** (`PROXY_BIND_ADDRESS=127.0.0.1`). The Docker publish itself is loopback-only unless you opt in — so even without any firewall, the proxy isn't internet-reachable. |
| Orchestrator API (5000) | **Not published at all** — only reachable on the compose network / inside the container. It is unauthenticated and must stay internal. |
| LAN opt-in | `PROXY_BIND_ADDRESS=0.0.0.0` exposes the proxy to the LAN. Pair with `LOCAL_REQUIRE_AUTH=true` (checked **before** the wake path, so unauthorized probes get `407` and cannot wake the remote task). |
| Fargate side | IP allowlist (security group), SOCKS5 username/password, and the reaper Lambda that force-stops abandoned tasks. |
| Healthchecks | Internal only (container→container or container→localhost). |

See [README.md](./README.md#network-exposure--security) and
[SECURITY-IP-ALLOWLIST.md](./SECURITY-IP-ALLOWLIST.md) for the project-level
configuration.

## Habits that keep this from biting

1. **Publish on loopback by default** — `"127.0.0.1:8080:8080"` unless a port
   genuinely needs LAN/internet access.
2. **Audit with Docker, not just UFW** — `docker ps --format '{{.Names}} {{.Ports}}'`
   is the real list of exposed services.
3. **Check both firewall views** — host processes: `ufw status verbose`;
   Docker-published ports: `iptables -S DOCKER-USER`.
4. **Verify from outside** — a phone on mobile data is the cheapest external
   probe you own.
5. **Prefer a reverse proxy** (Traefik/Caddy) so only 80/443 are ever
   world-reachable; keep everything else on loopback.
