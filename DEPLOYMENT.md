# Deployment Guide — Fargate SOCKS5 Proxy

> Manual deployment steps for those who prefer not to use `./setup.sh`. For automated setup, see [README.md](./README.md#quick-start).

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [AWS Infrastructure Setup](#aws-infrastructure-setup)
3. [Local Proxy Setup](#local-proxy-setup)
4. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- AWS account with Fargate permissions
- AWS CLI v2 configured
- Docker and Docker Compose installed

### Verify Setup

```bash
aws sts get-caller-identity
docker --version
docker compose --version
```

---

## AWS Infrastructure Setup

### Step 1: Deploy CloudFormation Stack

Creates VPC, ECS cluster, security groups, and auto-shutdown Lambda.

**With IP allowlist enabled (recommended for static IPs):**

```bash
ENVIRONMENT_NAME="proxy"
IDLE_TIMEOUT_MINUTES=60
YOUR_PUBLIC_IP=$(curl -s https://checkip.amazonaws.com)

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

**With SOCKS5 username/password (no IP allowlist):**

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
aws cloudformation wait stack-create-complete --stack-name ${ENVIRONMENT_NAME}-fargate-proxy
aws cloudformation describe-stacks --stack-name ${ENVIRONMENT_NAME}-fargate-proxy --query 'Stacks[0].Outputs' --output table
```

### Step 2: Create .env Configuration

```bash
STACK_NAME="proxy-fargate-proxy"

CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' --output text)
SUBNET_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].Outputs[?OutputKey==`SubnetId1`].OutputValue' --output text)
SG_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue' --output text)

cat > .env << EOF
AWS_REGION=us-east-1
ECS_CLUSTER=$CLUSTER_NAME
ECS_TASK_DEFINITION=go-socks5-proxy
TASK_SUBNET=$SUBNET_ID
TASK_SECURITY_GROUP=$SG_ID
LOCAL_PROXY_PORT=8080
SOCKS5_PORT=1080
IDLE_TIMEOUT_MINUTES=60

# IP Allowlist
IP_ALLOWLIST_ENABLED=true
CLIENT_SECURITY_GROUP_ID=${SG_ID}
DUAL_IP_RETENTION_MINUTES=180

# SOCKS5 auth (upstream)
REQUIRE_AUTH=false
PROXY_USER=
PROXY_PASSWORD=

# Local proxy auth (optional, for LAN use)
LOCAL_REQUIRE_AUTH=false
LOCAL_PROXY_USER=
LOCAL_PROXY_PASSWORD=
EOF
```

### Step 3: Verify Infrastructure

```bash
aws ecs describe-clusters --clusters $CLUSTER_NAME
aws ecs list-task-definitions --family-prefix go-socks5-proxy
aws ec2 describe-security-groups --group-ids $SG_ID
```

---

## Local Proxy Setup

### Step 4: Build and Run

```bash
docker compose up -d --build
```

### Step 5: Verify

```bash
docker compose ps
curl http://localhost:5000/status
```

Wait ~30-60s for the Fargate task to initialize. The `/status` endpoint will show the remote IP once ready.

All configuration and management commands are documented in [README.md](./README.md).

---

## Troubleshooting

### Local Containers Won't Start

```bash
docker compose logs proxy-orchestrator
docker compose logs http-proxy

# Verify AWS credentials
aws sts get-caller-identity
```

### Local Proxy Running but No Remote IP

```bash
curl http://localhost:5000/status
aws ecs list-tasks --cluster proxy-cluster --desired-status RUNNING

# Check Fargate logs
aws logs tail /ecs/proxy-go-socks5-proxy --follow
```

### Fargate Task Won't Start

Common causes:
- Subnet lacks Internet Gateway / public route
- Security group blocks egress or SOCKS5 port (1080)
- Task definition image not available
- Insufficient Fargate capacity in region

Check CloudFormation stack events for failures:

```bash
aws cloudformation describe-stack-events --stack-name proxy-fargate-proxy --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]'
```

### Manual Fargate Operations

```bash
# Start task via AWS CLI
aws ecs run-task \
  --cluster proxy-cluster \
  --task-definition go-socks5-proxy \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}"

# Stop task via AWS CLI
TASK_ARN=$(aws ecs list-tasks --cluster proxy-cluster --desired-status RUNNING --query 'taskArns[0]' --output text)
aws ecs stop-task --cluster proxy-cluster --task $TASK_ARN --reason "Manual stop"
```
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

