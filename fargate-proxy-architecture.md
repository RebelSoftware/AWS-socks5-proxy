# Fargate SOCKS5 Proxy Architecture

A two-tier proxy architecture: a local Node.js HTTP proxy + Python orchestrator manage ephemeral Fargate SOCKS5 instances for cost-effective international IP proxying.

## Architecture Overview

```
┌─────────────────────┐
│   Your Browser      │
│  (any app)          │
└──────────┬──────────┘
           │ HTTP/HTTPS proxy
           │ localhost:8080
           │
    ┌──────▼──────────────────────────────────┐
    │  async-proxy/proxy.js (Node.js)         │
    │  Local HTTP → SOCKS5 Proxy             │
    │                                         │
    │  ✓ Routes HTTP/HTTPS via SOCKS5 tunnel  │
    │  ✓ Polls orchestrator for endpoint IP   │
    │  ✓ Supports WebSocket, SSE, HTTP/2      │
    │  ✓ SOCKS5 auth (PROXY_USER/PASSWORD)    │
    └──────┬──────────────────────────────────┘
           │ Reads endpoint from /status API
           │
    ┌──────▼──────────────────────────────────┐
    │  proxy-orchestrator/orchestrator.py     │
    │  (Python / Flask)                       │
    │                                         │
    │  ✓ Manages Fargate task lifecycle       │
    │  ✓ Starts/stops tasks via AWS ECS API   │
    │  ✓ Detects public IP from task ENI      │
    │  ✓ Manages security group (IP allowlist)│
    │  ✓ Dual-IP retention for IP changes     │
    │  ✓ Exposes REST API on port 5000        │
    └──────┬──────────────────────────────────┘
           │ AWS SDK (boto3)
           │
    ┌──────▼──────────────────────────────────┐
    │  AWS ECS Fargate                        │
    │  ┌──────────────────────────────────┐   │
    │  │ serjs/go-socks5-proxy            │   │
    │  │ (SOCKS5 proxy container)         │   │
    │  │                                  │   │
    │  │ Environment:                     │   │
    │  │  PROXY_USER / PROXY_PASSWORD     │   │
    │  │  REQUIRE_AUTH                    │   │
    │  └──────────────────────────────────┘   │
    │                                          │
    │  Auto-shutdown Lambda monitors idle time │
    │  CloudWatch Logs for activity tracking   │
    └──────────────────────────────────────────┘
```

## Key Features

| Feature | Benefit |
|---------|---------|
| **Stable Local Interface** | Browser always uses `localhost:8080` — no IP changes |
| **Auto-Orchestration** | Starts/stops Fargate automatically |
| **Persistent Connections** | Full WebSocket, SSE, HTTP/2 support |
| **Cost Optimized** | ~$1-3/month for 100 hours usage |
| **Configurable Idle Shutdown** | Auto-terminates after N min (default 60) |
| **Dual Security Layers** | IP allowlist + username/password auth |
| **IP Change Handling** | Auto-detects IP changes, dual-IP retention |

## Cost Breakdown

**Fargate Pricing (running):**
- vCPU: $0.04048/hour × 0.25 = $0.0101/hour
- Memory: $0.004445/hour × 0.5GB = $0.0022/hour
- **Total: ~$0.012/hour (~$0.30/day)**

**For 100 hours/month:** ~$1.20
**For 200 hours/month:** ~$2.40

**Other:** Data transfer, Lambda execution (negligible at this scale)

---

## Components

### 1. Local HTTP Proxy (`async-proxy/proxy.js`)
- **Language:** Node.js
- **Role:** Accepts HTTP/HTTPS requests on `localhost:8080`, tunnels them through SOCKS5
- **Key behavior:** Polls the orchestrator's `/status` endpoint every 30s to get the current Fargate task IP. Reconnects transparently when the IP changes.
- **Auth:** Supports SOCKS5 username/password authentication via `PROXY_USER`/`PROXY_PASSWORD` env vars

### 2. Orchestrator (`proxy-orchestrator/orchestrator.py`)
- **Language:** Python 3, Flask web server
- **Role:** Manages the lifecycle of Fargate SOCKS5 tasks
- **Key responsibilities:**
  - Starts new Fargate tasks when needed via `ecs.run_task()`
  - Monitors running tasks and extracts public IP from ENI attachments
  - Auto-stops stale tasks and starts fresh ones if connection fails
  - Manages security group rules for IP allowlist (add/remove IPs)
  - Dual-IP retention: keeps old IP in SG for 180 min during transitions
  - Exposes REST API: `/status`, `/start`, `/stop`, `/ip/check`, `/ip/status`

### 3. Fargate Task (`serjs/go-socks5-proxy`)
- **Image:** `serjs/go-socks5-proxy:latest`
- **Type:** AWS Fargate (serverless container)
- **Resources:** 0.25 vCPU, 512 MB RAM
- **Networking:** Public subnet, auto-assign public IP
- **Auth:** Accepts `PROXY_USER`, `PROXY_PASSWORD`, `REQUIRE_AUTH` env vars
- **Logging:** CloudWatch Logs (streamed to `/ecs/proxy-socks5-proxy`)

### 4. Auto-Shutdown Lambda
- **Trigger:** EventBridge rule every 15 minutes
- **Logic:** Checks CloudWatch Logs for recent activity. If no logs within `IDLE_TIMEOUT_MINUTES`, stops the task via `ecs.stop_task()`
- **Cost:** Negligible (Lambda free tier)

### 5. Infrastructure (`fargate-infrastructure.yaml`)
- CloudFormation template deploying: VPC, subnets, IGW, security groups, ECS cluster, task definition, log group, auto-shutdown Lambda + schedule

---

## Security Architecture

```
┌─────────────────────────────────────────────┐
│  Layer 1: IP Allowlist (Security Group)     │
│  ─────────────────────────────────────────── │
│  When enabled: SG only allows port 1080     │
│  from your detected public IP (/32)         │
│                                              │
│  When disabled: SG allows 0.0.0.0/0         │
│  (relies on Layer 2 for security)           │
└─────────────────────────────────────────────┘
                       +
┌─────────────────────────────────────────────┐
│  Layer 2: SOCKS5 Auth (Username/Password)   │
│  ─────────────────────────────────────────── │
│  When enabled: PROXY_USER/PROXY_PASSWORD    │
│  required for SOCKS5 handshake              │
│                                              │
│  Enforced by setup.sh: if Layer 1 is off,   │
│  Layer 2 is mandatory                       │
└─────────────────────────────────────────────┘
```

---

## Data Flow

```
1. Browser sends HTTP request to localhost:8080
2. proxy.js checks currentEndpoint (from orchestrator /status)
3. proxy.js opens SOCKS5 tunnel to Fargate task IP:1080
   (with PROXY_USER/PROXY_PASSWORD if REQUIRE_AUTH=true)
4. Fargate SOCKS5 proxy forwards to target website
5. Response flows back through the same tunnel
6. Browser receives response
```

---

## Idle Shutdown

Two mechanisms ensure cost-efficient auto-shutdown:

| Mechanism | Trigger | Action |
|-----------|---------|--------|
| **Lambda** (every 15 min) | No CloudWatch logs for N minutes | Stops Fargate task |
| **Orchestrator** | Connection errors exceed threshold | Stops and restarts task |

The idle timeout (`TASK_IDLE_TIMEOUT_MINUTES`) is configured during `setup.sh` and can be set to any value (0 disables auto-shutdown).

---

## Configuration Variables

| Variable | Where Set | Purpose |
|----------|-----------|---------|
| `TASK_IDLE_TIMEOUT_MINUTES` | `.env`, CF template | Auto-shutdown delay |
| `IP_ALLOWLIST_ENABLED` | `.env`, CF template | Enable SG IP restriction |
| `CLIENT_SECURITY_GROUP_ID` | `.env` | SG to update with client IP |
| `DUAL_IP_RETENTION_MINUTES` | `.env`, CF template | Keep old IP during transition |
| `REQUIRE_AUTH` | `.env`, CF template | Enable SOCKS5 auth |
| `PROXY_USER` | `.env`, CF template | SOCKS5 username |
| `PROXY_PASSWORD` | `.env`, CF template | SOCKS5 password |

---

## Related Files

| File | Description |
|------|-------------|
| [QUICKSTART.md](./QUICKSTART.md) | 5-minute quick start |
| [README.md](./README.md) | Full documentation |
| [DEPLOYMENT.md](./DEPLOYMENT.md) | Deployment & troubleshooting |
| [SECURITY-IP-ALLOWLIST.md](./SECURITY-IP-ALLOWLIST.md) | Security configuration |
| `setup.sh` | Automated deployment script |
| `proxy-manage.sh` | Management CLI |
| `fargate-infrastructure.yaml` | CloudFormation template |
| `docker-compose.yml` | Local services |
| `async-proxy/proxy.js` | Node.js HTTP → SOCKS5 proxy |
| `proxy-orchestrator/orchestrator.py` | Python Fargate orchestrator |

