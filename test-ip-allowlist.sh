#!/bin/bash
# Test script for IP allowlist dual-IP retention
# Tests the orchestrator's IP change detection and security group management
# without requiring an actual IP change.
#
# Usage: ./test-ip-allowlist.sh [orchestrator_url]
# Default: http://localhost:5000

set -e

ORCHESTRATOR_URL="${1:-http://localhost:5000}"
STACK_NAME="proxy-fargate-proxy"
REGION="${AWS_REGION:-us-east-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ PASS:${NC} $1"; }
fail() { echo -e "${RED}✗ FAIL:${NC} $1"; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

# Step 1: Check IP allowlist is enabled
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "TEST: IP Allowlist Dual-IP Retention"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get initial status
info "Checking initial IP allowlist status..."
STATUS=$(curl -s "$ORCHESTRATOR_URL/ip/status" 2>/dev/null || echo '{"ip_allowlist_enabled": false}')

if [ "$(echo "$STATUS" | jq -r '.ip_allowlist_enabled // false')" != "true" ]; then
    fail "IP allowlist is not enabled. Run setup.sh with IP allowlist enabled first."
    exit 1
fi

INITIAL_IP=$(echo "$STATUS" | jq -r '.current_local_ip // "unknown"')
info "Initial IP: $INITIAL_IP"
pass "IP allowlist is enabled"

# Get SG ID from stack outputs
info "Looking up security group ID..."
SG_ID=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue' \
    --output text 2>/dev/null || echo "")

if [ -z "$SG_ID" ]; then
    fail "Could not find security group ID from stack $STACK_NAME"
    exit 1
fi
info "Security Group: $SG_ID"

# Function to list current SG rules for port 1080
list_sg_rules() {
    aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$SG_ID" \
        --region $REGION \
        --query 'SecurityGroupRules[?FromPort==`1080` && IsEgress==`false`].[CidrIpv4,Description]' \
        --output table 2>/dev/null || echo "No rules found"
}

# Step 2: Show current SG rules
echo ""
info "Current SG rules for port 1080:"
list_sg_rules
echo ""

# Step 3: Simulate IP change to a test IP
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "TEST 1: Simulate IP change to 203.0.113.1"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RESULT=$(curl -s -X POST "$ORCHESTRATOR_URL/ip/simulate-change" \
    -H 'Content-Type: application/json' \
    -d '{"new_ip": "203.0.113.1"}')

if [ "$(echo "$RESULT" | jq -r '.status')" != "success" ]; then
    fail "Simulated IP change failed: $(echo "$RESULT" | jq -r '.message')"
    exit 1
fi

pass "Simulated change to 203.0.113.1"
info "Orchestrator now tracking:"
echo "$RESULT" | jq '{current_local_ip, previous_local_ip}'

echo ""
info "SG rules should now include 203.0.113.1:"
list_sg_rules

# Step 4: Simulate another IP change (tests dual-IP retention)
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "TEST 2: Change again to 203.0.113.2 (dual-IP)"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RESULT2=$(curl -s -X POST "$ORCHESTRATOR_URL/ip/simulate-change" \
    -H 'Content-Type: application/json' \
    -d '{"new_ip": "203.0.113.2"}')

if [ "$(echo "$RESULT2" | jq -r '.status')" != "success" ]; then
    fail "Second simulated IP change failed"
    exit 1
fi

pass "Simulated change to 203.0.113.2"
CURRENT_IP=$(echo "$RESULT2" | jq -r '.current_local_ip')
PREVIOUS_IP=$(echo "$RESULT2" | jq -r '.previous_local_ip')

echo ""
info "Orchestrator state:"
echo "$RESULT2" | jq '{current_local_ip, previous_local_ip}'

if [ "$PREVIOUS_IP" = "203.0.113.1" ] && [ "$CURRENT_IP" = "203.0.113.2" ]; then
    pass "Dual-IP tracking working: previous=$PREVIOUS_IP, current=$CURRENT_IP"
else
    fail "Dual-IP tracking unexpected state: previous=$PREVIOUS_IP, current=$CURRENT_IP"
fi

echo ""
info "SG rules should now include BOTH 203.0.113.1 AND 203.0.113.2:"
echo ""
list_sg_rules

# Verify both IPs are in the SG
RULE_COUNT=$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$SG_ID" \
    --region $REGION \
    --query 'SecurityGroupRules[?FromPort==`1080` && IsEgress==`false` && (CidrIpv4==`203.0.113.1/32` || CidrIpv4==`203.0.113.2/32`)] | length(@)' \
    --output text)

if [ "$RULE_COUNT" -ge 2 ]; then
    pass "Both IPs (203.0.113.1 and 203.0.113.2) found in security group"
else
    fail "Expected 2+ rules, found $RULE_COUNT. Dual-IP may not be working."
fi

# Step 5: Test force cleanup (simulates 180-min retention expiry)
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "TEST 3: Force cleanup of old IP (retention expiry)"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RESULT3=$(curl -s -X POST "$ORCHESTRATOR_URL/ip/simulate-change" \
    -H 'Content-Type: application/json' \
    -d '{"new_ip": "203.0.113.3", "force_cleanup": true}')

if [ "$(echo "$RESULT3" | jq -r '.status')" != "success" ]; then
    fail "Force cleanup test failed"
    exit 1
fi

CURRENT_IP3=$(echo "$RESULT3" | jq -r '.current_local_ip')
PREVIOUS_IP3=$(echo "$RESULT3" | jq -r '.previous_local_ip')

echo ""
info "Orchestrator state after cleanup:"
echo "$RESULT3" | jq '{current_local_ip, previous_local_ip, force_cleanup_applied}'

if [ "$PREVIOUS_IP3" = "null" ]; then
    pass "Previous IP cleaned up (simulated retention expiry)"
else
    info "Previous IP still present (expected if no old IP was tracked)"
fi

echo ""
info "SG rules after cleanup (should only have 203.0.113.3):"
echo ""
list_sg_rules

# Step 6: Restore original IP
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "TEST 4: Restore original IP"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$INITIAL_IP" != "unknown" ] && [ "$INITIAL_IP" != "null" ]; then
    RESULT4=$(curl -s -X POST "$ORCHESTRATOR_URL/ip/simulate-change" \
        -H 'Content-Type: application/json' \
        -d "{\"new_ip\": \"$INITIAL_IP\", \"force_cleanup\": true}")
    
    if [ "$(echo "$RESULT4" | jq -r '.status')" = "success" ]; then
        pass "Restored original IP: $INITIAL_IP"
    else
        fail "Failed to restore original IP"
    fi
else
    info "Skipping restore (no initial IP tracked)"
fi

# Summary
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "TEST SUMMARY"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo -e "To verify in AWS Console:"
echo -e "  ${BLUE}AWS Console → EC2 → Security Groups → $SG_ID${NC}"
echo -e "  ${BLUE}Check Inbound Rules for port 1080${NC}"
echo ""
echo -e "Via CLI:"
echo -e "  ${BLUE}aws ec2 describe-security-group-rules \\${NC}"
echo -e "  ${BLUE}  --filters Name=group-id,Values=$SG_ID \\${NC}"
echo -e "  ${BLUE}  --region $REGION \\${NC}"
echo -e "  ${BLUE}  --query 'SecurityGroupRules[?FromPort==\`1080\` && IsEgress==\`false\`]'${NC}"
echo ""
echo "Note: Test IPs (203.0.113.x) are from RFC 5737 (documentation range)."
echo "After testing, run the following to clean up any remaining test IPs:"
echo ""
echo -e "  ${YELLOW}curl -X POST $ORCHESTRATOR_URL/ip/check${NC}"
echo -e "  (This will re-detect your real IP and update the SG)"
echo ""
