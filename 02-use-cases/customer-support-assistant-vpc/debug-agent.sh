#!/bin/bash

################################################################################
# Comprehensive Agent Debugging Tool
#
# This script performs deep debugging of the agent runtime
################################################################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }

REGION="us-west-2"

print_header "Deep Agent Debugging Report"

# Get Agent Runtime ARN
AGENT_RUNTIME_ARN=$(aws ssm get-parameter \
    --name /app/customersupportvpc/agentcore/agent_runtime_arn \
    --region "$REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null)

if [ -z "$AGENT_RUNTIME_ARN" ]; then
    print_error "Could not find agent runtime ARN"
    exit 1
fi

RUNTIME_ID=$(echo "$AGENT_RUNTIME_ARN" | awk -F'/' '{print $NF}')
print_info "Agent Runtime ID: $RUNTIME_ID"

# 1. Check current runtime configuration
print_header "1. Runtime Configuration"

RUNTIME_CONFIG=$(aws bedrock-agentcore get-agent-runtime \
    --agent-runtime-id "$RUNTIME_ID" \
    --region "$REGION" 2>&1)

if echo "$RUNTIME_CONFIG" | grep -q "Could not connect"; then
    print_error "AWS CLI doesn't support bedrock-agentcore yet"
    print_warning "Skipping runtime config check"
else
    echo "$RUNTIME_CONFIG" | jq '.' || echo "$RUNTIME_CONFIG"
fi

# 2. Check what Docker image the runtime is using
print_header "2. Current Docker Image"

# Try to extract from AWS CLI output
CURRENT_IMAGE=$(echo "$RUNTIME_CONFIG" | jq -r '.agentRuntimeArtifact.containerConfiguration.containerUri' 2>/dev/null || echo "Unable to retrieve")
print_info "Current Image: $CURRENT_IMAGE"

# 3. Check latest ECR image
print_header "3. Latest ECR Images"

ECR_REPO=$(aws cloudformation describe-stack-resources \
    --stack-name customer-support-vpc-neon-agent-dev \
    --region "$REGION" \
    --query 'StackResources[?ResourceType==`AWS::ECR::Repository`].PhysicalResourceId' \
    --output text 2>/dev/null)

if [ -n "$ECR_REPO" ]; then
    print_info "ECR Repository: $ECR_REPO"
    
    # Get last 5 images
    aws ecr describe-images \
        --repository-name "$ECR_REPO" \
        --region "$REGION" \
        --query 'sort_by(imageDetails,&imagePushedAt)[-5:].[imageTags[0],imagePushedAt]' \
        --output table
fi

# 4. Get detailed agent logs with error filtering
print_header "4. Recent Agent Logs (Last 30 Minutes)"

print_info "Fetching logs..."
echo ""

aws logs filter-log-events \
    --log-group-name "/aws/vendedlogs/bedrock-agentcore/${RUNTIME_ID}" \
    --start-time $(($(date +%s - 1800) * 1000)) \
    --region "$REGION" \
    --query 'events[*].message' \
    --output text 2>/dev/null | \
    while IFS= read -r line; do
        # Try to parse as JSON
        parsed=$(echo "$line" | jq -r 'if type == "object" then 
            "\(.event_timestamp // .timestamp // "???") | \(.service_name // "AgentCore") | \(.operation // "???")" 
        else . end' 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            echo "$parsed"
        else
            echo "$line"
        fi
    done | tail -20

# 5. Check for Python errors in logs
print_header "5. Searching for Errors in Logs"

ERROR_LOGS=$(aws logs filter-log-events \
    --log-group-name "/aws/vendedlogs/bedrock-agentcore/${RUNTIME_ID}" \
    --start-time $(($(date +%s - 3600) * 1000)) \
    --filter-pattern "?ERROR ?Exception ?Traceback ?Failed" \
    --region "$REGION" \
    --query 'events[*].message' \
    --output text 2>/dev/null)

if [ -n "$ERROR_LOGS" ]; then
    print_error "Found errors in logs:"
    echo "$ERROR_LOGS" | tail -20
else
    print_success "No obvious errors found in logs"
fi

# 6. Check EventBridge rule status
print_header "6. EventBridge Automation Status"

RULE_NAME="csvpc-neon-dev-agent-ecr-push-rule"
RULE_STATUS=$(aws events describe-rule \
    --name "$RULE_NAME" \
    --region "$REGION" \
    --query 'State' \
    --output text 2>/dev/null)

if [ "$RULE_STATUS" = "ENABLED" ]; then
    print_success "EventBridge rule is enabled"
else
    print_error "EventBridge rule status: $RULE_STATUS"
fi

# 7. Check Lambda function logs
print_header "7. Lambda Function Logs (ECR Notification)"

LAMBDA_NAME="csvpc-neon-dev-agent-ecr-notification"
print_info "Checking Lambda: $LAMBDA_NAME"

aws logs tail "/aws/lambda/$LAMBDA_NAME" \
    --since 1h \
    --region "$REGION" 2>/dev/null | head -30 || print_warning "No recent Lambda logs"

# 8. Test network connectivity from runtime
print_header "8. Network Configuration Check"

# Get VPC config
VPC_ID=$(aws cloudformation describe-stack-resources \
    --stack-name customer-support-vpc-neon-vpc-dev \
    --region "$REGION" \
    --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' \
    --output text 2>/dev/null)

if [ -n "$VPC_ID" ]; then
    print_info "VPC ID: $VPC_ID"
    
    # Check NAT Gateway
    NAT_STATUS=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$VPC_ID" \
        --region "$REGION" \
        --query 'NatGateways[*].[NatGatewayId,State]' \
        --output text 2>/dev/null)
    
    if [ -n "$NAT_STATUS" ]; then
        print_success "NAT Gateway found"
        echo "$NAT_STATUS"
    else
        print_error "No NAT Gateway found - agent cannot reach internet!"
    fi
fi

# 9. Check SSM parameters the agent needs
print_header "9. Required SSM Parameters"

params=(
    "/app/customersupportvpc/gateway/gateway_url"
    "/app/customersupportvpc/mcp/mcp_runtime_arn"
)

for param in "${params[@]}"; do
    value=$(aws ssm get-parameter \
        --name "$param" \
        --region "$REGION" \
        --query 'Parameter.Value' \
        --output text 2>/dev/null)
    
    if [ -n "$value" ]; then
        print_success "$(basename $param): $value"
    else
        print_error "$(basename $param): MISSING"
    fi
done

# 10. Recommendations
print_header "10. Debugging Recommendations"

echo "Based on the analysis above, try these steps:"
echo ""
echo "1. If you see 'ImportError' or 'ModuleNotFoundError':"
echo "   → Check agent/main.py imports are correct"
echo "   → Verify prompt.py import conflict is fixed"
echo ""
echo "2. If you see '424' or 'Failed Dependency':"
echo "   → Check Gateway/MCP SSM parameters exist"
echo "   → Verify agent can reach external services"
echo ""
echo "3. If you see 'ConnectionError' or 'Timeout':"
echo "   → Verify NAT Gateway is in 'available' state"
echo "   → Check security group allows outbound internet"
echo ""
echo "4. If logs show successful initialization but no response:"
echo "   → Try: git status (check if main.py changes are committed)"
echo "   → Run: ./rebuild-agent.sh (rebuild with latest code)"
echo ""
echo "5. To view live logs:"
echo "   aws logs tail \"/aws/vendedlogs/bedrock-agentcore/${RUNTIME_ID}\" \\"
echo "     --follow --region $REGION"
echo ""
print_info "If you still see issues, share the output of sections 4, 5, and 7 above"
