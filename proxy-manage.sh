#!/bin/bash
# Management script for Fargate SOCKS5 proxy
# Usage: ./proxy-manage.sh [start|start --remote|start --no-remote|stop|stop --remote|status|logs|info]

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

container_is_up() {
    # True if the container with this name exists and is actually running
    # (not just "Created" or "Exited" — docker compose ps would match those too)
    [ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" = "running" ]
}

start_proxy() {
    print_header "Starting Proxy"
    
    # Remote auto-start is controlled by AUTO_START_REMOTE (from .env, sourced
    # above, or the compose default). It can be overridden per run:
    #   --no-remote / -n  force OFF (local proxy only)
    #   --remote    / -r  force ON  (start the remote Fargate task now)
    for arg in "$@"; do
        case "$arg" in
            --no-remote|-n)
                AUTO_START_REMOTE=false
                ;;
            --remote|-r)
                AUTO_START_REMOTE=true
                ;;
        esac
    done
    # If no flag was given, use the configured value (default off).
    AUTO_START_REMOTE="${AUTO_START_REMOTE:-false}"
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker not installed"
        exit 1
    fi
    
    print_info "Starting Docker containers..."
    AUTO_START_REMOTE=$AUTO_START_REMOTE docker compose up -d
    
    print_info "Waiting for orchestrator to initialize..."
    sleep 5
    
    # Check if running
    if container_is_up proxy-orchestrator && container_is_up http-proxy; then
        print_success "Local proxy started"
    else
        print_error "Failed to start local proxy"
        docker compose ps
        docker compose logs --tail 30 proxy-orchestrator http-proxy
        exit 1
    fi
    
    # If remote auto-start is disabled, we're done — do not wait for Fargate
    if [ "$AUTO_START_REMOTE" = false ]; then
        print_success "Remote SOCKS5 proxy NOT started (AUTO_START_REMOTE=false)"
        echo ""
        echo -e "${GREEN}Start the remote later when needed:${NC}"
        echo "  ./proxy-manage.sh start --remote         # recreate containers, start remote"
        echo "  curl -X POST http://localhost:5000/start # start remote now, no container recreation"
        echo ""
        echo -e "${BLUE}Note:${NC} traffic sent through localhost:8080 will wake the remote on demand."
        return 0
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
    docker compose logs --tail 50 proxy-orchestrator http-proxy
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
    if container_is_up proxy-orchestrator || container_is_up http-proxy; then
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
    LOCAL_OK=true
    if container_is_up http-proxy; then
        print_success "Local proxy (http-proxy): running"
    else
        print_error "Local proxy (http-proxy): not running"
        LOCAL_OK=false
    fi
    if container_is_up proxy-orchestrator; then
        print_success "Orchestrator: running"
    else
        print_error "Orchestrator: not running"
        LOCAL_OK=false
    fi
    if [ "$LOCAL_OK" = false ]; then
        return 1
    fi
    
    # AUTO_START_REMOTE baked into the orchestrator container at creation — this
    # is the value that survives container restarts (host reboot, crash, etc.).
    ORCH_AUTO_START=$(docker inspect proxy-orchestrator \
        --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep '^AUTO_START_REMOTE=' | cut -d= -f2 | tail -1)
    ORCH_AUTO_START="${ORCH_AUTO_START:-true}"
    echo "  Remote auto-start: $ORCH_AUTO_START   # survives container restarts"
    
    # Check Fargate task
    TASKS=$(aws ecs list-tasks \
        --cluster $ECS_CLUSTER \
        --region $AWS_REGION \
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
    
    # Idle/activity info from the http-proxy container
    PROXY_HEALTH=$(docker exec http-proxy wget -q -T 5 -O - http://127.0.0.1:8081/health 2>/dev/null || echo "{}")
    WAKE_STATE=$(echo "$PROXY_HEALTH" | jq -r '.wakeState // "unknown"' 2>/dev/null)
    IDLE_SECONDS=$(echo "$PROXY_HEALTH" | jq -r '.idleForSeconds // empty' 2>/dev/null)
    ACTIVE_CONNS=$(echo "$PROXY_HEALTH" | jq -r '.activeConnections // 0' 2>/dev/null)
    IDLE_TIMEOUT_MINS=$(echo "$ORCHESTRATOR_STATUS" | jq -r '.idle_timeout_minutes // "unknown"' 2>/dev/null)

    if [[ "$IDLE_SECONDS" =~ ^[0-9]+$ ]]; then
        if [ "$IDLE_SECONDS" -ge 3600 ]; then
            IDLE_DISPLAY="$(awk "BEGIN {printf \"%.1f h\", $IDLE_SECONDS/3600}")"
        elif [ "$IDLE_SECONDS" -ge 60 ]; then
            IDLE_DISPLAY="$(awk "BEGIN {printf \"%.1f min\", $IDLE_SECONDS/60}")"
        else
            IDLE_DISPLAY="${IDLE_SECONDS} s"
        fi
    else
        IDLE_DISPLAY="unknown"
    fi

    echo ""
    echo -e "${BLUE}Configuration:${NC}"
    echo "  Local proxy:     localhost:8080"
    echo "  Remote IP:       $REMOTE_IP"
    echo "  Task ARN:        $(echo $ORCHESTRATOR_STATUS | jq -r '.remote_task // "unknown"' 2>/dev/null)"
    echo "  Wake state:      $WAKE_STATE"
    echo "  Idle for:        $IDLE_DISPLAY"
    echo "  Active conns:    $ACTIVE_CONNS"
    echo "  Idle timeout:    ${IDLE_TIMEOUT_MINS} min"
    echo ""
    echo -e "${BLUE}Quick Test:${NC}"
    echo "  curl -x http://localhost:8080 http://httpbin.org/ip"
}

show_logs() {
    print_header "Proxy Logs"
    
    echo -e "${BLUE}Local Proxy Logs (http-proxy):${NC}"
    docker compose logs http-proxy
    
    echo ""
    echo -e "${BLUE}Orchestrator Logs:${NC}"
    docker compose logs proxy-orchestrator
    
    echo ""
    echo -e "${BLUE}Fargate Task Logs (last 50 lines):${NC}"
    aws logs tail /ecs/proxy-socks5-proxy \
        --region "$AWS_REGION" \
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
    TASKS=$(aws ecs list-tasks --cluster $ECS_CLUSTER --region $AWS_REGION --query 'taskArns[]' --output text 2>/dev/null || echo "none")
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

# Return the proxy's outbound IP by trying several IP echo services.
# Any single service (e.g. httpbin.org) may be down — that does not mean the
# proxy is broken. Prints the IP on success, nothing on failure.
get_proxy_origin_ip() {
    for IP_URL in \
        "http://httpbin.org/ip" \
        "https://api.ipify.org" \
        "https://checkip.amazonaws.com"; do
        RESPONSE=$(curl -s --max-time 10 -x http://localhost:8080 "$IP_URL" 2>/dev/null || true)
        # JSON services: {"origin":"1.2.3.4"} or {"ip":"1.2.3.4"}
        IP=$(echo "$RESPONSE" | jq -r '.origin // .ip // empty' 2>/dev/null | tr -d '[:space:]')
        if [ -z "$IP" ]; then
            # Plain-text services: response is just the IP
            IP=$(echo "$RESPONSE" | tr -d '[:space:]')
            if ! echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
                IP=""
            fi
        fi
        if [ -n "$IP" ]; then
            echo "$IP"
            return 0
        fi
    done
    return 1
}

check_health() {
    print_header "Health Check"
    
    # Test local proxy
    if curl -s --max-time 5 http://localhost:8080 >/dev/null 2>&1; then
        print_success "Local proxy: responding"
    else
        print_error "Local proxy: not responding"
        return 1
    fi
    
    # Test orchestrator API
    if curl -s --max-time 5 http://localhost:5000/status >/dev/null 2>&1; then
        print_success "Orchestrator: responding"
    else
        print_error "Orchestrator: not responding"
        return 1
    fi
    
    # Test SOCKS5 through proxy (bounded so a stalled upstream can't hang us,
    # and resilient to any single echo service being down)
    ORIGIN_IP=$(get_proxy_origin_ip || echo "")
    if [ -n "$ORIGIN_IP" ]; then
        print_success "SOCKS5 proxy: responding"
        echo "  Your external IP: $ORIGIN_IP"
    else
        print_error "SOCKS5 proxy: not responding"
        return 1
    fi
}

# Main
case "${1:-status}" in
    start)
        # Pass any additional arguments (e.g., --no-remote) to start_proxy
        shift 1
        start_proxy "$@"
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
        echo "  start    - Start local proxy (remote start per AUTO_START_REMOTE)"
        echo "  start --no-remote - Start local proxy WITHOUT auto-starting remote Fargate task"
        echo "  start --remote - Start local proxy AND auto-start remote Fargate task"
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
