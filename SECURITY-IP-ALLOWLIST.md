# Security Configuration — IP Allowlist & Authentication

> The proxy supports **three independent security layers**. See [README.md](./README.md#security) for the config table and [DEPLOYMENT.md](./DEPLOYMENT.md) for deployment commands.

| Layer | What it protects | Best For |
|-------|-----------------|----------|
| **Local HTTP proxy auth** | Access to `localhost:8080` | LAN/multi-device deployments |
| **IP Allowlist** (AWS SG) | Fargate SOCKS5 port 1080 | Office/static IP environments |
| **SOCKS5 auth** | Upstream proxy connection | Dynamic IPs, defense-in-depth |

During `setup.sh`, you must enable at least one of the AWS-facing layers (IP allowlist or SOCKS5 auth). Local proxy auth is optional and independent.

---

## Security Model

### IP Allowlist Mode (Recommended for Static IPs)

Security group restricted to your client's public IP (`/32` CIDR). Automatic IP change detection and security group updates. Dual-IP retention: maintains both old and new IPs for 180 minutes during transitions.

**Security guarantees:**
- ✅ Only your IP can reach the proxy port (1080)
- ✅ Automatic recovery if your IP changes mid-session
- ✅ Dual-IP retention prevents dropped connections during IP transitions

### SOCKS5 Username/Password Authentication

SOCKS5 username/password auth (RFC 1929) between the local HTTP proxy and the Fargate task. Credentials passed as environment variables. Can be combined with IP allowlist for defense-in-depth.

### Local HTTP Proxy Authentication

HTTP `Proxy-Authorization: Basic` header required to use the local proxy at all. Independent of the other layers. Ideal for LAN deployments where untrusted devices share the network. See [README.md](./README.md#security) for configuration.

---

## Monitoring IP Changes

### Check Current IP Status

```bash
# View orchestrator status with IP information
curl http://localhost:5000/status | jq '.'

# Example output:
# {
#   "status": "running",
#   "remote_ip": "54.123.45.67",
#   "local_public_ip": "203.0.113.42",
#   "ip_allowlist_enabled": true,
#   "previous_ip": null,
#   ...
# }
```

### Check IP Allowlist Details

```bash
curl http://localhost:5000/ip/status | jq '.'

# Example output:
# {
#   "current_local_ip": "203.0.113.42",
#   "previous_local_ip": null,
#   "dual_ip_retention_minutes": 180,
#   "ip_allowlist_enabled": true
# }
```

### Manual IP Check (if IP changed mid-session)

If your IP changes and the automatic detection doesn't pick it up:

```bash
curl -X POST http://localhost:5000/ip/check | jq '.'

# This will:
# 1. Detect your new current public IP
# 2. Add it to the security group
# 3. Keep old IP for 180 minutes (for connection continuity)
# 4. Return status of the update
```

---

## How It Works: Automatic IP Management

### Initialization Phase
```
1. Orchestrator starts
2. Detects local machine's public IP (tries multiple services for redundancy)
3. Calls AWS EC2 to get current SG rules
4. If new IP detected → adds ingress rule for new IP/32
5. Tracks previous IP with timestamp for dual-IP retention
```

### Monitoring Phase (every 60 seconds)
```
1. Check if IP has changed since last check
2. If different:
   - Add new IP to security group
   - Store previous IP with timestamp
3. If previous IP is older than 180 minutes:
   - Remove the old IP rule from security group
4. Log all changes
```

### Transition Handling (Dual-IP Mode)
```
Old IP: 203.0.113.42 (active for 5 hours)
         ↓ User's office IP changes
New IP: 203.0.113.99

Timeline:
  T+0:    New IP detected, SG now allows both 42 and 99
  T+90m:  Both IPs still in SG (existing connections on 42 work fine)
  T+180m: Old IP (42) automatically removed, only 99 in SG
```

---

## Security Group Rule Structure

When IP allowlist is enabled, the security group will have rules like:

```
Inbound Rules:
  Port: 1080 (SOCKS5)
  Protocol: TCP
  
  Rule 1 (Current IP):
    CIDR: 203.0.113.42/32
    Description: SOCKS5 client IP (added 2024-05-23T14:30:00)
  
  Rule 2 (Previous IP - if within retention period):
    CIDR: 203.0.113.99/32
    Description: SOCKS5 client IP (added 2024-05-23T12:15:00)
    [This rule will auto-remove after 180 minutes]
```

---

## Troubleshooting

### IP Not Updating

**Symptom:** Proxy was working, then connection refused after IP change

**Solution:**

1. Verify orchestrator is detecting IP changes:
   ```bash
   docker logs socks5-orchestrator | tail -50
   ```
   Look for: `"Local public IP changed: X.X.X.X -> Y.Y.Y.Y"`

2. Manually trigger IP check:
   ```bash
   curl -X POST http://localhost:5000/ip/check
   ```

3. Check orchestrator can reach IP detection services:
   ```bash
   # From orchestrator container:
   docker exec socks5-orchestrator curl -v https://checkip.amazonaws.com
   ```

### Multiple IPs in SG (Expected)

During IP transitions, you'll see multiple rules. This is **expected and correct**. The system:
- Adds new IP immediately
- Keeps old IP for 180 minutes for connection continuity
- Automatically removes old IP after retention period

To verify rules:
```bash
aws ec2 describe-security-groups \
  --group-ids sg-0123456789abcdef0 \
  --region us-east-1 | jq '.SecurityGroups[0].IpPermissions[]'
```

### Static IPs Not Detecting

If orchestrator shows `null` for `local_public_ip`:

1. Check CloudWatch logs (orchestrator container)
2. Verify container can reach external IP services:
   ```bash
   docker exec socks5-orchestrator curl https://api.ipify.org
   ```
3. Verify AWS credentials for EC2 API access

## Environment Variables

All configuration variables are documented in [README.md](./README.md#configuration). Security-specific ones:

| Variable | Default | Purpose |
|----------|---------|---------|
| `IP_ALLOWLIST_ENABLED` | `false` | Enable/disable IP allowlist mode |
| `CLIENT_SECURITY_GROUP_ID` | (required) | SG ID to update with client IP |
| `DUAL_IP_RETENTION_MINUTES` | `180` | Minutes to keep old IP after change |
| `LOCAL_REQUIRE_AUTH` | `false` | Enable local HTTP proxy authentication |

---

## CloudFormation Parameters Reference

```yaml
Parameters:
  IPAllowlistEnabled:
    Type: String
    Default: 'false'
    Description: Enable IP allowlist security mode
  
  ClientPublicIP:
    Type: String
    Description: Client IP to allowlist (e.g., 203.0.113.42/32)
  
  DualIPRetentionMinutes:
    Type: Number
    Default: 180
    Description: Minutes to retain old IP during transitions
```

---

## Performance Impact

- **IP Detection:** ~500ms every 60 seconds (not on critical path)
- **Security Group Update:** ~1 second (on-demand, not frequent)
- **Proxy Throughput:** Zero impact - all changes happen in background thread

---

## Switching Back to Open Access

If you need to disable IP allowlist temporarily:

```bash
# Update stack to disable IP allowlist
aws cloudformation update-stack \
  --stack-name socks5-proxy-stack \
  --use-previous-template \
  --parameters \
    ParameterKey=IPAllowlistEnabled,ParameterValue=false \
  --capabilities CAPABILITY_NAMED_IAM

# Then update .env and restart
IP_ALLOWLIST_ENABLED=false
./proxy-manage.sh stop
./proxy-manage.sh start
```

**Warning:** With IP allowlist disabled, the proxy is open to anyone on the internet. Only use this for testing/debugging.

---

## Logging

All IP changes are logged with timestamps:

```bash
# View IP-related logs
docker logs socks5-orchestrator | grep -E "(IP|security|allowlist)"

# Example log output:
# 2024-05-23 14:30:45 - Local public IP changed: 203.0.113.42 -> 203.0.113.99
# 2024-05-23 14:30:46 - Updating security group sg-xxx to allow 203.0.113.99/32
# 2024-05-23 14:30:47 - Successfully updated security group to allow 203.0.113.99/32
# 2024-05-23 14:30:47 - Stored previous IP 203.0.113.42 for dual-IP retention
```

---

## Next Steps

1. ✅ Deploy stack with IP allowlist enabled
2. ✅ Verify IP appears in `curl http://localhost:5000/ip/status`
3. ✅ Test proxy connection works with your IP
4. ✅ Change office IP/network and verify automatic update
5. ✅ Check logs for IP change notifications

For additional security, consider:
- Enabling VPC Flow Logs for audit trail
- Setting up CloudWatch alarms for failed SG updates
- Using AWS Systems Manager to track IP changes
