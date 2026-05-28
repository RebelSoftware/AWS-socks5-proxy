# Security Configuration

## Overview

The SOCKS5 proxy supports **two complementary security layers** that can be used independently or together:

| Layer | Mechanism | Best For |
|-------|-----------|----------|
| **IP Allowlist** | AWS security group restricts port 1080 to your IP | Office/static IP environments |
| **Username/Password** | SOCKS5 authentication via `PROXY_USER`/`PROXY_PASSWORD` | Dynamic IPs, defense-in-depth |

During `setup.sh`, you **must** enable at least one layer:
- If you decline the IP allowlist, username/password auth is **mandatory**
- If you enable the IP allowlist, username/password auth is **optional** (recommended for extra protection)

---

## Security Model

### IP Allowlist Mode (Recommended for Static IPs)

**When to use:** Office environments with fixed or semi-dynamic IPs

- Security group restricted to your client's public IP (`/32` CIDR)
- No authentication required (default) — security by network isolation
- Automatic IP change detection and security group updates
- Dual-IP retention: maintains both old and new IPs for 180 minutes during transitions

**Security guarantees:**
- ✅ Only your IP can reach the proxy port (1080)
- ✅ Anyone at another IP cannot access the proxy
- ✅ Automatic recovery if your IP changes mid-session
- ✅ Full audit trail of IP changes in logs

### Username/Password Authentication (Required when IP allowlist is off)

**When to use:** Dynamic IPs, travel, or as an additional security layer

- SOCKS5 username/password authentication (RFC 1929)
- Credentials passed as environment variables to the Fargate container
- Local proxy automatically uses credentials when connecting
- Can be combined with IP allowlist for defense-in-depth

**Security guarantees:**
- ✅ Only users with valid credentials can connect
- ✅ Works from any IP address
- ✅ Credentials never stored in files (environment variables only)
- ✅ Backup security layer if IP allowlist is compromised

---

## Deployment

### Automated Setup (Recommended)

Run `./setup.sh` and follow the prompts. It will ask about:
1. **IP allowlist** — Enable/disable (auto-detects your public IP)
2. **Username/password** — Set credentials (required if IP allowlist is off)
3. **Idle timeout** — Configure auto-shutdown minutes

### Manual Deployment with IP Allowlist

Deploy the CloudFormation stack with IP allowlist enabled:

```bash
YOUR_PUBLIC_IP="203.0.113.42"  # Replace with your actual IP

aws cloudformation create-stack \
  --stack-name socks5-proxy-stack \
  --template-body file://fargate-infrastructure.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=proxy \
    ParameterKey=IPAllowlistEnabled,ParameterValue=true \
    ParameterKey=ClientPublicIP,ParameterValue="${YOUR_PUBLIC_IP}/32" \
    ParameterKey=DualIPRetentionMinutes,ParameterValue=180 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

### Manual Deployment with Username/Password Auth (No IP Allowlist)

```bash
aws cloudformation create-stack \
  --stack-name socks5-proxy-stack \
  --template-body file://fargate-infrastructure.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=proxy \
    ParameterKey=IPAllowlistEnabled,ParameterValue=false \
    ParameterKey=ProxyUsername,ParameterValue=myuser \
    ParameterKey=ProxyPassword,ParameterValue=mypassword \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

### Get Stack Outputs

After stack creation, get the security group ID:

```bash
aws cloudformation describe-stacks \
  --stack-name socks5-proxy-stack \
  --query 'Stacks[0].Outputs' \
  --region us-east-1
```

Note the `SecurityGroupId` value.

### Configure Local Orchestrator

Update your `.env` file with:

```bash
# IP Allowlist configuration
IP_ALLOWLIST_ENABLED=true
CLIENT_SECURITY_GROUP_ID=sg-0123456789abcdef0  # From stack outputs
DUAL_IP_RETENTION_MINUTES=180

# Username/password (if enabled)
REQUIRE_AUTH=true
PROXY_USER=myuser
PROXY_PASSWORD=mypassword
```

### Start the Proxy

```bash
./proxy-manage.sh start
```

The orchestrator will:
1. Detect your local machine's public IP (if allowlist enabled)
2. Verify it's in the security group
3. Automatically add it if it's not yet in the rules
4. Track IP changes and update the SG as needed

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

---

## Environment Variables Reference

| Variable | Default | Purpose |
|----------|---------|---------|
| `IP_ALLOWLIST_ENABLED` | `false` | Enable/disable IP allowlist mode |
| `CLIENT_SECURITY_GROUP_ID` | (required) | SG ID to update with client IP |
| `DUAL_IP_RETENTION_MINUTES` | `180` | Minutes to keep old IP after change |
| `AWS_REGION` | `us-east-1` | AWS region for EC2 API calls |

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
