# AWS EC2 Proxy Setup Guide (Legacy)

> **⚠️ This guide is for the legacy EC2-based proxy approach.**  
> The current project uses **AWS Fargate** which is more cost-effective, fully managed, and easier to set up.  
> See [README.md](./README.md) or [QUICKSTART.md](./QUICKSTART.md) for the recommended approach.

This guide walks you through deploying a persistent HTTP proxy on an EC2 nano instance with automatic shutdown and CLI management.

## Table of Contents
1. [Why EC2 over Lambda](#why-ec2-over-lambda)
2. [Prerequisites](#prerequisites)
3. [Initial Setup](#initial-setup)
4. [Installing the Proxy](#installing-the-proxy)
5. [Auto-Shutdown Configuration](#auto-shutdown-configuration)
6. [Management Scripts](#management-scripts)
7. [Monitoring & Troubleshooting](#monitoring--troubleshooting)
8. [Cost Management](#cost-management)

---

## Why EC2 over Lambda

| Feature | Lambda | EC2 Nano |
|---------|--------|----------|
| **Persistent Connections** | ❌ No | ✅ Yes |
| **WebSockets** | ❌ No | ✅ Yes |
| **HTTP Keep-Alive** | ⚠️ Limited | ✅ Full |
| **SSE/Long Polling** | ⚠️ Slow | ✅ Fast |
| **Cost (intermittent)** | $0-3/month | $2-4/month |
| **Setup Time** | 30+ min | 15 min |
| **Start/Stop** | N/A | 1-2 min |

---

## Prerequisites

- AWS account with EC2 and security group permissions
- AWS CLI v2 installed and configured
- SSH key pair created in AWS
- Familiar with basic Linux/Debian commands

### Verify AWS CLI Setup

```bash
aws ec2 describe-regions --query 'Regions[0].RegionName' --output text
# Should return your configured region (e.g., us-east-1)
```

---

## Initial Setup

### Step 1: Create Security Group

This allows SSH (port 22) and HTTP proxy traffic (port 8080).

```bash
# Create security group
SG_ID=$(aws ec2 create-security-group \
  --group-name proxy-sg \
  --description "Security group for HTTP proxy" \
  --query 'GroupId' \
  --output text)

echo "Security Group ID: $SG_ID"

# Allow SSH from your IP
# Replace YOUR_IP with your public IP (check: curl ifconfig.me)
YOUR_IP="YOUR_IP/32"

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr $YOUR_IP

# Allow HTTP proxy traffic from anywhere (or restrict if needed)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 8080 \
  --cidr 0.0.0.0/0

# Allow HTTPS proxy traffic
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 8443 \
  --cidr 0.0.0.0/0

echo "Security group configured: $SG_ID"
```

### Step 2: Create EC2 Instance

Find the latest Debian 12 AMI:

```bash
# Find latest Debian 12 AMI in your region
AMI_ID=$(aws ec2 describe-images \
  --owners 379101102735 \
  --filters "Name=name,Values=debian-12-amd64-*" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)

echo "Using AMI: $AMI_ID"

# Get your SSH key name (or create one first)
# List available keys: aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text
KEY_NAME="your-key-name"  # Replace with your SSH key name

# Launch instance
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t4g.nano \
  --key-name $KEY_NAME \
  --security-group-ids $SG_ID \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=http-proxy}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance launched: $INSTANCE_ID"
echo "Waiting for instance to start..."
sleep 30

# Get instance details
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].[PublicIpAddress,State.Name]' \
  --output text
```

**Save these values in a file for later:**

```bash
cat > proxy-config.sh << 'EOF'
#!/bin/bash
export INSTANCE_ID="i-xxxxxxxxxxxxx"  # Replace with your instance ID
export SG_ID="sg-xxxxxxxxxxxxx"       # Replace with your security group ID
export KEY_NAME="your-key-name"       # Replace with your key name
export REGION="us-east-1"             # Replace with your region
EOF

chmod +x proxy-config.sh
source proxy-config.sh
```

### Step 3: Wait for Instance to be Ready

```bash
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Instance running at: $PUBLIC_IP"
echo "SSH in with: ssh -i /path/to/key.pem admin@$PUBLIC_IP"
```

---

## Installing the Proxy

### Step 4: Initial SSH Connection

```bash
# SSH into the instance
ssh -i /path/to/your-key.pem admin@$PUBLIC_IP

# Once connected, update system
sudo apt update && sudo apt upgrade -y
```

### Step 5: Install mitmproxy

mitmproxy provides full persistent connection support with WebSocket, SSE, Keep-Alive, etc.

```bash
# Install Python and pip
sudo apt install -y python3 python3-pip

# Install mitmproxy
sudo pip install mitmproxy

# Verify installation
mitmproxy --version
```

### Step 6: Create mitmproxy Service

This allows mitmproxy to run in the background and restart automatically.

```bash
# Create systemd service file
sudo tee /etc/systemd/system/mitmproxy.service > /dev/null << 'EOF'
[Unit]
Description=mitmproxy HTTP/HTTPS Proxy
After=network.target

[Service]
Type=simple
User=admin
ExecStart=/usr/local/bin/mitmproxy --mode regular --listen-host 0.0.0.0 --listen-port 8080 --ignore-hosts '^(?!.*\.example\.com)' --set confdir=/home/admin/.mitmproxy
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable mitmproxy
sudo systemctl start mitmproxy

# Check status
sudo systemctl status mitmproxy
```

### Step 7: Create Auto-Shutdown Script

This script runs as a cron job and shuts down the instance after N hours of inactivity.

```bash
# Create shutdown script
cat > /home/admin/auto-shutdown.sh << 'EOF'
#!/bin/bash
# Auto-shutdown after IDLE_HOURS of no proxy traffic
# Run via cron every 15 minutes

IDLE_HOURS=2
IDLE_MINUTES=$((IDLE_HOURS * 60))
LOG_FILE="/var/log/mitmproxy/access.log"
LOCK_FILE="/tmp/shutdown-scheduled"

# Check if shutdown already scheduled
if [ -f "$LOCK_FILE" ]; then
    exit 0
fi

# Check last mitmproxy activity
if [ ! -f "$LOG_FILE" ]; then
    LAST_ACCESS=0
else
    LAST_ACCESS=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo $(date +%s))
fi

CURRENT_TIME=$(date +%s)
IDLE_SECONDS=$((IDLE_MINUTES * 60))
TIME_DIFF=$((CURRENT_TIME - LAST_ACCESS))

echo "[$(date)] Last access: $((TIME_DIFF / 60)) minutes ago (threshold: $IDLE_MINUTES minutes)" >> /tmp/shutdown-check.log

if [ $TIME_DIFF -gt $IDLE_SECONDS ]; then
    echo "[$(date)] No activity for $IDLE_HOURS hours. Scheduling shutdown..." >> /tmp/shutdown-check.log
    touch "$LOCK_FILE"
    
    # Shutdown after 5 minutes (grace period)
    sudo shutdown -h +5 "System auto-shutting down due to inactivity"
    
    # Log to CloudWatch (optional)
    echo "Auto-shutdown initiated due to $IDLE_HOURS hours inactivity" | logger -t mitmproxy-shutdown
else
    echo "[$(date)] Activity detected. Keeping instance running." >> /tmp/shutdown-check.log
fi
EOF

chmod +x /home/admin/auto-shutdown.sh

# Test the script manually first
/home/admin/auto-shutdown.sh

# Add to crontab (runs every 15 minutes)
(crontab -l 2>/dev/null; echo "*/15 * * * * /home/admin/auto-shutdown.sh") | crontab -
```

### Step 8: Verify Proxy is Running

```bash
# From your local machine (not SSH'd in)
export PROXY_IP=$PUBLIC_IP

# Test HTTP proxy
curl -x http://$PROXY_IP:8080 http://httpbin.org/ip

# Should return: "origin": "<your-external-ip>"
```

---

## Management Scripts

Save these scripts on your **local machine** for easy instance management.

### Create Management Script File

```bash
mkdir -p ~/aws-proxy-scripts
cd ~/aws-proxy-scripts

# Source your config
source /path/to/proxy-config.sh
```

### Script 1: Start Instance

```bash
cat > start-proxy.sh << 'EOF'
#!/bin/bash
source ./proxy-config.sh

echo "Starting proxy instance..."
aws ec2 start-instances --instance-ids $INSTANCE_ID --region $REGION

echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

# Get IP and wait for SSH to be ready
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --region $REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Waiting for mitmproxy to be ready..."
sleep 10

# Verify mitmproxy is running
for i in {1..30}; do
  if nc -z $PUBLIC_IP 8080 2>/dev/null; then
    echo "✓ Proxy is ready at http://$PUBLIC_IP:8080"
    exit 0
  fi
  echo "Attempt $i: Proxy not ready yet..."
  sleep 2
done

echo "✗ Proxy failed to start. Check instance status."
exit 1
EOF

chmod +x start-proxy.sh
```

### Script 2: Stop Instance

```bash
cat > stop-proxy.sh << 'EOF'
#!/bin/bash
source ./proxy-config.sh

echo "Stopping proxy instance..."
aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION

echo "Waiting for instance to stop..."
aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID --region $REGION

echo "✓ Proxy instance stopped"
EOF

chmod +x stop-proxy.sh
```

### Script 3: Get Status & IP

```bash
cat > status-proxy.sh << 'EOF'
#!/bin/bash
source ./proxy-config.sh

STATE=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --region $REGION \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)

echo "Instance State: $STATE"

if [ "$STATE" == "running" ]; then
  PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
  
  echo "Public IP: $PUBLIC_IP"
  echo "Proxy URL: http://$PUBLIC_IP:8080"
  
  # Test connectivity
  if nc -z $PUBLIC_IP 8080 2>/dev/null; then
    echo "✓ Proxy is responding"
  else
    echo "⚠ Proxy not responding yet (may still be starting)"
  fi
else
  echo "Instance is not running"
fi
EOF

chmod +x status-proxy.sh
```

### Script 4: SSH into Instance

```bash
cat > ssh-proxy.sh << 'EOF'
#!/bin/bash
source ./proxy-config.sh

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --region $REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "SSH'ing into $PUBLIC_IP..."
ssh -i ~/.ssh/$KEY_NAME.pem admin@$PUBLIC_IP
EOF

chmod +x ssh-proxy.sh
```

### Script 5: View Logs

```bash
cat > logs-proxy.sh << 'EOF'
#!/bin/bash
source ./proxy-config.sh

# View systemd logs (last 50 lines, follow mode)
ssh -i ~/.ssh/$KEY_NAME.pem admin@$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --region $REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text) \
  "sudo journalctl -u mitmproxy -n 50 -f"
EOF

chmod +x logs-proxy.sh
```

### Quick Usage

```bash
# Start the proxy and get ready to use
./start-proxy.sh

# Check status anytime
./status-proxy.sh

# SSH into instance if needed
./ssh-proxy.sh

# View live logs
./logs-proxy.sh

# Stop the proxy (when done)
./stop-proxy.sh
```

---

## Auto-Shutdown Configuration

The auto-shutdown script is already installed on the instance. Here's how to adjust it:

### Modify Idle Time

Edit the `auto-shutdown.sh` script on the instance:

```bash
# SSH in
./ssh-proxy.sh

# Edit the script
sudo nano /home/admin/auto-shutdown.sh

# Change this line to your desired idle time (in hours)
# IDLE_HOURS=2
```

### Disable Auto-Shutdown Temporarily

```bash
# SSH in
./ssh-proxy.sh

# Remove the lock file and reschedule timer
sudo rm -f /tmp/shutdown-scheduled

# Check scheduled shutdown (if any)
sudo shutdown -c  # Cancel any pending shutdown
```

---

## Monitoring & Troubleshooting

### Check Instance Uptime

```bash
./ssh-proxy.sh

# Check how long it's been running
uptime

# View system logs
sudo journalctl -u mitmproxy -n 100
```

### Check Proxy Traffic

```bash
./ssh-proxy.sh

# View recent proxy requests
sudo tail -f /var/log/mitmproxy/access.log

# Or via systemd logs
sudo journalctl -u mitmproxy -f
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Proxy not responding | `./status-proxy.sh` to test; check firewall rules |
| Auto-shutdown too aggressive | SSH in, edit `/home/admin/auto-shutdown.sh`, increase `IDLE_HOURS` |
| Instance won't start | Check AWS console for errors; verify key name and security group |
| High data transfer costs | Instance only transfers data when proxy is active; check if accidentally left running |

---

## Cost Management

### Estimated Monthly Costs

**Nano instance (t4g.nano):**
- **On-demand:** ~$0.0252/hour = ~$1.80/month (24/7)
- **For 100 hours/month:** ~$2.50
- **For 50 hours/month:** ~$1.25

**EBS volume (8GB default):**
- ~$0.80/month

**Data transfer:**
- Free for first 1GB/month
- $0.12/GB after (but typically low for proxy traffic)

**Total estimate (100 hours/month):** ~$3.30/month

### Cost Optimization

1. **Use Spot instances** (50-70% discount, but can be interrupted)
   ```bash
   # Launch with --instance-type t4g.nano --spot
   ```

2. **Resize smaller** if needed
   ```bash
   # Stop instance, change type, restart
   ```

3. **Set billing alarm**
   ```bash
   aws cloudwatch put-metric-alarm \
     --alarm-name proxy-monthly-cost \
     --alarm-description "Alert if proxy costs exceed $10/month" \
     --metric-name EstimatedCharges \
     --namespace AWS/Billing \
     --statistic Maximum \
     --period 86400 \
     --threshold 10 \
     --comparison-operator GreaterThanThreshold
   ```

---

## Cleanup (if needed)

```bash
# Stop instance
./stop-proxy.sh

# Terminate instance
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION

# Delete security group (wait for instance to fully terminate first)
sleep 60
aws ec2 delete-security-group --group-id $SG_ID --region $REGION

# Delete SSH key (if no longer needed)
aws ec2 delete-key-pair --key-name $KEY_NAME --region $REGION
```

---

## Configure Browser Proxy

### Chrome/Edge
1. Settings → Advanced → System → Open your computer's proxy settings
2. **Manual proxy setup**
   - HTTP proxy: `<PUBLIC_IP>:8080`
   - HTTPS proxy: `<PUBLIC_IP>:8080` (uses HTTP CONNECT)

### Firefox
1. Preferences → Network Settings
2. Manual proxy configuration
   - HTTP proxy: `<PUBLIC_IP>:8080`
   - HTTPS proxy: `<PUBLIC_IP>:8080`

### macOS System Proxy
```bash
networksetup -setwebproxy "Wi-Fi" $PUBLIC_IP 8080
networksetup -setsecurewebproxy "Wi-Fi" $PUBLIC_IP 8080
```

---

## Next Steps

1. **Create the scripts:** Copy the management scripts to your local machine
2. **Test start/stop:** Run `./start-proxy.sh` and `./stop-proxy.sh` to verify
3. **Monitor usage:** Check `./status-proxy.sh` periodically
4. **Set billing alarm:** Catch any accidental overspend early
5. **Bookmark:** The IP changes on each start, so use `./status-proxy.sh` to get it

---

## Reference Commands

| Task | Command |
|------|---------|
| Start proxy | `./start-proxy.sh` |
| Stop proxy | `./stop-proxy.sh` |
| Check status | `./status-proxy.sh` |
| SSH into instance | `./ssh-proxy.sh` |
| View logs | `./logs-proxy.sh` |
| Get current IP | `./status-proxy.sh` (shows in output) |
| Disable auto-shutdown | `./ssh-proxy.sh` then `sudo rm /tmp/shutdown-scheduled` |

