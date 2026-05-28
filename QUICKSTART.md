# Fargate SOCKS5 Proxy - Getting Started

## What You've Built

A sophisticated two-tier proxy system that:
- ✅ Uses lightweight SOCKS5 proxy (serjs/go-socks5-proxy)
- ✅ Uses local HTTP proxy (Node.js) for browser integration
- ✅ Auto-manages Fargate tasks (starts/stops as needed)
- ✅ Supports persistent connections (WebSockets, SSE, HTTP/2)
- ✅ Costs only $1-3/month for typical intermittent use
- ✅ Configurable auto-shutdown (default 60 min inactivity)
- ✅ IP allowlist and/or username/password security

## Files Overview

| File | Purpose |
|------|---------|
| `setup.sh` | **Start here** - Automated initial setup |
| `proxy-manage.sh` | Daily management (start/stop/status/logs/info) |
| `README.md` | Complete documentation |
| `DEPLOYMENT.md` | Detailed deployment guide |
| `fargate-infrastructure.yaml` | AWS CloudFormation infrastructure |
| `docker-compose.yml` | Docker Compose configuration |
| `async-proxy/proxy.js` | Local Node.js HTTP → SOCKS5 proxy |
| `proxy-orchestrator/orchestrator.py` | Fargate orchestrator service |

## Quick Start (5 minutes)

### Step 1: Run Automated Setup

```bash
chmod +x setup.sh
./setup.sh
```

During setup you'll be prompted to configure:
- **IP allowlist** — Restrict proxy to your IP (recommended for static IPs)
- **Username/password** — SOCKS5 auth (required if IP allowlist is off)
- **Idle timeout** — How long before auto-shutdown (default 60 min)

This will:
- ✓ Verify AWS CLI, Docker, Docker Compose
- ✓ Deploy AWS CloudFormation stack
- ✓ Extract infrastructure details
- ✓ Create `.env` configuration
- ✓ Build Docker image

### Step 2: Start the Proxy

```bash
chmod +x proxy-manage.sh
./proxy-manage.sh start
```

Wait 30-60 seconds for Fargate task to initialize. Output will show:
```
✓ Remote SOCKS5 proxy ready
✓ Public IP: 12.34.56.78
```

### Step 3: Configure Browser

Set proxy in your browser:
- **HTTP proxy:** `localhost:8080`
- **HTTPS proxy:** `localhost:8080`
- **Port:** 8080

### Step 4: Test

Visit http://httpbin.org/ip or run:
```bash
curl -x http://localhost:8080 http://httpbin.org/ip
```

Should show an IP from your chosen AWS region!

## Daily Usage

### When you need the proxy:
```bash
./proxy-manage.sh start
# Wait 30-60 seconds
# Use proxy in browser
```

### When you're done:
```bash
./proxy-manage.sh stop
# Or stop Fargate task immediately:
./proxy-manage.sh stop --remote
# Or just close laptop - Fargate auto-stops after configured idle timeout
```

### Monitor status anytime:
```bash
./proxy-manage.sh status
./proxy-manage.sh health
./proxy-manage.sh info
```

## Important Notes

### Architecture

```
Browser (localhost:8080)
    ↓
Local HTTP Proxy (Node.js — async-proxy/proxy.js)
    ├ Routes via SOCKS5 to Fargate task
    └ Monitors orchestrator for endpoint updates
    ↓
Local Orchestrator (Python — proxy-orchestrator/orchestrator.py)
    ├ Manages Fargate task lifecycle
    ├ Detects IP changes, manages security groups
    └ Provides management API on port 5000
    ↓
AWS Fargate SOCKS5 Proxy (serjs/go-socks5-proxy)
    ├ Ephemeral task with public IP
    ├ Optional username/password auth
    └ Auto-stops after configured idle timeout
    ↓
Internet (with your AWS region's IP)
```
    └ Routes via SOCKS5
    ↓
AWS Fargate SOCKS5 Proxy
    ├ Public IP: changes each restart
    └ Auto-stops after 60min idle
    ↓
Internet (international IP)
```

### Costs

**Monthly:** ~$1.20-2.40 for 100 hours usage
- $0.012/hour Fargate compute
- First 1GB data transfer free
- Auto-shutdown saves money on idle

### Auto-Shutdown

- **Happens after:** 60 minutes of no proxy traffic
- **Saves:** Money on idle time
- **Restart:** Just run `./proxy-manage.sh start` again
- **Time to startup:** 30-60 seconds

## Troubleshooting

### Proxy won't start
```bash
./proxy-manage.sh start
# Check output for errors
docker compose logs proxy-orchestrator
```

### Can't connect from browser
1. Check `.env` file is created
2. Verify Docker containers running: `docker compose ps`
3. Test local proxy: `curl http://localhost:8080`
4. Check AWS credentials: `aws sts get-caller-identity`

### Fargate task won't initialize
```bash
# Check task status
aws ecs list-tasks --cluster proxy-cluster --desired-status RUNNING

# View logs
aws logs tail /ecs/proxy-socks5-proxy --follow
```

### IP keeps changing
- That's normal! Each time you restart, Fargate gets a new public IP
- Local proxy auto-detects and reconfigures itself
- Browser interface stays at `localhost:8080` (never changes)

## Cleanup

To remove everything:
```bash
# Stop proxy
./proxy-manage.sh stop

# Delete AWS resources
aws cloudformation delete-stack --stack-name proxy-fargate-proxy
```

## Next Steps

1. **Run setup.sh** to deploy infrastructure
2. **Run proxy-manage.sh start** to launch
3. **Configure browser proxy** to localhost:8080
4. **Test** at httpbin.org/ip
5. **Set browser as daily tool** for when you need international IP

## Reference

```bash
./proxy-manage.sh start    # Start proxy
./proxy-manage.sh stop     # Stop proxy
./proxy-manage.sh status   # Show status
./proxy-manage.sh logs     # View logs
./proxy-manage.sh info     # Show costs and config
./proxy-manage.sh health   # Health check
```

## Documentation

- **README.md** - Full documentation
- **DEPLOYMENT.md** - Detailed deployment steps
- **fargate-infrastructure.yaml** - Infrastructure as Code

---

**You're ready to go! Start with `./setup.sh`**
