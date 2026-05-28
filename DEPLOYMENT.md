# Deployment Guide - Fargate SOCKS5 Proxy with Local Orchestration

This guide walks through deploying the complete two-tier proxy solution.

> **💡 Tip:** For the quickest setup, run `./setup.sh` which automates all of the following steps.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [AWS Infrastructure Setup](#aws-infrastructure-setup)
3. [Local Proxy Setup](#local-proxy-setup)
4. [Testing](#testing)
5. [Management Operations](#management-operations)
6. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- AWS account with Fargate permissions
- AWS CLI v2 configured
- Docker and Docker Compose installed
- Python 3.9+

### Verify Setup

```bash
aws sts get-caller-identity
docker --version
docker compose --version
python3 --version
```

---

## AWS Infrastructure Setup

### Step 1: Deploy CloudFormation Stack

This creates the VPC, ECS cluster, security groups, and auto-shutdown Lambda.

**With IP allowlist enabled (recommended for static IPs):**

```bash
# Set your parameters
ENVIRONMENT_NAME="proxy"
IDLE_TIMEOUT_MINUTES=60
YOUR_PUBLIC_IP=$(curl -s https://checkip.amazonaws.com)  # Auto-detect

aws cloudformation create-stack \
  --stack-name ${ENVIRONMENT_NAME}-fargate-proxy \
  --template-body file://fargate-infrastructure.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${ENVIRONMENT_NAME} \
    ParameterKey=TaskIdleTimeoutMinutes,ParameterValue=${IDLE_TIMEOUT_MINUTES} \
    ParameterKey=IPAllowlistEnabled,ParameterValue=true \
    ParameterKey=ClientPublicIP,ParameterValue="${YOUR_PUBLIC_IP}/32" \
  --capabilities CAPABILITY_NAMED_IAM
```

**With username/password authentication (no IP allowlist):**

```bash
aws cloudformation create-stack \
  --stack-name ${ENVIRONMENT_NAME}-fargate-proxy \
  --template-body file://fargate-infrastructure.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${ENVIRONMENT_NAME} \
    ParameterKey=TaskIdleTimeoutMinutes,ParameterValue=${IDLE_TIMEOUT_MINUTES} \
    ParameterKey=IPAllowlistEnabled,ParameterValue=false \
    ParameterKey=ProxyUsername,ParameterValue=myuser \
    ParameterKey=ProxyPassword,ParameterValue=mypassword \
  --capabilities CAPABILITY_NAMED_IAM
```

**Wait for stack creation:**

```bash
aws cloudformation wait stack-create-complete \
  --stack-name ${ENVIRONMENT_NAME}-fargate-proxy

# Get stack outputs
aws cloudformation describe-stacks \
  --stack-name ${ENVIRONMENT_NAME}-fargate-proxy \
  --query 'Stacks[0].Outputs' \
  --output table
```

### Step 2: Save Infrastructure Details

Save the CloudFormation outputs to configure the local proxy:

```bash
STACK_NAME="proxy-fargate-proxy"

CLUSTER_NAME=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' \
  --output text)

SUBNET_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SubnetId1`].OutputValue`' \
  --output text)

SG_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue' \
  --output text)

# Create local configuration
cat > .env << EOF
AWS_REGION=us-east-1
ECS_CLUSTER=$CLUSTER_NAME
ECS_TASK_DEFINITION=go-socks5-proxy
TASK_SUBNET=$SUBNET_ID
TASK_SECURITY_GROUP=$SG_ID
LOCAL_PROXY_PORT=8080
SOCKS5_PORT=1080
TASK_IDLE_TIMEOUT_MINUTES=60

# IP Allowlist configuration
IP_ALLOWLIST_ENABLED=true
CLIENT_SECURITY_GROUP_ID=${SG_ID}
DUAL_IP_RETENTION_MINUTES=180

# Proxy authentication (if configured)
REQUIRE_AUTH=false
PROXY_USER=
PROXY_PASSWORD=
EOF

echo "✓ Configuration saved to .env"
```

### Step 3: Verify Infrastructure

```bash
# Check cluster was created
aws ecs describe-clusters --clusters $CLUSTER_NAME

# List available task definitions
aws ecs list-task-definitions

# Check security group rules
aws ec2 describe-security-groups --group-ids $SG_ID
```

---

## Local Proxy Setup

### Step 4: Configure AWS Credentials

The local proxy needs AWS credentials to manage Fargate tasks.

```bash
# Option 1: Use default AWS profile (recommended)
# Your credentials should already be in ~/.aws/credentials

# Option 2: Use specific profile
export AWS_PROFILE=your-profile

# Verify credentials
aws sts get-caller-identity
```

### Step 5: Build and Run Local Proxy

```bash
# Build the local proxy Docker image
docker compose build

# Start the local proxy container
docker compose up -d

# Check that it started successfully
docker compose logs proxy-orchestrator

# Wait for initialization (usually 30-60 seconds)
```

### Step 6: Verify Local Proxy is Running

```bash
# Check container status
docker compose ps

# Test the management API
curl http://localhost:5000/status

# Expected output:
# {
#   "status": "running",
#   "remote_ip": "12.34.56.78",
#   "remote_task": "arn:aws:ecs:...",
#   "local_port": 8080,
#   "socks5_port": 1080
# }

# Test HTTP proxy locally
curl -x http://localhost:8080 http://httpbin.org/ip
```

---

## Testing

### Manual Test: Check Fargate Task is Running

```bash
# List running tasks
aws ecs list-tasks \
  --cluster $CLUSTER_NAME \
  --desired-status RUNNING

# Get task details
TASK_ARN=$(aws ecs list-tasks \
  --cluster $CLUSTER_NAME \
  --desired-status RUNNING \
  --query 'taskArns[0]' \
  --output text)

aws ecs describe-tasks \
  --cluster $CLUSTER_NAME \
  --tasks $TASK_ARN

# Get the task's IP address
aws ec2 describe-network-interfaces \
  --filters "Name=attachment.instance-owner-id,Values=ecs" \
  --query 'NetworkInterfaces[0].Association.PublicIp'
```

### Manual Test: SOCKS5 Connection

```bash
# Test SOCKS5 proxy through local proxy
export REMOTE_IP=$(curl -s http://localhost:5000/status | jq -r '.remote_ip')

# Test direct connection to remote SOCKS5
curl -x socks5://$REMOTE_IP:1080 http://httpbin.org/ip

# Should return the international IP
```

### Browser Configuration

**Chrome/Edge:**
1. Settings → Advanced → System → Open proxy settings
2. Manual proxy setup
3. HTTP proxy: `localhost:8080`
4. HTTPS proxy: `localhost:8080`

**Firefox:**
1. Preferences → Network Settings
2. Manual proxy configuration
3. HTTP Proxy: `localhost:8080`
4. HTTPS Proxy: `localhost:8080`

### Test in Browser

Visit these sites to verify proxy is working:
- http://httpbin.org/ip - Should show international IP
- http://ifconfig.me - Should show international IP
- http://whatismyipaddress.com - Should show international IP

---

## Management Operations

### Using the Management Script (Recommended)

```bash
./proxy-manage.sh start              # Start proxy (waits ~30-60s for Fargate)
./proxy-manage.sh stop               # Stop local containers only
./proxy-manage.sh stop --remote      # Stop local + Fargate task immediately
./proxy-manage.sh status             # Show status & remote IP
./proxy-manage.sh health             # Full connectivity test
./proxy-manage.sh logs               # View orchestrator logs
./proxy-manage.sh info               # Configuration & cost summary
```

### Alternative: Docker Compose Directly

```bash
# Start
docker compose up -d

# Check status
docker compose ps
curl http://localhost:5000/status

# View logs
docker compose logs proxy-orchestrator
docker compose logs http-proxy

# Stop local containers only
docker compose down
```

### Manually Start Fargate Task

```bash
# Via orchestrator API (requires local containers running)
curl -X POST http://localhost:5000/start

# Via AWS CLI directly (works even if local containers are down)
aws ecs run-task \
  --cluster $CLUSTER_NAME \
  --task-definition go-socks5-proxy \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}"
```

### Manually Stop Fargate Task

```bash
# Via orchestrator API (requires local containers running)
curl -X POST http://localhost:5000/stop

# Via AWS CLI directly (works even if local containers are down)
TASK_ARN=$(aws ecs list-tasks \
  --cluster $CLUSTER_NAME \
  --desired-status RUNNING \
  --query 'taskArns[0]' \
  --output text)

if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
  aws ecs stop-task --cluster $CLUSTER_NAME --task $TASK_ARN --reason "Manual stop"
fi
```

### View Fargate Task Logs

```bash
aws logs tail /ecs/proxy-socks5-proxy --follow
```

---

## Troubleshooting

### Issue: Local Containers Won't Start

**Check logs:**
```bash
docker compose logs proxy-orchestrator
docker compose logs http-proxy

# If permission error, check AWS credentials
cat ~/.aws/credentials
```

**Fix:**
- Verify AWS credentials in `~/.aws/credentials`
- Check `AWS_PROFILE` matches your setup
- Rebuild: `docker compose down && docker compose build && docker compose up -d`

### Issue: Local Proxy Running but No Remote IP

```bash
# Check orchestrator status
curl http://localhost:5000/status

# Check if Fargate task is running
aws ecs list-tasks --cluster $CLUSTER_NAME --desired-status RUNNING

# Check for task failures
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER_NAME --query 'taskArns[0]' --output text)
[ -n "$TASK_ARN" ] && aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN

# Check CloudWatch logs
aws logs tail /ecs/proxy-socks5-proxy --follow
```

### Issue: Fargate Task Won't Start

**Common causes:**
- Security group blocks SOCKS5 port (1080)
- Subnet doesn't have public route/Internet Gateway
- Task definition image not available
- IAM roles not properly configured

**Check:**
```bash
aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks TASK_ARN
# Look for 'failures' or 'stoppedReason' in the output
```

### Issue: SOCKS5 Connection Fails

```bash
# Test connectivity from orchestrator container
docker compose exec orchestrator nc -zv $REMOTE_IP 1080

# Check security group allows inbound on 1080
aws ec2 describe-security-groups --group-ids $SG_ID

# If using auth, verify credentials match
grep -E "PROXY_USER|PROXY_PASSWORD" .env
```

### Issue: Auth Errors

```bash
# Verify the Fargate task has the correct env vars
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER_NAME --query 'taskArns[0]' --output text)
aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN | jq '.tasks[0].overrides.containerOverrides[0].environment'

# Check local .env matches
grep -E "REQUIRE_AUTH|PROXY_USER|PROXY_PASSWORD" .env
```

### Issue: Auto-Shutdown Not Working

```bash
# Check Lambda function was created
aws lambda get-function --function-name proxy-socks5-autoshutdown

# View Lambda logs
aws logs tail /aws/lambda/proxy-socks5-autoshutdown --follow

# Check EventBridge rule
aws events list-rules --name-prefix proxy
```

### Issue: High Costs

```bash
# Check if tasks are stuck running
aws ecs list-tasks --cluster $CLUSTER_NAME --desired-status RUNNING

# Manually stop them
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER_NAME --query 'taskArns[0]' --output text)
aws ecs stop-task --cluster $CLUSTER_NAME --task $TASK_ARN --reason "Cost cleanup"

# Or use the management script
./proxy-manage.sh stop --remote
```

---

## Cleanup

### Remove Everything

```bash
# Stop and remove local containers
docker compose down -v

# Delete Fargate tasks
TASK_ARNS=$(aws ecs list-tasks --cluster $CLUSTER_NAME --query 'taskArns[]' --output text)
for task in $TASK_ARNS; do
  aws ecs stop-task --cluster $CLUSTER_NAME --task $task
done

# Wait for tasks to stop
sleep 60

# Delete CloudFormation stack (removes all AWS resources)
aws cloudformation delete-stack --stack-name proxy-fargate-proxy

# Verify deletion
aws cloudformation wait stack-delete-complete --stack-name proxy-fargate-proxy
```

---

## Cost Monitoring

### Estimate Monthly Cost

```bash
# Fargate task hours per month
HOURS_PER_MONTH=100

# Cost calculation
echo "vCPU cost: \$0.04048 × 0.25 × $HOURS_PER_MONTH = \$$(python3 -c \"print(0.04048 * 0.25 * $HOURS_PER_MONTH)\")"
echo "Memory cost: \$0.004445 × 0.5 × $HOURS_PER_MONTH = \$$(python3 -c \"print(0.004445 * 0.5 * $HOURS_PER_MONTH)\")"
echo "Data transfer: ~\$0 (first 1GB free)"
```

### Set CloudWatch Alarm

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name fargate-proxy-costs \
  --alarm-description "Alert if Fargate costs exceed \$5/month" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 86400 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Start | `docker-compose up -d` |
| Stop | `docker-compose down` |
| Status | `curl http://localhost:5000/status` |
| Logs | `docker-compose logs -f` |
| Fargate logs | `aws logs tail /ecs/proxy-socks5-proxy --follow` |
| List tasks | `aws ecs list-tasks --cluster $CLUSTER_NAME` |
| Stop task | `aws ecs stop-task --cluster $CLUSTER_NAME --task TASK_ARN` |

