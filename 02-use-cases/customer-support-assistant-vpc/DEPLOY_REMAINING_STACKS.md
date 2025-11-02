# Deploy Remaining Stacks - Cognito, MCP, and Gateway

## Overview

After deploying VPC and Neon configuration stacks using `deploy-neon.sh`, you need to deploy three more stacks before the Agent Runtime stack.

## Prerequisites

✅ VPC Stack deployed (from `deploy-neon.sh`)
✅ Neon Config Stack deployed (from `deploy-neon.sh`)
✅ AWS Profile set: `export AWS_PROFILE=juandaserniCelliaLabsSuperA`

## Deployment Order

```
1. Cognito Stack      (User authentication)
2. MCP Stack          (MCP DynamoDB runtime)
3. Gateway Stack      (API Gateway for tools)
4. Agent Runtime      (Your agent with Neon)
```

## Step 1: Deploy Cognito Stack

The Cognito stack creates the user pool for authentication.

```bash
# Set your AWS profile
export AWS_PROFILE=juandaserniCelliaLabsSuperA

# Set variables
REGION="us-west-2"
ENVIRONMENT="dev"
ADMIN_EMAIL="your-email@example.com"
ADMIN_PASSWORD="YourSecureP@ssw0rd123"

# Deploy Cognito Stack
aws cloudformation create-stack \
  --stack-name customer-support-vpc-neon-cognito-${ENVIRONMENT} \
  --template-body file://cloudformation/cognito-stack.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
    ParameterKey=AdminUserEmail,ParameterValue="${ADMIN_EMAIL}" \
    ParameterKey=AdminUserPassword,ParameterValue="${ADMIN_PASSWORD}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${REGION} \
  --tags \
    Key=Project,Value=CustomerSupportVPCNeon \
    Key=Environment,Value=${ENVIRONMENT}

# Wait for completion (3-5 minutes)
echo "⏳ Waiting for Cognito stack creation..."
aws cloudformation wait stack-create-complete \
  --stack-name customer-support-vpc-neon-cognito-${ENVIRONMENT} \
  --region ${REGION}

echo "✅ Cognito stack created successfully!"
```

### Verify Cognito Stack
```bash
# Get outputs
aws cloudformation describe-stacks \
  --stack-name customer-support-vpc-neon-cognito-${ENVIRONMENT} \
  --region ${REGION} \
  --query 'Stacks[0].Outputs' \
  --output table
```

## Step 2: Deploy MCP (DynamoDB) Stack

The MCP stack creates the DynamoDB MCP server runtime.

```bash
# Deploy MCP Stack
aws cloudformation create-stack \
  --stack-name customer-support-vpc-neon-mcp-${ENVIRONMENT} \
  --template-body file://cloudformation/mcp-server-stack.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
    ParameterKey=VPCStackName,ParameterValue=customer-support-vpc-neon-vpc-${ENVIRONMENT} \
    ParameterKey=CognitoStackName,ParameterValue=customer-support-vpc-neon-cognito-${ENVIRONMENT} \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${REGION} \
  --tags \
    Key=Project,Value=CustomerSupportVPCNeon \
    Key=Environment,Value=${ENVIRONMENT}

# Wait for completion (15-20 minutes - includes Docker build)
echo "⏳ Waiting for MCP stack creation (this takes 15-20 minutes)..."
aws cloudformation wait stack-create-complete \
  --stack-name customer-support-vpc-neon-mcp-${ENVIRONMENT} \
  --region ${REGION}

echo "✅ MCP stack created successfully!"
```

### Verify MCP Stack
```bash
# Get MCP Runtime ARN
aws cloudformation describe-stacks \
  --stack-name customer-support-vpc-neon-mcp-${ENVIRONMENT} \
  --region ${REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`MCPDynamoDBRuntimeArn`].OutputValue' \
  --output text
```

## Step 3: Deploy Gateway Stack

The Gateway stack creates the API Gateway for external tools.

```bash
# Deploy Gateway Stack
aws cloudformation create-stack \
  --stack-name customer-support-vpc-neon-gateway-${ENVIRONMENT} \
  --template-body file://cloudformation/gateway-stack.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
    ParameterKey=CognitoStackName,ParameterValue=customer-support-vpc-neon-cognito-${ENVIRONMENT} \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${REGION} \
  --tags \
    Key=Project,Value=CustomerSupportVPCNeon \
    Key=Environment,Value=${ENVIRONMENT}

# Wait for completion (10-15 minutes - includes Lambda deployment)
echo "⏳ Waiting for Gateway stack creation (this takes 10-15 minutes)..."
aws cloudformation wait stack-create-complete \
  --stack-name customer-support-vpc-neon-gateway-${ENVIRONMENT} \
  --region ${REGION}

echo "✅ Gateway stack created successfully!"
```

### Verify Gateway Stack
```bash
# Get Gateway URL
aws ssm get-parameter \
  --name /app/customersupportvpc/gateway/gateway_url \
  --query 'Parameter.Value' \
  --output text \
  --region ${REGION}
```

## Step 4: Deploy Agent Runtime Stack (with Neon)

Now deploy the agent runtime stack that uses Neon database.

```bash
# Deploy Agent Runtime Stack
aws cloudformation create-stack \
  --stack-name customer-support-vpc-neon-agent-${ENVIRONMENT} \
  --template-body file://cloudformation/agent-server-stack-neon.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
    ParameterKey=VPCStackName,ParameterValue=customer-support-vpc-neon-vpc-${ENVIRONMENT} \
    ParameterKey=CognitoStackName,ParameterValue=customer-support-vpc-neon-cognito-${ENVIRONMENT} \
    ParameterKey=MCPStackName,ParameterValue=customer-support-vpc-neon-mcp-${ENVIRONMENT} \
    ParameterKey=GatewayStackName,ParameterValue=customer-support-vpc-neon-gateway-${ENVIRONMENT} \
    ParameterKey=NeonStackName,ParameterValue=customer-support-vpc-neon-config-${ENVIRONMENT} \
    ParameterKey=ModelID,ParameterValue="global.anthropic.claude-sonnet-4-20250514-v1:0" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${REGION} \
  --tags \
    Key=Project,Value=CustomerSupportVPCNeon \
    Key=Environment,Value=${ENVIRONMENT}

# Wait for completion (30-40 minutes - includes Docker build)
echo "⏳ Waiting for Agent Runtime stack creation (this takes 30-40 minutes)..."
aws cloudformation wait stack-create-complete \
  --stack-name customer-support-vpc-neon-agent-${ENVIRONMENT} \
  --region ${REGION}

echo "✅ Agent Runtime stack created successfully!"
```

### Verify Agent Runtime
```bash
# Get Agent Runtime ARN
aws ssm get-parameter \
  --name /app/customersupportvpc/agentcore/agent_runtime_arn \
  --query 'Parameter.Value' \
  --output text \
  --region ${REGION}
```

## Complete Deployment Script

Here's a complete script that deploys all remaining stacks:

```bash
#!/bin/bash

# Deploy Remaining Stacks for Neon Migration
# Run this after deploy-neon.sh completes

set -e

# Configuration
export AWS_PROFILE=juandaserniCelliaLabsSuperA
REGION="us-west-2"
ENVIRONMENT="dev"
ADMIN_EMAIL="your-email@example.com"        # Change this
ADMIN_PASSWORD="YourSecureP@ssw0rd123"      # Change this

echo "🚀 Starting deployment of remaining stacks..."
echo "Region: ${REGION}"
echo "Environment: ${ENVIRONMENT}"
echo ""

# 1. Deploy Cognito Stack
echo "📦 Step 1/4: Deploying Cognito Stack..."
aws cloudformation create-stack \
  --stack-name customer-support-vpc-neon-cognito-${ENVIRONMENT} \
  --template-body file://cloudformation/cognito-stack.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
    ParameterKey=AdminUserEmail,ParameterValue="${ADMIN_EMAIL}" \
    ParameterKey=AdminUserPassword,ParameterValue="${ADMIN_PASSWORD}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${REGION} \
  --tags Key=Project,Value=CustomerSupportVPCNeon Key=Environment,Value=${ENVIRONMENT}

aws cloudformation wait stack-create-complete \
  --stack-name customer-support-vpc-neon-cognito-${ENVIRONMENT} \
  --region ${REGION}
echo "✅ Cognito stack created!"

# 2. Deploy MCP Stack
echo ""
echo "📦 Step 2/4: Deploying MCP Stack (15-20 minutes)..."
aws cloudformation create-stack \
  --stack-name customer-support-vpc-neon-mcp-${ENVIRONMENT} \
  --template-body file://cloudformation/mcp-server-stack.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
    ParameterKey=VPCStackName,ParameterValue=customer-support-vpc-neon-vpc-${ENVIRONMENT} \
    ParameterKey=CognitoStackName,ParameterValue=customer-support-vpc-neon-cognito-${ENVIRONMENT} \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${REGION} \
  --tags Key=Project,Value=CustomerSupportVPCNeon Key=Environment,Value=${ENVIRONMENT}

aws cloudformation wait stack-create-complete \
  --stack-name customer-support-vpc-neon-mcp-${ENVIRONMENT} \
  --region ${REGION}
echo "✅ MCP stack created!"

# 3. Deploy Gateway Stack
echo ""
echo "📦 Step 3/4: Deploying Gateway Stack (10-15 minutes)..."
aws cloudformation create-stack \
  --stack-name customer-support-vpc-neon-gateway-${ENVIRONMENT} \
  --template-body file://cloudformation/gateway-stack.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
    ParameterKey=CognitoStackName,ParameterValue=customer-support-vpc-neon-cognito-${ENVIRONMENT} \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${REGION} \
  --tags Key=Project,Value=CustomerSupportVPCNeon Key=Environment,Value=${ENVIRONMENT}

aws cloudformation wait stack-create-complete \
  --stack-name customer-support-vpc-neon-gateway-${ENVIRONMENT} \
  --region ${REGION}
echo "✅ Gateway stack created!"

# 4. Deploy Agent Runtime Stack
echo ""
echo "📦 Step 4/4: Deploying Agent Runtime Stack (30-40 minutes)..."
aws cloudformation create-stack \
  --stack-name customer-support-vpc-neon-agent-${ENVIRONMENT} \
  --template-body file://cloudformation/agent-server-stack-neon.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
    ParameterKey=VPCStackName,ParameterValue=customer-support-vpc-neon-vpc-${ENVIRONMENT} \
    ParameterKey=CognitoStackName,ParameterValue=customer-support-vpc-neon-cognito-${ENVIRONMENT} \
    ParameterKey=MCPStackName,ParameterValue=customer-support-vpc-neon-mcp-${ENVIRONMENT} \
    ParameterKey=GatewayStackName,ParameterValue=customer-support-vpc-neon-gateway-${ENVIRONMENT} \
    ParameterKey=NeonStackName,ParameterValue=customer-support-vpc-neon-config-${ENVIRONMENT} \
    ParameterKey=ModelID,ParameterValue="global.anthropic.claude-sonnet-4-20250514-v1:0" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${REGION} \
  --tags Key=Project,Value=CustomerSupportVPCNeon Key=Environment,Value=${ENVIRONMENT}

aws cloudformation wait stack-create-complete \
  --stack-name customer-support-vpc-neon-agent-${ENVIRONMENT} \
  --region ${REGION}
echo "✅ Agent Runtime stack created!"

echo ""
echo "🎉 All stacks deployed successfully!"
echo ""
echo "Deployed Stacks:"
echo "  1. ✅ Cognito: customer-support-vpc-neon-cognito-${ENVIRONMENT}"
echo "  2. ✅ MCP: customer-support-vpc-neon-mcp-${ENVIRONMENT}"
echo "  3. ✅ Gateway: customer-support-vpc-neon-gateway-${ENVIRONMENT}"
echo "  4. ✅ Agent Runtime: customer-support-vpc-neon-agent-${ENVIRONMENT}"
echo ""
echo "Next: Test your deployment (see DEPLOY_NEON.md)"
```

Save this as `deploy-remaining-stacks.sh` and run it!

## Total Deployment Time

| Stack | Time | Status |
|-------|------|--------|
| Cognito | 3-5 min | ⏳ |
| MCP | 15-20 min | ⏳ |
| Gateway | 10-15 min | ⏳ |
| Agent Runtime | 30-40 min | ⏳ |
| **Total** | **58-80 min** | **~1hr 20min** |

## Stack Dependencies

```
VPC Stack (already deployed)
  ├─→ Cognito Stack
  │     ├─→ MCP Stack
  │     ├─→ Gateway Stack
  │     └─→ Agent Runtime Stack
  │
  └─→ Neon Config Stack (already deployed)
        └─→ Agent Runtime Stack
```

## Verification Commands

After all stacks are deployed, verify everything:

```bash
# Set environment
ENVIRONMENT="dev"
REGION="us-west-2"

# Check all stack statuses
for stack in vpc config cognito mcp gateway agent; do
  echo "Checking customer-support-vpc-neon-${stack}-${ENVIRONMENT}..."
  aws cloudformation describe-stacks \
    --stack-name customer-support-vpc-neon-${stack}-${ENVIRONMENT} \
    --region ${REGION} \
    --query 'Stacks[0].StackStatus' \
    --output text
done

# Get Agent Runtime URL (will be in the agent stack outputs)
aws cloudformation describe-stacks \
  --stack-name customer-support-vpc-neon-agent-${ENVIRONMENT} \
  --region ${REGION} \
  --query 'Stacks[0].Outputs' \
  --output table
```

## Troubleshooting

### Stack Creation Failed

Check the events:
```bash
aws cloudformation describe-stack-events \
  --stack-name STACK_NAME \
  --region us-west-2 \
  --max-items 10 \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]' \
  --output table
```

### Delete and Retry

If you need to delete and retry:
```bash
# Delete in reverse order
aws cloudformation delete-stack --stack-name customer-support-vpc-neon-agent-dev --region us-west-2
aws cloudformation delete-stack --stack-name customer-support-vpc-neon-gateway-dev --region us-west-2
aws cloudformation delete-stack --stack-name customer-support-vpc-neon-mcp-dev --region us-west-2
aws cloudformation delete-stack --stack-name customer-support-vpc-neon-cognito-dev --region us-west-2

# Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name customer-support-vpc-neon-agent-dev --region us-west-2
# ... repeat for each stack
```

## Quick Start Summary

1. ✅ Run `deploy-neon.sh` (VPC + Neon config) - **DONE**
2. ⏳ Deploy Cognito stack (~5 min)
3. ⏳ Deploy MCP stack (~20 min)
4. ⏳ Deploy Gateway stack (~15 min)
5. ⏳ Deploy Agent Runtime stack (~40 min)
6. ✅ Test deployment

**OR**

Save the complete script above as `deploy-remaining-stacks.sh`, update the email/password, and run it to deploy everything automatically!

## Next Steps

After all stacks are deployed:
1. Test Neon connection
2. Test agent queries
3. Deploy frontend (Next.js + Amplify)
4. Configure Cognito in your frontend

See `DEPLOY_NEON.md` for complete testing instructions.
