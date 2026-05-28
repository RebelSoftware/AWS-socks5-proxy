#!/bin/bash
# Quick setup script for Fargate proxy

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check prerequisites
print_header "Checking Prerequisites"

if ! command -v aws &> /dev/null; then
    print_error "AWS CLI not installed"
    echo "Install from: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi
print_success "AWS CLI installed"

if ! command -v docker &> /dev/null; then
    print_error "Docker not installed"
    echo "Install from: https://docs.docker.com/get-docker/"
    exit 1
fi
print_success "Docker installed"

# Docker Compose is now a Docker plugin (docker compose)
if ! docker compose version &> /dev/null; then
    print_error "Docker Compose not installed"
    echo "Install from: https://docs.docker.com/compose/install/"
    exit 1
fi
print_success "Docker Compose installed"

# Verify AWS credentials
print_info "Verifying AWS credentials..."
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    print_error "AWS credentials not configured"
    echo "Run: aws configure"
    exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_success "AWS account: $ACCOUNT_ID"

# Get region
print_info "Detecting AWS region..."
REGION=$(aws configure get region || echo "us-east-1")
echo "Using region: $REGION"

# Detect local public IP for IP allowlist
print_header "Detecting Public IP"

# Ask user if they want to enable IP allowlist
echo ""
print_info "IP Allowlist restricts proxy access to your IP address only."
print_info "Recommended for office/static IP environments."
echo ""
read -p "Enable IP allowlist? [Y/n]: " ENABLE_ALLOWLIST
ENABLE_ALLOWLIST="${ENABLE_ALLOWLIST:-Y}"

IP_ALLOWLIST_ENABLED="false"
CLIENT_IP=""
ALLOWLIST_PARAMS=""

if [[ "$ENABLE_ALLOWLIST" =~ ^[Yy]$ ]]; then
    print_info "Detecting your public IP..."
    
    # Try multiple IP detection services
    DETECTED_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    fi
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP=$(curl -s --max-time 5 https://ident.me 2>/dev/null)
    fi
    
    if [ -n "$DETECTED_IP" ]; then
        echo ""
        print_info "Detected public IP: $DETECTED_IP"
        read -p "Use this IP? [Y/n]: " USE_DETECTED
        USE_DETECTED="${USE_DETECTED:-Y}"
        
        if [[ "$USE_DETECTED" =~ ^[Yy]$ ]]; then
            CLIENT_IP="$DETECTED_IP"
        else
            read -p "Enter your public IP (with CIDR, e.g., 203.0.113.42/32): " CLIENT_IP
        fi
    else
        echo ""
        print_info "Could not auto-detect your IP."
        read -p "Enter your public IP (with CIDR, e.g., 203.0.113.42/32): " CLIENT_IP
    fi
    
    if [ -n "$CLIENT_IP" ]; then
        # Add /32 if not specified
        if [[ "$CLIENT_IP" != *"/"* ]]; then
            CLIENT_IP="${CLIENT_IP}/32"
        fi
        IP_ALLOWLIST_ENABLED="true"
        print_success "IP allowlist will be enabled for $CLIENT_IP"
    fi
fi

# Prompt for SOCKS5 authentication credentials
print_header "Proxy Authentication Configuration"

echo ""
if [ "$IP_ALLOWLIST_ENABLED" = "false" ]; then
    print_info "IP allowlist is disabled — anyone can reach the proxy port."
    print_info "You MUST set a username and password to secure the proxy."
    echo ""
    REQUIRE_AUTH_PROMPT="Proceed with authentication setup? [Y/n]"
else
    print_info "IP allowlist is enabled. You may optionally add username/password"
    print_info "for an additional layer of security."
    echo ""
    REQUIRE_AUTH_PROMPT="Set up username/password authentication? [y/N]"
fi

# Try existing values from .env
CURRENT_PROXY_USER=""
if [ -f ".env" ]; then
    ENV_USER=$(grep -oP '(?<=^PROXY_USER=).*' .env 2>/dev/null || echo "")
    [ -n "$ENV_USER" ] && CURRENT_PROXY_USER="$ENV_USER"
fi

if [ "$IP_ALLOWLIST_ENABLED" = "false" ]; then
    # Force auth when IP allowlist is disabled
    SETUP_AUTH="Y"
else
    read -p "$REQUIRE_AUTH_PROMPT" SETUP_AUTH
    SETUP_AUTH="${SETUP_AUTH:-N}"
fi

PROXY_USER=""
PROXY_PASSWORD=""
REQUIRE_AUTH="false"

if [[ "$SETUP_AUTH" =~ ^[Yy]$ ]]; then
    echo ""
    if [ -n "$CURRENT_PROXY_USER" ]; then
        print_info "Current proxy username: $CURRENT_PROXY_USER"
        read -p "Change username? [y/N]: " CHANGE_USER
        if [[ "$CHANGE_USER" =~ ^[Yy]$ ]]; then
            read -p "Enter proxy username: " PROXY_USER
        else
            PROXY_USER="$CURRENT_PROXY_USER"
        fi
    else
        read -p "Enter proxy username: " PROXY_USER
    fi
    
    # Validate username is not empty
    while [ -z "$PROXY_USER" ]; do
        print_error "Username cannot be empty."
        if [ -n "$CURRENT_PROXY_USER" ]; then
            read -p "Enter proxy username [$CURRENT_PROXY_USER]: " PROXY_USER
            PROXY_USER="${PROXY_USER:-$CURRENT_PROXY_USER}"
        else
            read -p "Enter proxy username: " PROXY_USER
        fi
    done
    
    read -s -p "Enter proxy password: " PROXY_PASSWORD
    echo ""
    
    # Validate password is not empty
    while [ -z "$PROXY_PASSWORD" ]; do
        print_error "Password cannot be empty."
        read -s -p "Enter proxy password: " PROXY_PASSWORD
        echo ""
    done
    
    read -s -p "Confirm proxy password: " PROXY_PASSWORD_CONFIRM
    echo ""
    
    while [ "$PROXY_PASSWORD" != "$PROXY_PASSWORD_CONFIRM" ]; do
        print_error "Passwords do not match. Try again."
        read -s -p "Enter proxy password: " PROXY_PASSWORD
        echo ""
        while [ -z "$PROXY_PASSWORD" ]; do
            print_error "Password cannot be empty."
            read -s -p "Enter proxy password: " PROXY_PASSWORD
            echo ""
        done
        read -s -p "Confirm proxy password: " PROXY_PASSWORD_CONFIRM
        echo ""
    done
    
    REQUIRE_AUTH="true"
    print_success "Authentication will be enabled for user '$PROXY_USER'"
else
    if [ "$IP_ALLOWLIST_ENABLED" = "false" ]; then
        print_error "You must enable either IP allowlist or username/password authentication."
        print_error "Otherwise your proxy will be accessible to anyone on the internet."
        exit 1
    fi
    print_info "Authentication disabled — relying on IP allowlist for security."
fi

# Prompt for task idle timeout
print_header "Task Idle Timeout Configuration"

# Try to get current value from existing .env for re-run convenience
CURRENT_TIMEOUT="60"
if [ -f ".env" ]; then
    ENV_TIMEOUT=$(grep -oP '(?<=^TASK_IDLE_TIMEOUT_MINUTES=)\d+' .env 2>/dev/null || echo "")
    [ -n "$ENV_TIMEOUT" ] && CURRENT_TIMEOUT="$ENV_TIMEOUT"
fi

echo ""
print_info "Fargate tasks auto-stop after N minutes of inactivity to save costs."
print_info "Recommended: 30-120 minutes. Set 0 to disable auto-shutdown."
echo ""
read -p "Idle timeout in minutes [${CURRENT_TIMEOUT}]: " TASK_IDLE_TIMEOUT_MINUTES
TASK_IDLE_TIMEOUT_MINUTES="${TASK_IDLE_TIMEOUT_MINUTES:-$CURRENT_TIMEOUT}"

# Validate input is a non-negative integer
while ! [[ "$TASK_IDLE_TIMEOUT_MINUTES" =~ ^[0-9]+$ ]] || [ "$TASK_IDLE_TIMEOUT_MINUTES" -lt 0 ] 2>/dev/null; do
    print_error "Please enter a valid non-negative integer (e.g., 60, 120, or 0 to disable)."
    read -p "Idle timeout in minutes [${CURRENT_TIMEOUT}]: " TASK_IDLE_TIMEOUT_MINUTES
    TASK_IDLE_TIMEOUT_MINUTES="${TASK_IDLE_TIMEOUT_MINUTES:-$CURRENT_TIMEOUT}"
done

if [ "$TASK_IDLE_TIMEOUT_MINUTES" -eq 0 ]; then
    print_info "Auto-shutdown disabled — task will run until manually stopped."
else
    print_success "Tasks will auto-stop after $TASK_IDLE_TIMEOUT_MINUTES minutes of inactivity."
fi

# Deploy CloudFormation stack (create or update)
print_header "Deploying AWS Infrastructure"

STACK_NAME="proxy-fargate-proxy"

# Build parameter list
PARAMS="ParameterKey=EnvironmentName,ParameterValue=proxy"
PARAMS="$PARAMS ParameterKey=TaskIdleTimeoutMinutes,ParameterValue=${TASK_IDLE_TIMEOUT_MINUTES}"
PARAMS="$PARAMS ParameterKey=DualIPRetentionMinutes,ParameterValue=180"

if [ "$IP_ALLOWLIST_ENABLED" = "true" ]; then
    PARAMS="$PARAMS ParameterKey=IPAllowlistEnabled,ParameterValue=true"
    PARAMS="$PARAMS ParameterKey=ClientPublicIP,ParameterValue=${CLIENT_IP}"
else
    PARAMS="$PARAMS ParameterKey=IPAllowlistEnabled,ParameterValue=false"
fi

# Add proxy authentication parameters
if [ "$REQUIRE_AUTH" = "true" ]; then
    PARAMS="$PARAMS ParameterKey=ProxyUsername,ParameterValue=${PROXY_USER}"
    PARAMS="$PARAMS ParameterKey=ProxyPassword,ParameterValue=${PROXY_PASSWORD}"
fi

# Check if stack exists
STACK_EXISTS=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].StackId' \
    --output text 2>/dev/null || echo "")

if [ -z "$STACK_EXISTS" ]; then
    # Create new stack
    print_info "Creating new CloudFormation stack: $STACK_NAME"
    
    aws cloudformation create-stack \
        --stack-name $STACK_NAME \
        --template-body file://fargate-infrastructure.yaml \
        --parameters $PARAMS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION
    
    print_info "Waiting for stack creation..."
    aws cloudformation wait stack-create-complete \
        --stack-name $STACK_NAME \
        --region $REGION
    
    print_success "CloudFormation stack created"
else
    # Update existing stack
    print_info "Updating existing CloudFormation stack: $STACK_NAME"
    
    # Use update-stack; it may return with "No updates to be performed"
    UPDATE_OUTPUT=$(aws cloudformation update-stack \
        --stack-name $STACK_NAME \
        --template-body file://fargate-infrastructure.yaml \
        --parameters $PARAMS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION 2>&1) || true
    
    if echo "$UPDATE_OUTPUT" | grep -q "No updates are to be performed"; then
        print_info "No stack updates needed"
    elif echo "$UPDATE_OUTPUT" | grep -q "StackId"; then
        print_info "Stack update in progress..."
        aws cloudformation wait stack-update-complete \
            --stack-name $STACK_NAME \
            --region $REGION
        print_success "CloudFormation stack updated"
    else
        print_error "Stack update failed"
        echo "$UPDATE_OUTPUT"
        exit 1
    fi
fi

# Extract outputs
print_header "Extracting Infrastructure Details"

CLUSTER_NAME=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' \
    --output text)

TASK_DEF=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`TaskDefinition`].OutputValue' \
    --output text)

SUBNET_ID=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`SubnetId1`].OutputValue' \
    --output text)

SG_ID=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue' \
    --output text)

echo "Cluster Name:      $CLUSTER_NAME"
echo "Task Definition:   $TASK_DEF"
echo "Subnet:            $SUBNET_ID"
echo "Security Group:    $SG_ID"

# Extract IP allowlist outputs (may not exist if condition is false)
ALLOWLIST_ENABLED_OUTPUT=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`IPAllowlistEnabled`].OutputValue' \
    --output text 2>/dev/null || echo "false")

if [ "$ALLOWLIST_ENABLED_OUTPUT" = "true" ]; then
    echo "IP Allowlist:      enabled"
    ALLOWLISTED_IP=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`AllowlistedIP`].OutputValue' \
        --output text 2>/dev/null || echo "")
    [ -n "$ALLOWLISTED_IP" ] && echo "Allowlisted IP:    $ALLOWLISTED_IP"
else
    echo "IP Allowlist:      disabled"
fi

# Create .env file
print_header "Creating Configuration"

# Save current (admin-level) AWS credentials before anything else
SAVED_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
SAVED_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
SAVED_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}"
SAVED_AWS_PROFILE="${AWS_PROFILE}"

# Preserve existing .env values if re-running (selectively, avoid credential overwrite)
if [ -f ".env" ]; then
    print_info "Backing up existing .env to .env.bak"
    cp .env .env.bak
fi

# Restore admin credentials (in case they were overwritten by shell config)
export AWS_ACCESS_KEY_ID="${SAVED_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${SAVED_AWS_SECRET_ACCESS_KEY}"
export AWS_SESSION_TOKEN="${SAVED_AWS_SESSION_TOKEN}"
unset AWS_PROFILE

# Verify we still have admin access
CALLER_ID=$(aws sts get-caller-identity 2>/dev/null || echo "")
if [ -z "$CALLER_ID" ]; then
    # If env vars were unset, try default profile
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    export AWS_PROFILE="${SAVED_AWS_PROFILE:-default}"
    CALLER_ID=$(aws sts get-caller-identity) || {
        print_error "AWS credentials lost during setup"
        echo "Re-run with valid AWS credentials (e.g., aws configure)"
        exit 1
    }
fi
echo "Caller ARN: $(echo $CALLER_ID | jq -r '.Arn')"

# Create restricted IAM user for orchestrator
print_header "Creating Orchestrator IAM User"

ORCHESTRATOR_USER="proxy-orchestrator"

# Look up IAM role names from CloudFormation stack
# First try: describe-stack-resources
EXECUTION_ROLE_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'StackResources[?ResourceType==`AWS::IAM::Role` && LogicalResourceId==`TaskExecutionRole`].PhysicalResourceId' \
    --output text )
echo "first try"
echo "Execution role name: $EXECUTION_ROLE_NAME" 

TASK_ROLE_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'StackResources[?ResourceType==`AWS::IAM::Role` && LogicalResourceId==`TaskRole`].PhysicalResourceId' \
    --output text )

echo "Task role name: $TASK_ROLE_NAME"

# Second try: list IAM roles by stack naming pattern if describe-stack-resources didn't return them
if [ -z "$EXECUTION_ROLE_NAME" ]; then
    EXECUTION_ROLE_NAME=$(aws iam list-roles \
        --query "Roles[?starts_with(RoleName, \`${STACK_NAME}-TaskExecutionRole\`)].RoleName" \
        --output text )
    echo "second try"
    echo "Execution role name: $EXECUTION_ROLE_NAME"
fi

if [ -z "$TASK_ROLE_NAME" ]; then
    TASK_ROLE_NAME=$(aws iam list-roles \
        --query "Roles[?starts_with(RoleName, \`${STACK_NAME}-TaskRole\`) && !starts_with(RoleName, \`${STACK_NAME}-TaskExecutionRole\`)].RoleName" \
        --output text )
    echo "Task role name: $TASK_ROLE_NAME"
fi

if [ -z "$EXECUTION_ROLE_NAME" ] || [ -z "$TASK_ROLE_NAME" ]; then
    print_error "Could not find IAM roles from CloudFormation stack"
    echo ""
    echo "The stack '$STACK_NAME' may not have been created successfully."
    echo "Run the following to check stack status:"
    echo "  aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION"
    echo ""
    echo "Or list the roles manually and update .env with these values:"
    echo "  aws iam list-roles --query \"Roles[?contains(RoleName, \`${STACK_NAME}\`)].RoleName\" --output table"
    exit 1
fi

EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXECUTION_ROLE_NAME}"
TASK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE_NAME}"

echo "Execution role:     $EXECUTION_ROLE_ARN"
echo "Task role:          $TASK_ROLE_ARN"

# Create IAM user (fails silently if already exists)
print_info "Ensuring IAM user '$ORCHESTRATOR_USER' exists..."
aws iam create-user --user-name $ORCHESTRATOR_USER 2>/dev/null && \
    print_success "IAM user created" || \
    print_info "IAM user already exists"

# Attach/update inline policy with least-privilege permissions
print_info "Applying orchestrator permissions policy..."
aws iam put-user-policy \
    --user-name $ORCHESTRATOR_USER \
    --policy-name orchestrator-permissions \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
            {
                \"Sid\": \"ECSManagement\",
                \"Effect\": \"Allow\",
                \"Action\": [
                    \"ecs:ListTasks\",
                    \"ecs:DescribeTasks\",
                    \"ecs:RunTask\",
                    \"ecs:StopTask\",
                    \"ecs:DescribeClusters\",
                    \"ecs:TagResource\"
                ],
                \"Resource\": \"*\"
            },
            {
                \"Sid\": \"EC2Describe\",
                \"Effect\": \"Allow\",
                \"Action\": [
                    \"ec2:DescribeNetworkInterfaces\",
                    \"ec2:DescribeSecurityGroups\",
                    \"ec2:DescribeSecurityGroupRules\"
                ],
                \"Resource\": \"*\"
            },
            {
                \"Sid\": \"SecurityGroupIngressManagement\",
                \"Effect\": \"Allow\",
                \"Action\": [
                    \"ec2:AuthorizeSecurityGroupIngress\",
                    \"ec2:RevokeSecurityGroupIngress\"
                ],
                \"Resource\": \"arn:aws:ec2:${REGION}:${ACCOUNT_ID}:security-group/${SG_ID}\"
            },
            {
                \"Sid\": \"PassRolesToECS\",
                \"Effect\": \"Allow\",
                \"Action\": \"iam:PassRole\",
                \"Resource\": [
                    \"${EXECUTION_ROLE_ARN}\",
                    \"${TASK_ROLE_ARN}\"
                ],
                \"Condition\": {
                    \"StringEquals\": {
                        \"iam:PassedToService\": \"ecs-tasks.amazonaws.com\"
                    }
                }
            }
        ]
    }"
print_success "Permissions policy updated"

# Manage access keys - delete old, create new
print_info "Rotating access keys..."
EXISTING_KEYS=$(aws iam list-access-keys --user-name $ORCHESTRATOR_USER --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || echo "")
for KEY_ID in $EXISTING_KEYS; do
    aws iam delete-access-key --user-name $ORCHESTRATOR_USER --access-key-id $KEY_ID
done

ACCESS_KEY_OUTPUT=$(aws iam create-access-key --user-name $ORCHESTRATOR_USER)
ORCHESTRATOR_ACCESS_KEY=$(echo "$ACCESS_KEY_OUTPUT" | jq -r '.AccessKey.AccessKeyId')
ORCHESTRATOR_SECRET_KEY=$(echo "$ACCESS_KEY_OUTPUT" | jq -r '.AccessKey.SecretAccessKey')

print_success "New access keys created for $ORCHESTRATOR_USER"

cat > .env << EOF
AWS_REGION=$REGION
# Orchestrator uses env-var based auth (IAM user: proxy-orchestrator)
# Do NOT set AWS_PROFILE - it conflicts with env-var credentials in boto3
AWS_ACCESS_KEY_ID=${ORCHESTRATOR_ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${ORCHESTRATOR_SECRET_KEY}
AWS_SESSION_TOKEN=
ECS_CLUSTER=$CLUSTER_NAME
ECS_TASK_DEFINITION=go-socks5-proxy
TASK_SUBNET=$SUBNET_ID
TASK_SECURITY_GROUP=$SG_ID
LOCAL_PROXY_PORT=8080
SOCKS5_PORT=1080
TASK_IDLE_TIMEOUT_MINUTES=$TASK_IDLE_TIMEOUT_MINUTES

# Proxy authentication configuration
REQUIRE_AUTH=${REQUIRE_AUTH:-false}
PROXY_USER=${PROXY_USER:-}
PROXY_PASSWORD=${PROXY_PASSWORD:-}

# IP Allowlist configuration
IP_ALLOWLIST_ENABLED=${IP_ALLOWLIST_ENABLED:-false}
CLIENT_SECURITY_GROUP_ID=${SG_ID}
DUAL_IP_RETENTION_MINUTES=180
EOF

print_success ".env file created"

# Build Docker image
print_header "Building Docker Image"

print_info "Building local proxy image..."
docker compose build

print_success "Docker image built"

# Final instructions
print_header "Setup Complete!"

echo ""
echo -e "${GREEN}You're ready to start!${NC}"
echo ""
echo "Next steps:"
echo ""
echo "1. Start the proxy:"
echo -e "   ${BLUE}./proxy-manage.sh start${NC}"
echo ""
echo "2. Configure your browser proxy:"
echo "   HTTP:  localhost:8080"
echo "   HTTPS: localhost:8080"
echo ""
echo "3. Test it:"
echo -e "   ${BLUE}curl -x http://localhost:8080 http://httpbin.org/ip${NC}"
echo ""
echo "4. Manage the proxy:"
echo -e "   ${BLUE}./proxy-manage.sh status${NC}   # Check status"
echo -e "   ${BLUE}./proxy-manage.sh info${NC}     # Show costs and config"
echo -e "   ${BLUE}./proxy-manage.sh logs${NC}     # View logs"
echo -e "   ${BLUE}./proxy-manage.sh stop${NC}     # Stop proxy (local only)"
echo -e "   ${BLUE}./proxy-manage.sh stop --remote${NC}   # Stop local proxy and remote Fargate task"
echo ""
echo "Estimated cost: ~\$1.20-2.40/month for typical usage"
echo "Tasks auto-stop after ${TASK_IDLE_TIMEOUT_MINUTES:-60} minutes of inactivity"
echo ""
echo "For more info, see README.md and DEPLOYMENT.md"
echo ""
