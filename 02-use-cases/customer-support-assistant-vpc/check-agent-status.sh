#!/bin/bash

################################################################################
# Agent Status Checker
# This script checks all aspects of the agent deployment and identifies issues
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
ISSUES_FOUND=0

print_header "Agent Status Diagnostic Report"

# Check 1: Git Status
print_header "1. Git Repository Status"

cd /home/juandaserni/Documents/amazon-bedrock-agentcore-samples

GIT_STATUS=$(git status --short 02-use-cases/customer-support-assistant-vpc/agent/ 2>/dev/null)

if [ -n "$GIT_STATUS" ]; then
    print_error "CRITICAL: Agent code changes NOT committed to GitHub!"
    echo "$GIT_STATUS"
    print_warning "CodeBuild pulls from GitHub - your local fixes won't be in the Docker image"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    
    echo ""
    print_info "To fix, run:"
    echo "  git add 02-use-cases/customer-support-assistant-vpc/agent/"
    echo "  git commit -m 'Fix: Agent code updates'"
    echo "  git push origin main"
else
    print_success "Agent code is committed to GitHub"
fi

# Check 2: Agent Logs for Errors
print_header "2. Agent Runtime Logs (Last 30 minutes)"

RUNTIME_ID="csvpcAgentRuntimeNeon-gXSm9F8HVd"

ERROR_LOGS=$(aws logs filter-log-events \
    --log-group-name "/aws/vendedlogs/bedrock-agentcore/${RUNTIME_ID}" \
    --start-time $(($(date +%s - 1800) * 1000)) \
    --filter-pattern "?ERROR ?Exception ?Traceback ?ImportError ?ModuleNotFoundError" \
    --region "$REGION" \
    --query 'events[*].message' \
    --output text 2>/dev/null | tail -10)

if [ -n "$ERROR_LOGS" ]; then
    print_error "Errors found in agent logs:"
    echo "$ERROR_LOGS"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    
    if echo "$ERROR_LOGS" | grep -q "ImportError\|ModuleNotFoundError"; then
        print_warning "Likely cause: Python import error (prompt conflict)"
    fi
else
    # Check if there are ANY logs
    ANY_LOGS=$(aws logs filter-log-events \
        --log-group-name "/aws/vendedlogs/bedrock-agentcore/${RUNTIME_ID}" \
        --start-time $(($(date +%s - 1800) * 1000)) \
        --region "$REGION" \
        --query 'events[*].message' \
        --output text 2>/dev/null | wc -l)
    
    if [ "$ANY_LOGS" -eq 0 ]; then
        print_warning "No logs found in last 30 minutes - agent may not be running"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    else
        print_success "No obvious errors in recent logs"
    fi
fi

# Check 3: Lambda Update Status
print_header "3. Lambda Runtime Update Status"

LAMBDA_LOGS=$(aws logs tail "/aws/lambda/csvpc-neon-dev-agent-ecr-notification" \
    --since 2h \
    --region "$REGION" 2>/dev/null | tail -20)

if echo "$LAMBDA_LOGS" | grep -q "Runtime updated successfully"; then
    print_success "Lambda successfully updated runtime recently"
elif echo "$LAMBDA_LOGS" | grep -q "ValidationException\|Error"; then
    print_error "Lambda encountered errors updating runtime"
    echo "$LAMBDA_LOGS" | grep -i "error\|exception" | tail -5
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
else
    print_warning "No recent Lambda update activity"
fi

# Check 4: Network Configuration
print_header "4. Network Configuration"

NAT_STATUS=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:Name,Values=*neon*" \
    --region "$REGION" \
    --query 'NatGateways[*].[NatGatewayId,State]' \
    --output text 2>/dev/null)

if [ -n "$NAT_STATUS" ]; then
    if echo "$NAT_STATUS" | grep -q "available"; then
        print_success "NAT Gateway is available"
    else
        print_error "NAT Gateway not in available state: $NAT_STATUS"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
else
    print_error "No NAT Gateway found - agent cannot reach internet!"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Check 5: Latest Docker Image
print_header "5. Docker Image Status"

LATEST_IMAGE=$(aws ecr describe-images \
    --repository-name csvpc-neon-dev-agent-repository \
    --region "$REGION" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imageTags[0],imagePushedAt]' \
    --output text 2>/dev/null)

if [ -n "$LATEST_IMAGE" ]; then
    print_info "Latest Docker image: $LATEST_IMAGE"
    
    # Check if recent (within last hour)
    IMAGE_TIME=$(echo "$LATEST_IMAGE" | awk '{print $2}')
    CURRENT_TIME=$(date -u +"%Y-%m-%dT%H:%M:%S")
    
    print_success "Docker image found in ECR"
else
    print_error "No Docker images found in ECR"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Summary
print_header "Summary & Recommended Actions"

if [ $ISSUES_FOUND -eq 0 ]; then
    print_success "No major issues detected"
    print_info "If agent still not responding, try rebuilding:"
    echo "  cd 02-use-cases/customer-support-assistant-vpc"
    echo "  ./rebuild-agent.sh"
else
    print_error "Found $ISSUES_FOUND issue(s) that need attention"
    echo ""
    print_info "Most Common Fix:"
    echo "  1. Commit any code changes to GitHub"
    echo "  2. Run ./rebuild-agent.sh"
    echo "  3. Wait ~20 minutes"
    echo "  4. Test again"
    echo ""
    print_info "Quick test after rebuild:"
    echo "  cd 02-use-cases/customer-support-assistant-vpc"
    echo "  uv run python test/connect_agent.py"
fi

echo ""
print_info "For detailed troubleshooting, see PROJECT_STATUS.md"
