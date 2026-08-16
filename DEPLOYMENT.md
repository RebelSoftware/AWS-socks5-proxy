# Deployment Guide — Fargate SOCKS5 Proxy

> Manual deployment for those who prefer not to use `./setup.sh` — the automated
> script is the recommended path (see [QUICKSTART.md](./QUICKSTART.md)).

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Deploy the AWS infrastructure](#1-deploy-the-aws-infrastructure)
3. [Create the .env file](#2-create-the-env-file)
4. [Build & run locally](#3-build--run-locally)
5. [Troubleshooting](#troubleshooting)
6. [Cleanup](#cleanup)

---

## Prerequisites

- AWS account with permissions for CloudFormation, ECS, EC2, and IAM
  (`setup.sh` verifies these for you; manually you need stack management plus
  IAM user/access-key management to create the orchestrator's restricted
  credentials)
- AWS CLI v2 configured
- Docker and Docker Compose installed
- `jq` (used to parse stack outputs)

```bash
aws sts get-caller-identity
docker compose version
jq --version
```

---

## 1. Deploy the AWS infrastructure

```bash
STACK_NAME="proxy-fargate-proxy"
YOUR_PUBLIC_IP=$(curl -s https://checkip.amazonaws.com)

aws cloudformation create-stack \
  --stack-name $STACK_NAME \
  --template-body file://fargate-infrastructure.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=proxy \
    ParameterKey=ReaperTimeoutMinutes,ParameterValue=120 \
    ParameterKey=IPAllowlistEnabled,ParameterValue=true \
    ParameterKey=ClientPublicIP,ParameterValue="${YOUR_PUBLIC_IP}/32" \
  --capabilities CAPABILITY_NAMED_IAM
```

- **`ReaperTimeoutMinutes`** — force-stop any task older than N minutes
  (default 120, `0` disables). Cost guard for the case where the local machine
  dies while a task is running.
- **No IP allowlist?** Pass `IPAllowlistEnabled=false` and add
  `ProxyUsername` / `ProxyPassword` — SOCKS5 auth then secures the proxy.

```bash
aws cloudformation wait stack-create-complete --stack-name $STACK_NAME
aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].Outputs' --output table
```

Creates: VPC, subnets, internet gateway, security groups, ECS cluster, task
definition, CloudWatch log group, and the reaper Lambda + 15-minute schedule.

---

## 2. Create the .env file

Extract the stack outputs in one call:

```bash
STACK_JSON=$(aws cloudformation describe-stacks --stack-name $STACK_NAME)
CLUSTER_NAME=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="ClusterName") | .OutputValue')
SUBNET_ID=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="SubnetId1") | .OutputValue')
SG_ID=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="SecurityGroupId") | .OutputValue')
```

Then create `.env` (complete reference: [.env.example](./.env.example)):

```bash
AWS_REGION=us-east-1
# Orchestrator credentials — use a restricted IAM user (see the policy in
# setup.sh: ECS task management, EC2 describe, SG ingress, iam:PassRole).
AWS_ACCESS_KEY_ID=<orchestrator access key>
AWS_SECRET_ACCESS_KEY=<orchestrator secret>

ECS_CLUSTER=$CLUSTER_NAME
ECS_TASK_DEFINITION=go-socks5-proxy
TASK_SUBNET=$SUBNET_ID
TASK_SECURITY_GROUP=$SG_ID
LOCAL_PROXY_PORT=8080
SOCKS5_PORT=1080
TASK_IDLE_TIMEOUT_MINUTES=60
HTTP_PROXY_HEALTH_URL=http://http-proxy:8081/health

# Remote auto-start and host binding
AUTO_START_REMOTE=false
PROXY_BIND_ADDRESS=127.0.0.1

# SOCKS5 auth to Fargate
REQUIRE_AUTH=false
PROXY_USER=
PROXY_PASSWORD=

# IP allowlist
IP_ALLOWLIST_ENABLED=true
CLIENT_SECURITY_GROUP_ID=$SG_ID
DUAL_IP_RETENTION_MINUTES=180

# Local proxy auth (optional, for LAN use)
LOCAL_REQUIRE_AUTH=false
LOCAL_PROXY_USER=
LOCAL_PROXY_PASSWORD=
```

Verify the resources:

```bash
aws ecs describe-clusters --clusters $CLUSTER_NAME
aws ecs list-task-definitions --family-prefix go-socks5-proxy
aws ec2 describe-security-groups --group-ids $SG_ID
```

---

## 3. Build & run locally

```bash
docker compose up -d --build
docker compose ps
docker exec proxy-orchestrator curl -s http://localhost:5000/status
```

Wait 30–60 seconds for the Fargate task to get its public IP (`remote_ip` in
`/status`). Daily management commands: [README.md](./README.md#daily-usage).

---

## Troubleshooting

### Local containers won't start

```bash
docker compose logs proxy-orchestrator http-proxy
aws sts get-caller-identity        # credentials valid?
```

### Local proxy up, no remote IP

```bash
docker exec proxy-orchestrator curl -s http://localhost:5000/status
aws ecs list-tasks --cluster proxy-cluster --desired-status RUNNING
aws logs tail /ecs/proxy-go-socks5-proxy --follow
```

### Fargate task won't start

Common causes: subnet missing internet gateway/public route, security group
blocks egress or port 1080, task definition image unavailable, insufficient
capacity in region. Check stack events:

```bash
aws cloudformation describe-stack-events --stack-name proxy-fargate-proxy \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]'
```

### Manual Fargate operations

```bash
# Start a task via AWS CLI
aws ecs run-task \
  --cluster proxy-cluster \
  --task-definition go-socks5-proxy \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}"

# Stop a task
TASK_ARN=$(aws ecs list-tasks --cluster proxy-cluster --desired-status RUNNING --query 'taskArns[0]' --output text)
aws ecs stop-task --cluster proxy-cluster --task $TASK_ARN --reason "Manual stop"

# Inspect failures / stoppedReason
aws ecs describe-tasks --cluster proxy-cluster --tasks $TASK_ARN
```

### SOCKS5 connection fails

```bash
# Security group allows your IP on 1080?
aws ec2 describe-security-group-rules --filters Name=group-id,Values=$SG_ID
# Credentials match?
grep -E "REQUIRE_AUTH|PROXY_USER|PROXY_PASSWORD" .env
```

### Reaper (abandoned-task guard)

The reaper force-stops tasks older than `ReaperTimeoutMinutes`. It normally
never fires first — the orchestrator stops idle tasks sooner. If a task is
stopped unexpectedly, check the Lambda logs:

```bash
aws lambda get-function --function-name proxy-socks5-reaper
aws logs tail /aws/lambda/proxy-socks5-reaper --follow
```

### High costs

```bash
aws ecs list-tasks --cluster proxy-cluster --desired-status RUNNING   # stuck tasks?
./proxy-manage.sh stop --remote                                       # stop everything
```

---

## Cleanup

```bash
docker compose down
./proxy-manage.sh stop --remote          # stop any Fargate task immediately
aws cloudformation delete-stack --stack-name proxy-fargate-proxy
aws cloudformation wait stack-delete-complete --stack-name proxy-fargate-proxy
```

> Cost watch: `aws ecs list-tasks --cluster proxy-cluster --desired-status
> RUNNING` shows stuck tasks; a CloudWatch alarm on
> `AWS/Billing.EstimatedCharges` can alert you (see AWS docs). The reaper
> normally makes this unnecessary.

---

## Quick Reference

| Task | Command |
|------|---------|
| Start / stop | `./proxy-manage.sh start` / `./proxy-manage.sh stop` |
| Status | `docker exec proxy-orchestrator curl -s http://localhost:5000/status` |
| Local logs | `docker compose logs -f http-proxy proxy-orchestrator` |
| Fargate logs | `aws logs tail /ecs/proxy-go-socks5-proxy --follow` |
| List tasks | `aws ecs list-tasks --cluster proxy-cluster` |
| Stop task | `aws ecs stop-task --cluster proxy-cluster --task TASK_ARN` |

