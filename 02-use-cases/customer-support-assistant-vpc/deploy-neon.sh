#!/bin/bash

################################################################################
# CloudFormation Stack Deployment Script for Neon Database
#
# This script automates the deployment of the Customer Support VPC stack
# with Neon PostgreSQL instead of Aurora.
################################################################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
STACK_NAME_BASE="customer-support-vpc-neon"
ENVIRONMENT="dev"
MODEL_ID="global.anthropic.claude-sonnet-4-20250514-v1:0"
REGION="us-west-2"
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
NEON_HOST=""
NEON_DATABASE="neondb"
NEON_USER=""
NEON_PASSWORD=""
NEON_PORT="5432"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFN_DIR="${SCRIPT_DIR}/cloudformation"

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

check_prerequisites() {
    print_header "Checking Prerequisites"

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        echo "Visit: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        exit 1
    fi
    print_success "AWS CLI found: $(aws --version | cut -d' ' -f1)"

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi

    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    print_success "AWS Account ID: ${AWS_ACCOUNT_ID}"

    # Check if CloudFormation directory exists
    if [ ! -d "$CFN_DIR" ]; then
        print_error "CloudFormation directory not found: $CFN_DIR"
        exit 1
    fi
    print_success "CloudFormation templates found"

    # Check for Neon-specific templates
    if [ ! -f "$CFN_DIR/vpc-stack-neon.yaml" ]; then
        print_error "Neon VPC template not found: $CFN_DIR/vpc-stack-neon.yaml"
        exit 1
    fi
    print_success "Neon-specific templates found"
}

validate_neon_credentials() {
    print_header "Validating Neon Credentials"

    if [ -z "$NEON_HOST" ]; then
        print_error "Neon host is required. Use --neon-host option."
        return 1
    fi

    if [ -z "$NEON_USER" ]; then
        print_error "Neon username is required. Use --neon-user option."
        return 1
    fi

    if [ -z "$NEON_PASSWORD" ]; then
        print_error "Neon password is required. Use --neon-password option."
        return 1
    fi

    # Validate host format
    if [[ ! "$NEON_HOST" =~ ^ep-.*\..*\.aws\.neon\.tech$ ]]; then
        print_warning "Neon host doesn't match expected format (ep-xxx.region.aws.neon.tech)"
        print_warning "Proceeding anyway, but please verify the host is correct"
    fi

    print_success "Neon credentials validated"
    return 0
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

    print_success "Bucket versioning enabled"

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

    print_success "Default encryption enabled"
}

deploy_vpc_stack() {
    print_header "Deploying VPC Stack with NAT Gateway"

    local vpc_stack_name="${STACK_NAME_BASE}-vpc-${ENVIRONMENT}"

    print_info "VPC Stack Name: ${vpc_stack_name}"

    # Check if stack already exists
    if aws cloudformation describe-stacks \
        --stack-name "$vpc_stack_name" \
        --region "$REGION" &> /dev/null; then
        print_warning "VPC stack already exists: ${vpc_stack_name}"
        return 0
    fi

    print_info "Creating VPC stack..."
    aws cloudformation create-stack \
        --stack-name "$vpc_stack_name" \
        --template-body file://"$CFN_DIR/vpc-stack-neon.yaml" \
        --parameters \
            ParameterKey=Environment,ParameterValue="$ENVIRONMENT" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --tags \
            Key=Project,Value=CustomerSupportVPCNeon \
            Key=Environment,Value="$ENVIRONMENT" \
            Key=ManagedBy,Value=CloudFormation

    print_info "Waiting for VPC stack creation (5-10 minutes due to NAT Gateway)..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$vpc_stack_name" \
        --region "$REGION"

    print_success "VPC stack created successfully!"
}

deploy_neon_config_stack() {
    print_header "Deploying Neon Configuration Stack"

    local neon_stack_name="${STACK_NAME_BASE}-config-${ENVIRONMENT}"

    print_info "Neon Config Stack Name: ${neon_stack_name}"

    # Check if stack already exists
    if aws cloudformation describe-stacks \
        --stack-name "$neon_stack_name" \
        --region "$REGION" &> /dev/null; then
        print_warning "Neon config stack already exists: ${neon_stack_name}"
        return 0
    fi

    print_info "Creating Neon configuration stack..."
    print_info "Neon Host: ${NEON_HOST}"
    print_info "Neon Database: ${NEON_DATABASE}"
    print_info "Neon User: ${NEON_USER}"

    aws cloudformation create-stack \
        --stack-name "$neon_stack_name" \
        --template-body file://"$CFN_DIR/neon-config-stack.yaml" \
        --parameters \
            ParameterKey=Environment,ParameterValue="$ENVIRONMENT" \
            ParameterKey=NeonHost,ParameterValue="$NEON_HOST" \
            ParameterKey=NeonDatabase,ParameterValue="$NEON_DATABASE" \
            ParameterKey=NeonUser,ParameterValue="$NEON_USER" \
            ParameterKey=NeonPassword,ParameterValue="$NEON_PASSWORD" \
            ParameterKey=NeonPort,ParameterValue="$NEON_PORT" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --tags \
            Key=Project,Value=CustomerSupportVPCNeon \
            Key=Environment,Value="$ENVIRONMENT" \
            Key=ManagedBy,Value=CloudFormation

    print_info "Waiting for Neon config stack creation (~2 minutes)..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$neon_stack_name" \
        --region "$REGION"

    print_success "Neon configuration stack created successfully!"
}

print_next_steps() {
    print_header "Next Steps"

    echo "1. Deploy remaining stacks (Cognito, MCP, Gateway) if not already deployed"
    echo ""
    echo "2. Deploy Agent Runtime Stack:"
    echo "   aws cloudformation create-stack \\"
    echo "     --stack-name ${STACK_NAME_BASE}-agent-${ENVIRONMENT} \\"
    echo "     --template-body file://${CFN_DIR}/agent-server-stack-neon.yaml \\"
    echo "     --parameters \\"
    echo "       ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \\"
    echo "       ParameterKey=VPCStackName,ParameterValue=${STACK_NAME_BASE}-vpc-${ENVIRONMENT} \\"
    echo "       ParameterKey=CognitoStackName,ParameterValue=YOUR_COGNITO_STACK \\"
    echo "       ParameterKey=MCPStackName,ParameterValue=YOUR_MCP_STACK \\"
    echo "       ParameterKey=GatewayStackName,ParameterValue=YOUR_GATEWAY_STACK \\"
    echo "       ParameterKey=NeonStackName,ParameterValue=${STACK_NAME_BASE}-config-${ENVIRONMENT} \\"
    echo "       ParameterKey=ModelID,ParameterValue=${MODEL_ID} \\"
    echo "     --capabilities CAPABILITY_NAMED_IAM \\"
    echo "     --region ${REGION}"
    echo ""
    echo "3. Test your deployment (see DEPLOY_NEON.md for details)"
    echo ""
    print_info "For complete deployment instructions, see: DEPLOY_NEON.md"
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy Customer Support VPC with Neon PostgreSQL

REQUIRED OPTIONS:
    --email EMAIL               Admin user email for Cognito (REQUIRED)
    --password PASSWORD         Admin user password for Cognito (REQUIRED)
    --neon-host HOST           Neon database host (REQUIRED)
                               Example: ep-xxx-xxx.us-west-2.aws.neon.tech
    --neon-user USERNAME       Neon database username (REQUIRED)
    --neon-password PASSWORD   Neon database password (REQUIRED)

OPTIONAL OPTIONS:
    -s, --stack STACK_NAME     CloudFormation stack base name (default: customer-support-vpc-neon)
    -r, --region REGION        AWS region (default: us-west-2)
    -e, --env ENVIRONMENT      Environment name (default: dev)
    --neon-database DB_NAME    Neon database name (default: neondb)
    --neon-port PORT           Neon database port (default: 5432)
    -m, --model MODEL_ID       Bedrock model ID (default: global.anthropic.claude-sonnet-4-20250514-v1:0)
    -h, --help                 Show this help message

EXAMPLES:
    # Basic deployment with Neon credentials
    $0 \\
      --email admin@example.com \\
      --password 'MyP@ssw0rd123' \\
      --neon-host ep-xxx-xxx.us-west-2.aws.neon.tech \\
      --neon-user myuser \\
      --neon-password 'MyNeonP@ss'

    # Production deployment with custom environment
    $0 \\
      --env prod \\
      --region us-west-2 \\
      --email admin@example.com \\
      --password 'MyP@ssw0rd123' \\
      --neon-host ep-xxx-xxx.us-west-2.aws.neon.tech \\
      --neon-database production_db \\
      --neon-user prod_user \\
      --neon-password 'ProdNeonP@ss'

NOTES:
    - This script deploys VPC and Neon configuration stacks only
    - You'll need to deploy Cognito, MCP, and Gateway stacks separately
    - Then deploy the Agent Runtime stack (instructions provided after deployment)
    - See DEPLOY_NEON.md for complete deployment guide

WHAT THIS SCRIPT DEPLOYS:
    1. VPC Stack with NAT Gateway (for Neon connectivity)
    2. Neon Configuration Stack (credentials in Secrets Manager)

WHAT YOU NEED TO DEPLOY SEPARATELY:
    - Cognito User Pool Stack
    - MCP DynamoDB Runtime Stack
    - Gateway Stack  
    - Agent Runtime Stack (with Neon)

EOF
}

################################################################################
# Main Script
################################################################################

main() {
    # Parse command line arguments
    CUSTOM_STACK_NAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--stack)
                CUSTOM_STACK_NAME="$2"
                shift 2
                ;;
            -r|--region)
                REGION="$2"
                shift 2
                ;;
            -e|--env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -m|--model)
                MODEL_ID="$2"
                shift 2
                ;;
            --email)
                ADMIN_EMAIL="$2"
                shift 2
                ;;
            --password)
                ADMIN_PASSWORD="$2"
                shift 2
                ;;
            --neon-host)
                NEON_HOST="$2"
                shift 2
                ;;
            --neon-database)
                NEON_DATABASE="$2"
                shift 2
                ;;
            --neon-user)
                NEON_USER="$2"
                shift 2
                ;;
            --neon-password)
                NEON_PASSWORD="$2"
                shift 2
                ;;
            --neon-port)
                NEON_PORT="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    # Set stack name base
    if [ -n "$CUSTOM_STACK_NAME" ]; then
        STACK_NAME_BASE="$CUSTOM_STACK_NAME"
    fi

    # Validate required parameters
    if [ -z "$ADMIN_EMAIL" ] || [ -z "$ADMIN_PASSWORD" ]; then
        print_error "Admin email and password are required!"
        print_usage
        exit 1
    fi

    if ! validate_neon_credentials; then
        print_usage
        exit 1
    fi

    print_header "Customer Support VPC with Neon - Deployment"
    echo "Stack Base Name:   $STACK_NAME_BASE"
    echo "Region:            $REGION"
    echo "Environment:       $ENVIRONMENT"
    echo "Model ID:          $MODEL_ID"
    echo "Admin Email:       $ADMIN_EMAIL"
    echo "Admin Password:    ******** (hidden)"
    echo ""
    echo "Neon Configuration:"
    echo "  Host:            $NEON_HOST"
    echo "  Database:        $NEON_DATABASE"
    echo "  User:            $NEON_USER"
    echo "  Password:        ******** (hidden)"
    echo "  Port:            $NEON_PORT"
    echo ""
    echo "Stacks to be deployed:"
    echo "  1. ${STACK_NAME_BASE}-vpc-${ENVIRONMENT}"
    echo "  2. ${STACK_NAME_BASE}-config-${ENVIRONMENT}"
    echo ""

    read -p "Continue with deployment? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deployment cancelled"
        exit 0
    fi

    # Execute deployment steps
    check_prerequisites
    deploy_vpc_stack
    deploy_neon_config_stack

    print_header "Deployment Complete"
    print_success "VPC and Neon configuration stacks deployed successfully!"
    print_info ""
    print_info "VPC Stack: ${STACK_NAME_BASE}-vpc-${ENVIRONMENT}"
    print_info "Neon Config Stack: ${STACK_NAME_BASE}-config-${ENVIRONMENT}"
    print_info ""
    
    print_next_steps
}

# Run main function
main "$@"
