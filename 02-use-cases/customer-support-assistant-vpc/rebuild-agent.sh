#!/bin/bash

################################################################################
# Rebuild Agent Runtime with Updated Code
#
# This script triggers a CodeBuild to rebuild the agent Docker image
# Use this after making changes to agent code (like adding prompt.py)
################################################################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REGION="us-west-2"
ENVIRONMENT="dev"
STACK_NAME="customer-support-vpc-neon-agent-${ENVIRONMENT}"

################################################################################
# Helper Functions
################################################################################

print_info() {
    echo -e "${BLUE}ℹ ${NC}$1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

################################################################################
# Main Script
################################################################################

main() {
    print_header "Agent Runtime Rebuild Tool"
    
    echo "This script will:"
    echo "  1. Find the CodeBuild project for the agent"
    echo "  2. Trigger a new Docker image build"
    echo "  3. Monitor the build progress"
    echo "  4. Wait for automatic agent runtime update"
    echo ""
    echo "Stack: $STACK_NAME"
    echo "Region: $REGION"
    echo ""
    echo "Estimated time: 20-25 minutes"
    echo ""

    read -p "Continue? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Rebuild cancelled"
        exit 0
    fi

    # Get CodeBuild project name
    print_header "Step 1: Finding CodeBuild Project"
    
    CODEBUILD_PROJECT=$(aws cloudformation describe-stack-resources \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'StackResources[?ResourceType==`AWS::CodeBuild::Project`].PhysicalResourceId' \
        --output text)
    
    if [ -z "$CODEBUILD_PROJECT" ]; then
        print_error "CodeBuild project not found in stack: $STACK_NAME"
        exit 1
    fi
    
    print_success "Found CodeBuild project: $CODEBUILD_PROJECT"

    # Trigger the build
    print_header "Step 2: Triggering Build"
    
    BUILD_ID=$(aws codebuild start-build \
        --project-name "$CODEBUILD_PROJECT" \
        --region "$REGION" \
        --query 'build.id' \
        --output text)
    
    if [ -z "$BUILD_ID" ]; then
        print_error "Failed to start build"
        exit 1
    fi
    
    print_success "Build started with ID: $BUILD_ID"
    
    # Extract build number from ID
    BUILD_NUMBER=$(echo "$BUILD_ID" | awk -F':' '{print $NF}')
    print_info "Build number: $BUILD_NUMBER"
    print_info "Console URL: https://console.aws.amazon.com/codesuite/codebuild/projects/${CODEBUILD_PROJECT}/build/${BUILD_ID}"

    # Monitor the build
    print_header "Step 3: Monitoring Build Progress"
    
    print_info "This will take 15-20 minutes..."
    print_warning "Press Ctrl+C to stop monitoring (build will continue)"
    echo ""
    
    LAST_STATUS=""
    LAST_PHASE=""
    
    while true; do
        # Get current build status
        BUILD_INFO=$(aws codebuild batch-get-builds \
            --ids "$BUILD_ID" \
            --region "$REGION" \
            --query 'builds[0]' \
            --output json)
        
        CURRENT_STATUS=$(echo "$BUILD_INFO" | jq -r '.buildStatus')
        CURRENT_PHASE=$(echo "$BUILD_INFO" | jq -r '.currentPhase')
        BUILD_COMPLETE=$(echo "$BUILD_INFO" | jq -r '.buildComplete')
        
        # Only print if status or phase changed
        if [ "$CURRENT_STATUS" != "$LAST_STATUS" ] || [ "$CURRENT_PHASE" != "$LAST_PHASE" ]; then
            timestamp=$(date '+%H:%M:%S')
            echo "[$timestamp] Phase: $CURRENT_PHASE | Status: $CURRENT_STATUS"
            LAST_STATUS="$CURRENT_STATUS"
            LAST_PHASE="$CURRENT_PHASE"
        fi
        
        # Check if build is complete
        if [ "$BUILD_COMPLETE" = "true" ]; then
            echo ""
            if [ "$CURRENT_STATUS" = "SUCCEEDED" ]; then
                print_success "Build completed successfully!"
                break
            elif [ "$CURRENT_STATUS" = "FAILED" ]; then
                print_error "Build failed!"
                print_info "Check logs at: https://console.aws.amazon.com/codesuite/codebuild/projects/${CODEBUILD_PROJECT}/build/${BUILD_ID}"
                exit 1
            elif [ "$CURRENT_STATUS" = "STOPPED" ]; then
                print_warning "Build was stopped"
                exit 1
            fi
        fi
        
        sleep 30  # Check every 30 seconds
    done

    # Get the new image tag
    print_header "Step 4: Checking New Image Tag"
    
    # The build creates an image with tag like "build-123"
    NEW_IMAGE_TAG="build-${BUILD_NUMBER}"
    print_success "New image tag: $NEW_IMAGE_TAG"

    # Wait for EventBridge to update the runtime
    print_header "Step 5: Waiting for Agent Runtime Update"
    
    print_info "EventBridge will automatically update the agent runtime..."
    print_info "This typically takes 2-5 minutes"
    print_warning "The agent runtime will update to use the new Docker image"
    
    # Get agent runtime ID
    AGENT_RUNTIME_ARN=$(aws ssm get-parameter \
        --name /app/customersupportvpc/agentcore/agent_runtime_arn \
        --query 'Parameter.Value' \
        --output text \
        --region "$REGION" 2>/dev/null)
    
    if [ -n "$AGENT_RUNTIME_ARN" ]; then
        AGENT_RUNTIME_ID=$(echo "$AGENT_RUNTIME_ARN" | awk -F'/' '{print $NF}')
        print_info "Agent Runtime ID: $AGENT_RUNTIME_ID"
        
        # Wait a bit for EventBridge lambda to process
        print_info "Waiting 3 minutes for automatic update..."
        sleep 180
        
        print_success "Update should be complete!"
    fi

    # Summary
    print_header "Rebuild Complete"
    
    echo "✅ Docker image rebuilt and pushed to ECR"
    echo "✅ Image tag: $NEW_IMAGE_TAG"
    echo "✅ Agent runtime should be updated automatically"
    echo ""
    print_info "Next Steps:"
    echo "  1. Test your agent:"
    echo "     cd $(pwd)"
    echo "     uv run python test/connect_agent.py"
    echo ""
    echo "  2. Check agent logs if needed:"
    echo "     aws logs tail \"/aws/vendedlogs/bedrock-agentcore/${AGENT_RUNTIME_ID}\" \\"
    echo "       --since 10m --follow --region $REGION"
    echo ""
    print_info "If the agent still shows old behavior, wait 2-3 more minutes"
    print_info "and try testing again. EventBridge updates may take a moment."
}

# Run main function
main "$@"
