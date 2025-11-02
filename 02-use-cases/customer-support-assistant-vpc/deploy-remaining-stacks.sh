#!/bin/bash

################################################################################
# Deploy Remaining Stacks for Neon Migration
#
# This script deploys Cognito, MCP, Gateway, and Agent Runtime stacks
# Run this after deploy-neon.sh completes successfully
################################################################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - UPDATE THESE VALUES
REGION="us-west-2"
ENVIRONMENT="dev"
ADMIN_EMAIL="juandaserni@gmail.com"        # REQUIRED: Your admin email
ADMIN_PASSWORD="Ju5An5SB1924#"     # REQUIRED: Your admin password (min 8 chars with uppercase, lowercase, number, special char)

# S3 bucket for template storage (will be auto-generated if not provided)
S3_BUCKET=""  # Leave empty to auto-generate, or provide your own bucket name

# Stack names
VPC_STACK="customer-support-vpc-neon-vpc-${ENVIRONMENT}"
CONFIG_STACK="customer-support-vpc-neon-config-${ENVIRONMENT}"
COGNITO_STACK="customer-support-vpc-neon-cognito-${ENVIRONMENT}"
DYNAMODB_STACK="customer-support-vpc-neon-dynamodb-${ENVIRONMENT}"
MCP_STACK="customer-support-vpc-neon-mcp-${ENVIRONMENT}"
GATEWAY_STACK="customer-support-vpc-neon-gateway-${ENVIRONMENT}"
AGENT_STACK="customer-support-vpc-neon-agent-${ENVIRONMENT}"

# Model configuration
MODEL_ID="global.anthropic.claude-sonnet-4-20250514-v1:0"

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

generate_bucket_name() {
    # Generate S3-compliant bucket name
    local random_suffix=$(head /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 12)
    echo "customersupportvpc-neon-${random_suffix}"
}

create_s3_bucket() {
    print_header "Creating S3 Bucket for Templates"

    local bucket_name="$1"

    # Check if bucket exists
    if aws s3 ls "s3://${bucket_name}" 2>/dev/null; then
        print_warning "S3 bucket already exists: ${bucket_name}"
        return 0
    fi

    print_info "Creating S3 bucket: ${bucket_name}"

    # Create bucket (handle us-east-1 special case)
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$bucket_name" \
            --region "$REGION"
    else
        aws s3api create-bucket \
            --bucket "$bucket_name" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"
    fi

    print_success "S3 bucket created: ${bucket_name}"

    # Enable versioning
    print_info "Enabling bucket versioning..."
    aws s3api put-bucket-versioning \
        --bucket "$bucket_name" \
        --versioning-configuration Status=Enabled

    # Enable encryption
    print_info "Enabling default encryption..."
    aws s3api put-bucket-encryption \
        --bucket "$bucket_name" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'

    print_success "S3 bucket configured successfully"
}

upload_templates() {
    print_header "Uploading Templates to S3"

    local bucket_name="$1"

    print_info "Uploading CloudFormation templates..."
    aws s3 sync cloudformation/ "s3://${bucket_name}/cloudformation/" \
        --exclude "*" \
        --include "*.yaml" \
        --region "$REGION"

    print_success "Templates uploaded successfully"
}

check_prerequisites() {
    print_header "Checking Prerequisites"

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed"
        exit 1
    fi
    print_success "AWS CLI found"

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured"
        exit 1
    fi
    print_success "AWS credentials configured"

    # Check admin email and password
    if [ -z "$ADMIN_EMAIL" ]; then
        print_error "ADMIN_EMAIL is not set. Please edit the script and set ADMIN_EMAIL."
        exit 1
    fi

    if [ -z "$ADMIN_PASSWORD" ]; then
        print_error "ADMIN_PASSWORD is not set. Please edit the script and set ADMIN_PASSWORD."
        exit 1
    fi

    print_success "Admin credentials configured"

    # Check if prerequisite stacks exist
    print_info "Checking prerequisite stacks..."
    
    if ! aws cloudformation describe-stacks --stack-name "$VPC_STACK" --region "$REGION" &> /dev/null; then
        print_error "VPC stack not found: $VPC_STACK"
        print_info "Run deploy-neon.sh first to create VPC and Neon config stacks"
        exit 1
    fi
    print_success "VPC stack exists: $VPC_STACK"

    if ! aws cloudformation describe-stacks --stack-name "$CONFIG_STACK" --region "$REGION" &> /dev/null; then
        print_error "Neon config stack not found: $CONFIG_STACK"
        print_info "Run deploy-neon.sh first to create VPC and Neon config stacks"
        exit 1
    fi
    print_success "Neon config stack exists: $CONFIG_STACK"
}

deploy_cognito_stack() {
    print_header "Step 1/4: Deploying Cognito Stack"

    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name "$COGNITO_STACK" --region "$REGION" &> /dev/null; then
        print_warning "Cognito stack already exists: $COGNITO_STACK"
        return 0
    fi

    print_info "Creating Cognito stack..."
    print_info "Admin Email: $ADMIN_EMAIL"

    aws cloudformation create-stack \
        --stack-name "$COGNITO_STACK" \
        --template-url "https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/cloudformation/cognito-stack.yaml" \
        --parameters \
            ParameterKey=Environment,ParameterValue="${ENVIRONMENT}" \
            ParameterKey=AdminUserEmail,ParameterValue="${ADMIN_EMAIL}" \
            ParameterKey=AdminUserPassword,ParameterValue="${ADMIN_PASSWORD}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --tags \
            Key=Project,Value=CustomerSupportVPCNeon \
            Key=Environment,Value="${ENVIRONMENT}" \
            Key=ManagedBy,Value=CloudFormation

    print_info "Waiting for Cognito stack creation (3-5 minutes)..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$COGNITO_STACK" \
        --region "$REGION"

    print_success "Cognito stack created successfully!"
}

deploy_dynamodb_stack() {
    print_header "Step 2/5: Deploying DynamoDB Stack"

    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name "$DYNAMODB_STACK" --region "$REGION" &> /dev/null; then
        print_warning "DynamoDB stack already exists: $DYNAMODB_STACK"
        return 0
    fi

    print_info "Creating DynamoDB stack..."
    print_info "This will take 3-5 minutes..."

    aws cloudformation create-stack \
        --stack-name "$DYNAMODB_STACK" \
        --template-url "https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/cloudformation/dynamodb-stack.yaml" \
        --parameters \
            ParameterKey=Environment,ParameterValue="${ENVIRONMENT}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --tags \
            Key=Project,Value=CustomerSupportVPCNeon \
            Key=Environment,Value="${ENVIRONMENT}" \
            Key=ManagedBy,Value=CloudFormation

    print_info "Waiting for DynamoDB stack creation..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$DYNAMODB_STACK" \
        --region "$REGION"

    print_success "DynamoDB stack created successfully!"
}

deploy_mcp_stack() {
    print_header "Step 3/5: Deploying MCP Stack"

    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name "$MCP_STACK" --region "$REGION" &> /dev/null; then
        print_warning "MCP stack already exists: $MCP_STACK"
        return 0
    fi

    print_info "Creating MCP stack..."
    print_info "This will take 15-20 minutes (includes Docker build)..."

    aws cloudformation create-stack \
        --stack-name "$MCP_STACK" \
        --template-url "https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/cloudformation/mcp-server-stack.yaml" \
        --parameters \
            ParameterKey=Environment,ParameterValue="${ENVIRONMENT}" \
            ParameterKey=VPCStackName,ParameterValue="${VPC_STACK}" \
            ParameterKey=CognitoStackName,ParameterValue="${COGNITO_STACK}" \
            ParameterKey=DynamoDBStackName,ParameterValue="${DYNAMODB_STACK}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --tags \
            Key=Project,Value=CustomerSupportVPCNeon \
            Key=Environment,Value="${ENVIRONMENT}" \
            Key=ManagedBy,Value=CloudFormation

    print_info "Waiting for MCP stack creation..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$MCP_STACK" \
        --region "$REGION"

    print_success "MCP stack created successfully!"
}

deploy_gateway_stack() {
    print_header "Step 4/5: Deploying Gateway Stack"

    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" --region "$REGION" &> /dev/null; then
        print_warning "Gateway stack already exists: $GATEWAY_STACK"
        return 0
    fi

    print_info "Creating Gateway stack..."
    print_info "This will take 10-15 minutes (includes Lambda deployment)..."

    aws cloudformation create-stack \
        --stack-name "$GATEWAY_STACK" \
        --template-url "https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/cloudformation/gateway-stack.yaml" \
        --parameters \
            ParameterKey=Environment,ParameterValue="${ENVIRONMENT}" \
            ParameterKey=VPCStackName,ParameterValue="${VPC_STACK}" \
            ParameterKey=CognitoStackName,ParameterValue="${COGNITO_STACK}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --tags \
            Key=Project,Value=CustomerSupportVPCNeon \
            Key=Environment,Value="${ENVIRONMENT}" \
            Key=ManagedBy,Value=CloudFormation

    print_info "Waiting for Gateway stack creation..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$GATEWAY_STACK" \
        --region "$REGION"

    print_success "Gateway stack created successfully!"
}

deploy_agent_stack() {
    print_header "Step 5/5: Deploying Agent Runtime Stack"

    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name "$AGENT_STACK" --region "$REGION" &> /dev/null; then
        print_warning "Agent Runtime stack already exists: $AGENT_STACK"
        return 0
    fi

    print_info "Creating Agent Runtime stack..."
    print_info "This will take 30-40 minutes (includes Docker build)..."
    print_info "Model ID: $MODEL_ID"

    aws cloudformation create-stack \
        --stack-name "$AGENT_STACK" \
        --template-url "https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/cloudformation/agent-server-stack-neon.yaml" \
        --parameters \
            ParameterKey=Environment,ParameterValue="${ENVIRONMENT}" \
            ParameterKey=VPCStackName,ParameterValue="${VPC_STACK}" \
            ParameterKey=CognitoStackName,ParameterValue="${COGNITO_STACK}" \
            ParameterKey=MCPStackName,ParameterValue="${MCP_STACK}" \
            ParameterKey=GatewayStackName,ParameterValue="${GATEWAY_STACK}" \
            ParameterKey=NeonStackName,ParameterValue="${CONFIG_STACK}" \
            ParameterKey=ModelID,ParameterValue="${MODEL_ID}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --tags \
            Key=Project,Value=CustomerSupportVPCNeon \
            Key=Environment,Value="${ENVIRONMENT}" \
            Key=ManagedBy,Value=CloudFormation

    print_info "Waiting for Agent Runtime stack creation..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$AGENT_STACK" \
        --region "$REGION"

    print_success "Agent Runtime stack created successfully!"
}

verify_deployment() {
    print_header "Verifying Deployment"

    print_info "Checking stack statuses..."
    
    for stack in "$VPC_STACK" "$CONFIG_STACK" "$COGNITO_STACK" "$DYNAMODB_STACK" "$MCP_STACK" "$GATEWAY_STACK" "$AGENT_STACK"; do
        status=$(aws cloudformation describe-stacks \
            --stack-name "$stack" \
            --region "$REGION" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null || echo "NOT_FOUND")
        
        if [ "$status" = "CREATE_COMPLETE" ]; then
            print_success "$(basename $stack): $status"
        else
            print_warning "$(basename $stack): $status"
        fi
    done

    print_info ""
    print_info "Getting Agent Runtime ARN..."
    AGENT_RUNTIME_ARN=$(aws ssm get-parameter \
        --name /app/customersupportvpc/agentcore/agent_runtime_arn \
        --query 'Parameter.Value' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "Not found")
    
    if [ "$AGENT_RUNTIME_ARN" != "Not found" ]; then
        print_success "Agent Runtime ARN: $AGENT_RUNTIME_ARN"
    else
        print_warning "Agent Runtime ARN not found in SSM Parameter Store"
    fi
}

print_summary() {
    print_header "Deployment Complete"
    
    echo "🎉 All stacks deployed successfully!"
    echo ""
    echo "Deployed Stacks:"
    echo "  1. ✅ VPC: $VPC_STACK"
    echo "  2. ✅ Neon Config: $CONFIG_STACK"
    echo "  3. ✅ Cognito: $COGNITO_STACK"
    echo "  4. ✅ DynamoDB: $DYNAMODB_STACK"
    echo "  5. ✅ MCP: $MCP_STACK"
    echo "  6. ✅ Gateway: $GATEWAY_STACK"
    echo "  7. ✅ Agent Runtime: $AGENT_STACK"
    echo ""
    echo "Region: $REGION"
    echo "Environment: $ENVIRONMENT"
    echo ""
    print_info "Next Steps:"
    echo "  1. Test your agent deployment (see DEPLOY_NEON.md)"
    echo "  2. Deploy your Next.js Amplify frontend"
    echo "  3. Configure Cognito in your frontend"
    echo ""
    print_info "View stacks in AWS Console:"
    echo "https://console.aws.amazon.com/cloudformation/home?region=${REGION}"
}

################################################################################
# Main Script
################################################################################

main() {
    # Generate S3 bucket name if not provided
    if [ -z "$S3_BUCKET" ]; then
        S3_BUCKET=$(generate_bucket_name)
        print_info "Generated S3 bucket name: ${S3_BUCKET}"
    fi

    print_header "Customer Support VPC with Neon - Automated Deployment"
    
    echo "This script will deploy:"
    echo "  1. Cognito Stack (User authentication)"
    echo "  2. DynamoDB Stack (Product reviews and catalog data)"
    echo "  3. MCP Stack (MCP DynamoDB runtime)"
    echo "  4. Gateway Stack (API Gateway for tools)"
    echo "  5. Agent Runtime Stack (Agent with Neon database)"
    echo ""
    echo "Configuration:"
    echo "  Region: $REGION"
    echo "  Environment: $ENVIRONMENT"
    echo "  S3 Bucket: $S3_BUCKET"
    echo "  Admin Email: $ADMIN_EMAIL"
    echo "  Admin Password: ********"
    echo "  Model ID: $MODEL_ID"
    echo ""
    echo "Estimated total time: 65-90 minutes (~1 hour 30 minutes)"
    echo ""

    read -p "Continue with deployment? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deployment cancelled"
        exit 0
    fi

    # Execute deployment steps
    check_prerequisites
    create_s3_bucket "$S3_BUCKET"
    upload_templates "$S3_BUCKET"
    deploy_cognito_stack
    deploy_dynamodb_stack
    deploy_mcp_stack
    deploy_gateway_stack
    deploy_agent_stack
    verify_deployment
    print_summary
}

# Check if required variables are set
if [ -z "$ADMIN_EMAIL" ] || [ -z "$ADMIN_PASSWORD" ]; then
    print_error "ERROR: ADMIN_EMAIL and ADMIN_PASSWORD must be set"
    echo ""
    echo "Please edit this script and set:"
    echo "  ADMIN_EMAIL=\"your-email@example.com\""
    echo "  ADMIN_PASSWORD=\"YourSecureP@ssw0rd123\""
    echo ""
    echo "Password requirements:"
    echo "  - Minimum 8 characters"
    echo "  - At least one uppercase letter"
    echo "  - At least one lowercase letter"
    echo "  - At least one number"
    echo "  - At least one special character"
    exit 1
fi

# Run main function
main "$@"
