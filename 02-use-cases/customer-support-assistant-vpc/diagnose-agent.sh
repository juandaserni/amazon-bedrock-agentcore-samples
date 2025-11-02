#!/bin/bash

################################################################################
# Agent Diagnostics Tool
#
# This script checks all dependencies and configuration
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
ENVIRONMENT="dev"

print_header "Agent Diagnostic Report"

# 1. Check all stacks
print_header "1. CloudFormation Stacks Status"
for stack in vpc config cognito dynamodb mcp gateway agent; do
    stack_name="customer-support-vpc-neon-${stack}-${ENVIRONMENT}"
    status=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$status" = "CREATE_COMPLETE" ] || [ "$status" = "UPDATE_COMPLETE" ]; then
        print_success "$stack: $status"
    else
        print_error "$stack: $status"
    fi
done

# 2. Check SSM Parameters
print_header "2. SSM Parameters Check"
params=(
    "/app/customersupportvpc/agentcore/agent_runtime_arn"
    "/app/customersupportvpc/gateway/gateway_url"
    "/app/customersupportvpc/mcp/mcp_runtime_arn"
    "/app/customersupportvpc/neon/host"
)

for param in "${params[@]}"; do
    value=$(aws ssm get-parameter \
        --name "$param" \
        --region "$REGION" \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || echo "MISSING")
    
    if [ "$value" != "MISSING" ]; then
        print_success "$(basename $param): Found"
    else
        print_error "$(basename $param): MISSING"
    fi
done

# 3. Check Neon Secret
print_header "3. Neon Database Credentials"
secret=$(aws secretsmanager get-secret-value \
    --secret-id /app/customersupportvpc/neon/credentials \
    --region "$REGION" \
    --query 'SecretString' \
    --output text 2>/dev/null || echo "MISSING")

if [ "$secret" != "MISSING" ]; then
    print_success "Neon credentials found"
    echo "$secret" | jq -r '.host' | sed 's/^/  Host: /'
else
    print_error "Neon credentials missing"
fi

# 4. Check Agent Runtime
print_header "4. Agent Runtime Status"
AGENT_ARN=$(aws ssm get-parameter \
    --name /app/customersupportvpc/agentcore/agent_runtime_arn \
    --region "$REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null)

if [ -n "$AGENT_ARN" ]; then
    print_success "Agent ARN: $AGENT_ARN"
    
    RUNTIME_ID=$(echo "$AGENT_ARN" | awk -F'/' '{print $NF}')
    print_info "Runtime ID: $RUNTIME_ID"
    
    # Check recent logs
    print_info "Checking recent logs..."
    aws logs tail "/aws/vendedlogs/bedrock-agentcore/${RUNTIME_ID}" \
        --since 5m \
        --region "$REGION" 2>/dev/null | tail -5 || print_warning "No recent logs"
else
    print_error "Agent ARN not found"
fi

# 5. Check ECR Image
print_header "5. Docker Image Status"
ECR_REPO=$(aws cloudformation describe-stack-resources \
    --stack-name "customer-support-vpc-neon-agent-${ENVIRONMENT}" \
    --region "$REGION" \
    --query 'StackResources[?ResourceType==`AWS::ECR::Repository`].PhysicalResourceId' \
    --output text 2>/dev/null)

if [ -n "$ECR_REPO" ]; then
    print_success "ECR Repository: $ECR_REPO"
    
    # Get latest image
    LATEST_IMAGE=$(aws ecr describe-images \
        --repository-name "$ECR_REPO" \
        --region "$REGION" \
        --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imageTags[0],imagePushedAt]' \
        --output text 2>/dev/null)
    
    if [ -n "$LATEST_IMAGE" ]; then
        TAG=$(echo "$LATEST_IMAGE" | awk '{print $1}')
        DATE=$(echo "$LATEST_IMAGE" | awk '{print $2}')
        print_info "Latest image: $TAG (pushed: $DATE)"
    fi
else
    print_error "ECR Repository not found"
fi

# 6. Test Agent Endpoint
print_header "6. Agent Endpoint Test"
if [ -n "$AGENT_ARN" ]; then
    print_info "Testing agent endpoint..."
    
    # This will show if we get 424 or other errors
    ESCAPED_ARN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$AGENT_ARN', safe=''))")
    ENDPOINT="https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/${ESCAPED_ARN}/invocations?qualifier=DEFAULT"
    
    print_info "Endpoint: $ENDPOINT"
    print_warning "Note: Endpoint test requires valid bearer token"
fi

# Summary
print_header "Summary & Recommendations"

# Check if critical parameters are missing
GATEWAY_URL=$(aws ssm get-parameter \
    --name /app/customersupportvpc/gateway/gateway_url \
    --region "$REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || echo "")
    
MCP_ARN=$(aws ssm get-parameter \
    --name /app/customersupportvpc/mcp/mcp_runtime_arn \
    --region "$REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || echo "")

if [ -z "$GATEWAY_URL" ] || [ -z "$MCP_ARN" ]; then
    print_error "CRITICAL: Gateway or MCP parameters missing!"
    echo ""
    echo "This causes HTTP 424 errors. The agent cannot initialize without these."
    echo ""
    echo "Solution:"
    echo "  1. Verify Gateway stack completed: aws cloudformation describe-stacks --stack-name customer-support-vpc-neon-gateway-${ENVIRONMENT} --region ${REGION}"
    echo "  2. Verify MCP stack completed: aws cloudformation describe-stacks --stack-name customer-support-vpc-neon-mcp-${ENVIRONMENT} --region ${REGION}"
    echo "  3. Check stack outputs contain the SSM parameters"
    echo ""
fi

# Check if prompt.py exists in source
if [ ! -f "agent/prompt.py" ]; then
    print_error "CRITICAL: agent/prompt.py missing from source!"
    echo ""
    echo "The agent cannot start without this file."
    echo ""
    echo "Solution:"
    echo "  File exists at: $(pwd)/agent/prompt.py"
    echo "  But needs to be in git and Docker image rebuilt"
    echo "  Run: ./rebuild-agent.sh"
    echo ""
fi

echo ""
print_info "Diagnostic complete. Review errors above and apply fixes."
