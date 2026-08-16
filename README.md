# AWS Fargate SOCKS5 Proxy

**Ephemeral proxy infrastructure — pay only when you need it.**

A local HTTP proxy that tunnels traffic through a SOCKS5 proxy running on an AWS
Fargate task with a public IP from your chosen region. The Fargate task runs
**only while in use**: it shuts down after an idle timeout and wakes automatically
on the next request.

**This is not a VPN.** Pair it with a per-site proxying tool (e.g. FoxyProxy) to
route selected websites through the proxy.

| | |
|---|---|
| **Cost** | ~$1–3/month (100–200 hrs of use) |
| **Setup** | ~5 minutes (`setup.sh`) |
| **Startup** | 30–60 seconds (Fargate wake) |
| **Security** | IP allowlist, SOCKS5 auth, optional local proxy auth |
| **Maintenance** | start/stop only — IP changes are handled automatically |

---

## Quick Start

```bash
./setup.sh                            # deploy AWS infra + write .env (asks about security, idle timeout, reaper)
./proxy-manage.sh start               # start local proxy (remote starts on first use)
curl -x http://localhost:8080 http://httpbin.org/ip  # test
```

[QUICKSTART.md](./QUICKSTART.md) has the step-by-step; [DEPLOYMENT.md](./DEPLOYMENT.md)
covers manual deployment.

---

## Architecture

```
Browser / LAN device → localhost:8080
   │ HTTP
async-proxy/proxy.js (Node)          local HTTP proxy
   │ polls /status · wakes on demand · state machine idle → waking → active
   │ SOCKS5 (port 1080)
proxy-orchestrator (Python/Flask)    task lifecycle, idle shutdown, SG updates
   │ boto3 (ECS / EC2)
AWS Fargate task (serjs/go-socks5-proxy)   public IP — OFF when idle
   │
Internet (your AWS region's IP)
```

### Idle flow

No traffic for `TASK_IDLE_TIMEOUT_MINUTES` → the orchestrator stops the Fargate
task → `proxy.js` notices the missing endpoint and enters `idle` → the next browser
request triggers `POST /wake` → a new task starts (with a **new public IP**) →
`proxy.js` picks up the new endpoint and resumes routing. The browser always uses
`localhost:8080` — no reconfiguration needed.

### Reaper (cost guard)

The orchestrator handles activity-based idle shutdown. As a belt-and-braces
safety net, an AWS-side **reaper** Lambda force-stops any task older than
`ReaperTimeoutMinutes` (default 120, `0` disables — prompted for by `setup.sh`).
If this machine dies while a task is running, no traffic can flow without the
local proxy, so an old task is certainly abandoned — the reaper stops it before
it quietly runs up a bill.

See [fargate-proxy-architecture.md](./fargate-proxy-architecture.md) for details.

### Start without the remote task

`AUTO_START_REMOTE` (default `false`) controls whether `start` also launches the
remote Fargate task. When off, the local containers start alone and the remote
starts only on demand:

- `./proxy-manage.sh start --no-remote` / `--remote` — force it off/on for one run
- `docker exec proxy-orchestrator curl -X POST http://localhost:5000/start` — start it now
- any traffic through `localhost:8080` wakes the remote automatically

The value is baked into the orchestrator container at creation and survives
restarts/reboots — only container recreation changes it (`./proxy-manage.sh status`
shows the active value).

### Network exposure & security

- The HTTP proxy is **localhost-only by default** (`PROXY_BIND_ADDRESS=127.0.0.1`);
  set it to `0.0.0.0` only to share the proxy with LAN devices.
- The orchestrator API (port 5000) is **not published on the host** — it is
  unauthenticated and must stay internal (`docker exec proxy-orchestrator curl -s
  http://localhost:5000/status`).
- An exposed proxy is an **open proxy**: any request it receives can wake the
  remote Fargate task (cost). If you expose `8080`, enable local proxy auth
  (`LOCAL_REQUIRE_AUTH` — checked **before** the wake path, so unauthorized
  probes get `407`) and/or restrict it with a firewall.
- Keep `TASK_IDLE_TIMEOUT_MINUTES` reasonable (e.g. `60`); with a very short
  timeout each stray probe spawns a brand-new task.
- **LAN devices:** set `PROXY_BIND_ADDRESS=0.0.0.0`, open port 8080 in the
  firewall (`sudo ufw allow 8080/tcp`), and enable `LOCAL_REQUIRE_AUTH`; devices
  use `http://<your-lan-ip>:8080`. If LAN devices have different public IPs,
  the IP allowlist may block them — disable it and rely on local + SOCKS5 auth
  instead.
- **Firewall caveat:** Docker-published ports bypass normal UFW rules — see
  [HARDENING.md](./HARDENING.md) before relying on a host firewall.

---

## Daily Usage

```bash
./proxy-manage.sh start              # start local proxy (remote starts on demand)
./proxy-manage.sh start --remote     # also start the remote Fargate task now
./proxy-manage.sh stop               # stop local containers (remote idles out)
./proxy-manage.sh stop --remote      # stop local + remote immediately
./proxy-manage.sh status             # status, wake state, idle time, public IP
./proxy-manage.sh health             # connectivity test
./proxy-manage.sh logs               # logs (last 200 lines per container)
./proxy-manage.sh info               # config + cost summary
```

**Browser config:** `localhost:8080` on this machine, or
`http://<your-lan-ip>:8080` on other devices (see
[Network exposure](#network-exposure--security)).

---

## Security

Three independent layers, configured during `setup.sh`:

| Layer | What it protects | How it works |
|-------|-----------------|--------------|
| **Local HTTP proxy auth** | Access to `localhost:8080` | HTTP `Proxy-Authorization` Basic header (optional, recommended for LAN) |
| **IP allowlist** | Fargate SOCKS5 port 1080 | AWS security group restricted to your public IP, auto-updated on IP change |
| **SOCKS5 auth** | Upstream tunnel to Fargate | SOCKS5 username/password (RFC 1929) |

`setup.sh` enforces at least one AWS-facing layer (allowlist or SOCKS5 auth).
See [SECURITY-IP-ALLOWLIST.md](./SECURITY-IP-ALLOWLIST.md) for details.

---

## Configuration

All configuration is stored in `.env` (generated by `setup.sh`; reference:
`.env.example`). Key values:

| Variable | Default | Description |
|----------|---------|-------------|
| `TASK_IDLE_TIMEOUT_MINUTES` | 60 | Remote auto-shutdown after N min idle (0 = never) |
| `AUTO_START_REMOTE` | `false` | Whether `start` also starts the remote task |
| `PROXY_BIND_ADDRESS` | `127.0.0.1` | Host bind address for the HTTP proxy |
| `IP_ALLOWLIST_ENABLED` | `false` | Restrict Fargate port 1080 to your public IP |
| `DUAL_IP_RETENTION_MINUTES` | 180 | Keep the old IP in the SG during transitions |
| `REQUIRE_AUTH` / `PROXY_USER` / `PROXY_PASSWORD` | — | SOCKS5 auth to Fargate |
| `LOCAL_REQUIRE_AUTH` / `LOCAL_PROXY_USER` / `LOCAL_PROXY_PASSWORD` | — | Auth for the local HTTP proxy |

The reaper timeout is **not** an `.env` value — it is a CloudFormation parameter
(`ReaperTimeoutMinutes`, default 120), prompted for by `setup.sh`.

---

## Costs

| Usage | Monthly cost |
|-------|-------------|
| 50 hrs | ~$0.60 |
| 100 hrs | ~$1.20 |
| 200 hrs | ~$2.40 |

Includes Fargate compute (0.25 vCPU / 0.5 GB), data transfer, the reaper Lambda,
and CloudWatch logs. Ephemeral by design: no minimum, auto-shutdown after idle,
wakes on the next request.

---

## File Guide

| File | Purpose |
|------|---------|
| [QUICKSTART.md](./QUICKSTART.md) | 5-minute quick start |
| [DEPLOYMENT.md](./DEPLOYMENT.md) | Manual deployment & troubleshooting |
| [fargate-proxy-architecture.md](./fargate-proxy-architecture.md) | Architecture deep dive |
| [SECURITY-IP-ALLOWLIST.md](./SECURITY-IP-ALLOWLIST.md) | IP allowlist & auth details |
| [HARDENING.md](./HARDENING.md) | Docker/UFW firewall guide — read before relying on a host firewall |
| [ec2-proxy-setup.md](./ec2-proxy-setup.md) | **Legacy** EC2-based alternative |
| `setup.sh` / `proxy-manage.sh` | Automated deployment / management CLI |
| `fargate-infrastructure.yaml` | CloudFormation template (incl. reaper Lambda) |
| `docker-compose.yml` | Local services |
| `async-proxy/` · `proxy-orchestrator/` | Local proxy (Node) · orchestrator (Python) source |

---

## FAQ

**Do I need to update browser settings each time?**
No — `localhost:8080` is permanent; IP changes are handled automatically.

**Why is the first request after idle slow?**
The Fargate task takes 30–60 seconds to start.

**What if I forget to stop it?**
The remote shuts down after the idle timeout, and the reaper force-stops any
abandoned task (default 120 min) even if the local machine dies.

**Can other devices on my network use it?**
Yes — see [Network exposure](#network-exposure--security).

**What IP/country will I get?**
Whichever AWS region you deploy to.

**Can I customize the SOCKS5 proxy image?**
Yes — see [serjs/socks5-server](https://github.com/serjs/socks5-server).

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Proxy won't start | `docker compose logs`, `aws sts get-caller-identity` |
| Fargate task won't init | `aws ecs list-tasks --cluster proxy-cluster`, CloudWatch logs, SG rules |
| Can't connect locally | `curl http://localhost:8080`, `docker compose ps` |
| Can't connect from another device | `PROXY_BIND_ADDRESS=0.0.0.0` + firewall on 8080 |
| Auth errors | `PROXY_USER`/`PROXY_PASSWORD` match between `.env` and the task definition |
| Task left running (cost) | `./proxy-manage.sh stop --remote`; abandoned tasks are reaped automatically |

See [DEPLOYMENT.md](./DEPLOYMENT.md#troubleshooting) for detailed steps.

