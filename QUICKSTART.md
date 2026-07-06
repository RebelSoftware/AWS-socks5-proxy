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
./proxy-manage.sh start              # Start proxy
./proxy-manage.sh stop               # Stop local containers
./proxy-manage.sh stop --remote      # Stop local + Fargate immediately
./proxy-manage.sh status             # Show status
./proxy-manage.sh health             # Connectivity test
./proxy-manage.sh logs               # View logs
./proxy-manage.sh info               # Cost/config summary
```

The remote proxy **auto-shuts down** after the configured idle timeout and **auto-wakes** on the next request. See [README.md](./README.md#idle-flow) for details.

## Cleanup

```bash
./proxy-manage.sh stop
aws cloudformation delete-stack --stack-name proxy-fargate-proxy
```

---

**Full documentation:** [README.md](./README.md)
**Deployment guide:** [DEPLOYMENT.md](./DEPLOYMENT.md)
