#!/bin/bash
# Management script for Fargate SOCKS5 proxy
# Usage: ./proxy-manage.sh [start|stop|stop --remote|status|logs|info]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
if [ ! -f ".env" ]; then
    echo -e "${RED}✗ .env file not found${NC}"
    echo "Please run the deployment steps first"
    exit 1
fi

source .env

# Functions
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

start_proxy() {
    print_header "Starting Proxy"
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker not installed"
        exit 1
    fi
    
    print_info "Starting Docker containers..."
    docker compose up -d
    
    print_info "Waiting for orchestrator to initialize..."
    sleep 5
    
    # Check if running
    if docker compose ps | grep -q "proxy-orchestrator"; then
        print_success "Local proxy started"
    else
        print_error "Failed to start local proxy"
        docker compose logs proxy-orchestrator
        exit 1
    fi
    
    # Wait for Fargate task to be ready
    print_info "Waiting for Fargate task to initialize (this may take 30-60 seconds)..."
    
    for i in {1..60}; do
        STATUS=$(curl -s http://localhost:5000/status 2>/dev/null || echo "{}")
        REMOTE_IP=$(echo $STATUS | jq -r '.remote_ip // empty' 2>/dev/null)
        
        if [ ! -z "$REMOTE_IP" ] && [ "$REMOTE_IP" != "null" ] && [ "$REMOTE_IP" != "None" ]; then
            print_success "Remote SOCKS5 proxy ready"
            print_success "Public IP: $REMOTE_IP"
            echo ""
            echo -e "${GREEN}Browser Proxy Configuration:${NC}"
            echo "  HTTP:  localhost:8080"
            echo "  HTTPS: localhost:8080"
            echo ""
            echo -e "${GREEN}Test your IP:${NC}"
            echo "  curl -x http://localhost:8080 http://httpbin.org/ip"
            return 0
        fi
        
        if [ $((i % 10)) -eq 0 ]; then
            print_info "Still waiting... ($i/60 seconds)"
        fi
        sleep 1
    done
    
    print_error "Fargate task failed to initialize"
    docker compose logs proxy-orchestrator
    exit 1
}

stop_remote_task() {
    # Stop Fargate task(s) directly via AWS CLI — works even if local containers are down.
    print_info "Looking for running Fargate tasks..."
    
    TASK_ARNS=$(aws ecs list-tasks \
        --cluster "$ECS_CLUSTER" \
        --desired-status RUNNING \
        --query 'taskArns[]' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$TASK_ARNS" ] || [ "$TASK_ARNS" = "None" ]; then
        print_info "No running Fargate tasks found."
        return 0
    fi
    
    STOPPED=0
    for TASK_ARN in $TASK_ARNS; do
        TASK_ID=$(echo "$TASK_ARN" | awk -F'/' '{print $NF}')
        print_info "Stopping task: $TASK_ID..."
        
        if aws ecs stop-task \
            --cluster "$ECS_CLUSTER" \
            --task "$TASK_ARN" \
            --reason "Manual stop via proxy-manage.sh" \
            --region "$AWS_REGION" \
            --output text > /dev/null 2>&1; then
            print_success "Task $TASK_ID stopped"
            STOPPED=$((STOPPED + 1))
        else
            print_error "Failed to stop task $TASK_ID"
        fi
    done
    
    if [ "$STOPPED" -gt 0 ]; then
        print_success "Stopped $STOPPED Fargate task(s)"
    fi
}

stop_proxy() {
    # Parse optional --remote flag
    STOP_REMOTE=false
    for arg in "$@"; do
        case "$arg" in
            --remote|-r)
                STOP_REMOTE=true
                ;;
        esac
    done
    
    print_header "Stopping Proxy"
    
    # Stop local containers first to prevent the orchestrator from
    # seeing the remote task disappear and trying to restart it.
    if docker compose ps 2>/dev/null | grep -q "proxy-orchestrator"; then
        print_info "Stopping Docker containers..."
        docker compose down
        print_success "Local proxy stopped"
    else
        print_info "Local proxy not running"
    fi
    
    # Then stop the remote Fargate task if --remote was passed
    if [ "$STOP_REMOTE" = true ]; then
        stop_remote_task
    fi
    
    if [ "$STOP_REMOTE" = false ]; then
        print_info "Note: Fargate task will auto-shutdown after ${TASK_IDLE_TIMEOUT_MINUTES:-60} minutes of inactivity"
        print_info "To stop the remote Fargate task immediately, use: ./proxy-manage.sh stop --remote"
    fi
}

show_status() {
    print_header "Proxy Status"
    
    # Check local containers
    if docker compose ps | grep -q "proxy-orchestrator"; then
        print_success "Local proxy: running"
    else
        print_error "Local proxy: not running"
        return 1
    fi
    
    # Check Fargate task
    TASKS=$(aws ecs list-tasks \
        --cluster $ECS_CLUSTER \
        --desired-status RUNNING \
        --query 'taskArns' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$TASKS" ]; then
        print_error "Fargate task: not running"
        return 1
    fi
    
    print_success "Fargate task: running"
    
    # Get remote IP
    ORCHESTRATOR_STATUS=$(curl -s http://localhost:5000/status 2>/dev/null || echo "{}")
    REMOTE_IP=$(echo $ORCHESTRATOR_STATUS | jq -r '.remote_ip // "unknown"' 2>/dev/null)
    
    echo ""
    echo -e "${BLUE}Configuration:${NC}"
    echo "  Local proxy:     localhost:8080"
    echo "  Remote IP:       $REMOTE_IP"
    echo "  Task ARN:        $(echo $ORCHESTRATOR_STATUS | jq -r '.remote_task // "unknown"' 2>/dev/null)"
    echo ""
    echo -e "${BLUE}Quick Test:${NC}"
    echo "  curl -x http://localhost:8080 http://httpbin.org/ip"
}

show_logs() {
    print_header "Proxy Logs"
    
    echo -e "${BLUE}Local Proxy Logs:${NC}"
    docker compose logs proxy-orchestrator
    
    echo ""
    echo -e "${BLUE}Fargate Task Logs (last 50 lines):${NC}"
    aws logs tail /ecs/proxy-socks5-proxy \
        --max-items 50 \
        2>/dev/null || print_info "No Fargate logs yet"
}

show_info() {
    print_header "Proxy Information"
    
    echo -e "${BLUE}Configuration:${NC}"
    echo "  Cluster:            $ECS_CLUSTER"
    echo "  Task Definition:    $ECS_TASK_DEFINITION"
    echo "  Subnet:             $TASK_SUBNET"
    echo "  Security Group:     $TASK_SECURITY_GROUP"
    echo "  Local Port:         $LOCAL_PROXY_PORT"
    echo "  SOCKS5 Port:        $SOCKS5_PORT"
    echo "  Idle Timeout:       $TASK_IDLE_TIMEOUT_MINUTES minutes"
    echo ""
    
    echo -e "${BLUE}AWS Resources:${NC}"
    
    # List tasks
    TASKS=$(aws ecs list-tasks --cluster $ECS_CLUSTER --query 'taskArns[]' --output text 2>/dev/null || echo "none")
    TASK_COUNT=$(echo $TASKS | wc -w)
    echo "  Running tasks:      $TASK_COUNT"
    
    # Estimate cost
    echo ""
    echo -e "${BLUE}Cost Estimate (running):${NC}"
    echo "  vCPU:        \$0.04048/hour (0.25 vCPU)"
    echo "  Memory:      \$0.004445/hour (0.5GB)"
    echo "  Total:       \$0.01207/hour (~\$0.29/day)"
    echo ""
    
    # Data transfer
    echo -e "${BLUE}Important:${NC}"
    echo "  • First 1GB data transfer/month is free"
    echo "  • \$0.12/GB for data transfer after free tier"
    echo "  • Task auto-stops after ${TASK_IDLE_TIMEOUT_MINUTES}min idle"
    echo ""
}

check_health() {
    print_header "Health Check"
    
    # Test local proxy
    if curl -s http://localhost:8080 >/dev/null 2>&1; then
        print_success "Local proxy: responding"
    else
        print_error "Local proxy: not responding"
        return 1
    fi
    
    # Test orchestrator API
    if curl -s http://localhost:5000/status >/dev/null 2>&1; then
        print_success "Orchestrator: responding"
    else
        print_error "Orchestrator: not responding"
        return 1
    fi
    
    # Test SOCKS5 through proxy
    RESULT=$(curl -s -x http://localhost:8080 http://httpbin.org/ip 2>/dev/null || echo "{}")
    if echo "$RESULT" | jq . >/dev/null 2>&1; then
        print_success "SOCKS5 proxy: responding"
        ORIGIN_IP=$(echo "$RESULT" | jq -r '.origin' 2>/dev/null)
        if [ ! -z "$ORIGIN_IP" ]; then
            echo "  Your external IP: $ORIGIN_IP"
        fi
    else
        print_error "SOCKS5 proxy: not responding"
        return 1
    fi
}

# Main
case "${1:-status}" in
    start)
        start_proxy
        ;;
    stop)
        # Pass any additional arguments (e.g., --remote) to stop_proxy
        shift 1
        stop_proxy "$@"
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    info)
        show_info
        ;;
    health)
        check_health
        ;;
    *)
        echo "Fargate SOCKS5 Proxy Manager"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  start    - Start local proxy and orchestrate Fargate task"
        echo "  stop     - Stop local proxy (Fargate auto-shuts down after idle)"
        echo "  stop --remote - Stop local proxy AND remote Fargate task immediately"
        echo "  status   - Show proxy status and configuration"
        echo "  logs     - Show proxy logs"
        echo "  info     - Show detailed information and costs"
        echo "  health   - Check proxy health"
        echo ""
        exit 1
        ;;
esac
