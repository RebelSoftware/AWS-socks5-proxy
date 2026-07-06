# Fargate SOCKS5 Proxy Architecture

A two-tier proxy architecture: a local Node.js HTTP proxy + Python orchestrator manage ephemeral Fargate SOCKS5 instances for cost-effective international IP proxying. The remote proxy shuts down when idle and wakes automatically on the next request.

> See [README.md](./README.md) for configuration reference, quick start, and daily usage.

## Architecture Overview

```
┌─────────────────────┐
│   Your Browser      │      Any device on LAN
│  (any app)          │
└──────────┬──────────┘
           │ HTTP/HTTPS proxy
           │ localhost:8080 (or LAN IP:8080)
           │ [Proxy-Authorization: Basic] — optional local auth
           │
    ┌──────▼──────────────────────────────────┐
    │  async-proxy/proxy.js (Node.js)         │
    │  Local HTTP → SOCKS5 Proxy             │
    │                                         │
    │  State machine: idle → waking → active  │
    │  ✓ Routes HTTP/HTTPS via SOCKS5 tunnel  │
    │  ✓ Polls orchestrator for endpoint IP   │
    │  ✓ Triggers wake via POST /wake         │
    │  ✓ Supports WebSocket, SSE, HTTP/2      │
    │  ✓ SOCKS5 auth (upstream to Fargate)    │
    │  ✓ Local auth (Proxy-Authorization)     │
    └──────┬──────────────────────────────────┘
           │ Reads endpoint from /status API
           │ Sends POST /wake when idle
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
    │  ✓ Polls proxy health for idle detection│
    │  ✓ Enters idle_mode, stops remote task  │
    │  ✓ Exposes REST API on port 5000        │
    └──────┬──────────────────────────────────┘
           │ AWS SDK (boto3)
           │
    ┌──────▼──────────────────────────────────┐
    │  AWS ECS Fargate       ─── OFF when idle │
    │  ┌──────────────────────────────────┐   │
    │  │ serjs/go-socks5-proxy            │   │
    │  │ (SOCKS5 proxy container)         │   │
    │  │  PROXY_USER / PROXY_PASSWORD     │   │
    │  │  REQUIRE_AUTH                    │   │
    │  └──────────────────────────────────┘   │
    │  Auto-stops after idle timeout          │
    │  CloudWatch Logs for activity tracking  │
    └──────────────────────────────────────────┘
```

## Idle / Wake Flow

```
1. Browser sends last request → lastActivityAt timestamp set
2. No traffic for IDLE_TIMEOUT_MINUTES → orchestrator detects idle
3. Orchestrator calls stop_task() → Fargate task stops
4. proxy.js detects no endpoint → enters 'idle' state
5. Next browser request hits proxy.js → returns 503 + triggers POST /wake
6. Orchestrator receives /wake → starts new Fargate task
7. proxy.js polls /status → gets new IP → enters 'active' state
8. Browser retries → request routed through SOCKS5 tunnel
```

## Key Features

| Feature | Benefit |
|---------|---------|
| **Stable Local Interface** | Browser always uses `localhost:8080` — no IP changes |
| **Auto-Orchestration** | Starts/stops Fargate automatically |
| **Idle Shutdown + Auto-Wake** | Remote stops after inactivity, wakes on next request |
| **Persistent Connections** | Full WebSocket, SSE, HTTP/2 support |
| **Cost Optimized** | ~$1-3/month for 100 hours usage |
| **Three Security Layers** | Local auth + IP allowlist + SOCKS5 auth |
| **IP Change Handling** | Auto-detects IP changes, dual-IP retention |

## Cost Breakdown

See [README.md](./README.md#costs).

---

## Components

### 1. Local HTTP Proxy (`async-proxy/proxy.js`)
- **Language:** Node.js
- **Role:** Accepts HTTP/HTTPS requests, tunnels them through SOCKS5
- **Key behavior:**
  - Polls the orchestrator's `/status` endpoint every 30s for current Fargate task IP
  - Tracks `lastActivityAt` timestamp on each request for idle detection
  - State machine: `idle` (no endpoint) → `waking` (waiting for Fargate) → `active` (routing traffic)
  - Calls `POST /wake` on orchestrator when transitioning from idle
  - Falls back to idle after 120s timeout if no endpoint appears
- **Upstream auth:** SOCKS5 username/password via `PROXY_USER`/`PROXY_PASSWORD`
- **Local auth:** HTTP `Proxy-Authorization: Basic` via `LOCAL_PROXY_USER`/`LOCAL_PROXY_PASSWORD`

### 2. Orchestrator (`proxy-orchestrator/orchestrator.py`)
- **Language:** Python 3, Flask web server
- **Role:** Manages the lifecycle of Fargate SOCKS5 tasks
- **Key responsibilities:**
  - Starts new Fargate tasks via `ecs.run_task()`
  - Monitors running tasks and extracts public IP from ENI attachments
  - Polls `http://http-proxy:8081/health` for `activeConnections` and `lastActivityAt`
  - Shuts down remote task when idle for `IDLE_TIMEOUT_MINUTES`
  - Enters `idle_mode` after shutdown — does not restart the task
  - Receives `POST /wake` to start a new task on demand
  - `POST /stop` sets `explicit_stop` to prevent auto-wake
  - Manages security group rules for IP allowlist (add/remove IPs)
  - Dual-IP retention: keeps old IP in SG for 180 min during transitions
  - Exposes REST API: `/status`, `/start`, `/stop`, `/wake`, `/ip/check`, `/ip/status`

### 3. Fargate Task (`serjs/go-socks5-proxy`)
- **Image:** `serjs/go-socks5-proxy:latest`
- **Type:** AWS Fargate (serverless container)
- **Resources:** 0.25 vCPU, 512 MB RAM
- **Networking:** Public subnet, auto-assign public IP
- **Auth:** Accepts `PROXY_USER`, `PROXY_PASSWORD`, `REQUIRE_AUTH` env vars
- **Logging:** CloudWatch Logs (streamed to `/ecs/proxy-go-socks5-proxy`)

### 4. Infrastructure (`fargate-infrastructure.yaml`)
- CloudFormation template deploying: VPC, subnets, IGW, security groups, ECS cluster, task definition, log group, auto-shutdown Lambda + schedule

---

## Security Architecture

```
┌──────────────────────────────────────────────┐
│  Layer 1: Local Proxy Auth (HTTP Basic)      │
│  ──────────────────────────────────────────── │
│  Optional: LOCAL_REQUIRE_AUTH=true            │
│  Protects the local HTTP proxy port 8080      │
│  Ideal for LAN/multi-device deployments       │
├──────────────────────────────────────────────┤
│  Layer 2: IP Allowlist (AWS Security Group)   │
│  ──────────────────────────────────────────── │
│  When enabled: SG only allows port 1080       │
│  from your detected public IP (/32)           │
├──────────────────────────────────────────────┤
│  Layer 3: SOCKS5 Auth (Username/Password)     │
│  ──────────────────────────────────────────── │
│  PROXY_USER/PROXY_PASSWORD required           │
│  for SOCKS5 handshake to Fargate              │
└──────────────────────────────────────────────┘
```

## Data Flow

```
1. Browser sends HTTP request to localhost:8080
   (with Proxy-Authorization header if local auth enabled)
2. proxy.js checks currentEndpoint (from orchestrator /status)
3. If idle → returns 503 + triggers POST /wake to orchestrator
4. If active → opens SOCKS5 tunnel to Fargate task IP:1080
   (with PROXY_USER/PROXY_PASSWORD if REQUIRE_AUTH=true)
5. Fargate SOCKS5 proxy forwards to target website
6. Response flows back through the same tunnel
7. Browser receives response
```

## Idle Shutdown

The orchestrator drives idle detection — no Lambda required:

| Mechanism | Trigger | Action |
|-----------|---------|--------|
| **Orchestrator** (every 30s) | Polls proxy.js health — no connections + no activity for N minutes | Stops Fargate task, enters `idle_mode` |
| **Proxy auto-wake** | Next browser request while idle | `POST /wake` → orchestrator starts new task |

The idle timeout (`IDLE_TIMEOUT_MINUTES`) is configured in `.env`. Default is 60 minutes.

---

## Related Files

| File | Description |
|------|-------------|
| [README.md](./README.md) | Full documentation (configuration, usage, costs) |
| [QUICKSTART.md](./QUICKSTART.md) | 5-minute quick start |
| [DEPLOYMENT.md](./DEPLOYMENT.md) | Manual deployment guide |
| [SECURITY-IP-ALLOWLIST.md](./SECURITY-IP-ALLOWLIST.md) | Security configuration deep-dive |
| `setup.sh` | Automated deployment script |
| `proxy-manage.sh` | Management CLI |
| `fargate-infrastructure.yaml` | CloudFormation template |
| `docker-compose.yml` | Local services configuration |
| `async-proxy/proxy.js` | Node.js HTTP → SOCKS5 proxy |
| `proxy-orchestrator/orchestrator.py` | Python Fargate orchestrator |

