# Security Configuration — IP Allowlist & Authentication

> Three independent security layers. See [README.md](./README.md#security) for
> the config table.

| Layer | Protects | Best for |
|-------|----------|----------|
| **Local HTTP proxy auth** | `localhost:8080` | LAN / multi-device setups |
| **IP allowlist** (AWS SG) | Fargate SOCKS5 port 1080 | Static IP environments |
| **SOCKS5 auth** | Upstream tunnel | Dynamic IPs, defense-in-depth |

`setup.sh` requires at least one AWS-facing layer (allowlist or SOCKS5 auth).
Local proxy auth is optional and independent.

---

## IP Allowlist Mode

The Fargate task's security group allows only your public IP (`/32`). The
orchestrator re-detects your IP every 60 seconds and updates the security group
when it changes. **Dual-IP retention** keeps the old IP for
`DUAL_IP_RETENTION_MINUTES` (default 180) so existing connections survive the
transition:

```
Old IP: 203.0.113.42
  T+0    IP changes to 203.0.113.99 → SG allows both
  T+180m old IP removed automatically
```

If your IP changes mid-session and detection lags:

```bash
docker exec proxy-orchestrator curl -s -X POST http://localhost:5000/ip/check
```

Check the current state:

```bash
docker exec proxy-orchestrator curl -s http://localhost:5000/ip/status | jq '.'
```

---

## SOCKS5 Authentication

RFC 1929 username/password between `proxy.js` and the Fargate task
(`REQUIRE_AUTH` + `PROXY_USER` / `PROXY_PASSWORD`). Can be combined with the
allowlist for defense-in-depth.

## Local Proxy Authentication

HTTP `Proxy-Authorization: Basic` on the local proxy (`LOCAL_REQUIRE_AUTH` +
`LOCAL_PROXY_USER` / `LOCAL_PROXY_PASSWORD`). Checked **before** the wake path,
so unauthorized probes get `407` and cannot wake the remote task.

---

## Automatic IP Management

1. On start (and every 60 s) the orchestrator detects the local public IP —
   via multiple echo services (`IP_ECHO_SERVICES`) for redundancy.
2. If the IP changed, it adds the new `/32` rule to the security group and
   stores the previous IP with a timestamp.
3. When the previous IP is older than `DUAL_IP_RETENTION_MINUTES`, the old
   rule is revoked automatically.

Inbound rules on port 1080 look like:

```
Rule 1 (current IP):  203.0.113.99/32  — added now
Rule 2 (previous IP): 203.0.113.42/32  — auto-removed after the retention window
```

Having **two rules during a transition is expected and correct**.

---

## Troubleshooting

### Proxy stops working after my IP changed

1. `docker logs proxy-orchestrator | grep "IP changed"` — is detection working?
2. `docker exec proxy-orchestrator curl -s -X POST http://localhost:5000/ip/check`
3. `docker exec proxy-orchestrator curl -s https://checkip.amazonaws.com` —
   can the container reach the IP echo services?

### Two rules on port 1080

Expected during a transition (old + new IP); the old rule is removed
automatically after the retention period.

```bash
aws ec2 describe-security-group-rules \
  --filters Name=group-id,Values=$SG_ID \
  --query 'SecurityGroupRules[?FromPort==`1080` && IsEgress==`false`]'
```

### `local_public_ip` shows null

Allowlist is disabled, detection failed, or the container can't reach the echo
services / lacks EC2 permissions.

## Environment Variables

Security-specific variables (all in `.env`, see
[README.md](./README.md#configuration)):

| Variable | Default | Purpose |
|----------|---------|---------|
| `IP_ALLOWLIST_ENABLED` | `false` | Enable IP allowlist mode |
| `CLIENT_SECURITY_GROUP_ID` | (required) | SG to update with your IP |
| `DUAL_IP_RETENTION_MINUTES` | `180` | Minutes to keep the old IP |
| `LOCAL_REQUIRE_AUTH` | `false` | Enable local HTTP proxy auth |

---

## Disabling the allowlist

Re-run `./setup.sh` and answer "n" to the allowlist prompt (or pass
`IPAllowlistEnabled=false` when updating the stack manually), then update
`.env` and restart:

```bash
IP_ALLOWLIST_ENABLED=false
./proxy-manage.sh stop
./proxy-manage.sh start
```

**Warning:** without the allowlist, only SOCKS5 auth protects the Fargate
port — and `setup.sh` enforces it.

---

## Testing

`test-ip-allowlist.sh` exercises dual-IP retention using RFC 5737 test IPs
(`203.0.113.x`) without touching your real IP. Run it after enabling the
allowlist.
