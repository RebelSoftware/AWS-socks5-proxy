# Fargate SOCKS5 Proxy — Quick Start

> A lightweight HTTP proxy that tunnels through an ephemeral AWS Fargate SOCKS5 proxy. See [README.md](./README.md) for full documentation, architecture, and configuration reference.

## Quick Start (5 minutes)

### Step 1: Run Automated Setup

```bash
chmod +x setup.sh
./setup.sh
```

You'll be prompted for:
- **IP allowlist** — Restrict proxy to your IP (recommended for static IPs)
- **Username/password** — SOCKS5 auth (required if IP allowlist is off)
- **Local proxy auth** — Optional password for the local HTTP proxy itself
- **Idle timeout** — How long before auto-shutdown (default 60 min)

### Step 2: Start the Proxy

```bash
chmod +x proxy-manage.sh
./proxy-manage.sh start
```

Wait ~30-60 seconds for Fargate to initialize. Output will show:
```
✓ Remote SOCKS5 proxy ready
✓ Public IP: 12.34.56.78
```

**Don't need the remote right now?** Start the local service without the Fargate task
(saves cost until you actually use it):

```bash
./proxy-manage.sh start --no-remote
```

Remote auto-start is **off by default** (`AUTO_START_REMOTE=false`), so a plain
`./proxy-manage.sh start` also keeps the remote off. Use `./proxy-manage.sh start --remote`
to auto-start it. The remote will start on demand when traffic hits `localhost:8080`, or run
`docker exec proxy-orchestrator curl -X POST http://localhost:5000/start` to start it manually.

### Step 3: Configure Browser

| Setting | Value |
|---------|-------|
| HTTP proxy | `localhost:8080` |
| HTTPS proxy | `localhost:8080` |
| Port | 8080 |
| Auth (if enabled) | `http://user:pass@localhost:8080` |

### Step 4: Test

```bash
curl -x http://localhost:8080 http://httpbin.org/ip
```

Should show an IP from your chosen AWS region!

---

## Daily Usage

```bash
./proxy-manage.sh start              # Start proxy (remote per AUTO_START_REMOTE)
./proxy-manage.sh start --no-remote  # Start local proxy without auto-starting remote
./proxy-manage.sh start --remote     # Start local proxy + auto-start remote Fargate task
./proxy-manage.sh stop               # Stop local containers
./proxy-manage.sh stop --remote      # Stop local + Fargate immediately
./proxy-manage.sh status             # Show status
./proxy-manage.sh health             # Connectivity test
./proxy-manage.sh logs               # View logs
./proxy-manage.sh info               # Cost/config summary
```

The remote proxy **auto-shuts down** after the configured idle timeout and **auto-wakes** on the next request. See [README.md](./README.md#idle-flow) for details.

> **Security:** the proxy is bound to **localhost by default** (`PROXY_BIND_ADDRESS`
> in `.env`), and the orchestrator API (5000) is **not published** on the host.
> If your host is reachable from the internet or LAN, do **not** set
> `PROXY_BIND_ADDRESS=0.0.0.0` unless you actually need LAN devices — an open proxy
> on `8080` gets hit by port scanners, which wakes the remote Fargate task and
> costs money. See [README.md](./README.md#network-exposure--security).

## Cleanup

```bash
./proxy-manage.sh stop
aws cloudformation delete-stack --stack-name proxy-fargate-proxy
```

---

**Full documentation:** [README.md](./README.md)
**Deployment guide:** [DEPLOYMENT.md](./DEPLOYMENT.md)
