# Neon Deployment Guide - Complete Instructions

## 🎉 All Files Ready!

Everything has been prepared for your Neon migration. This guide will walk you through deployment using your AWS profile.

## Prerequisites Checklist

- [x] ✅ All code files updated
- [x] ✅ All CloudFormation templates created
- [ ] 🔲 Neon account and database set up
- [ ] 🔲 Neon credentials ready

## Your AWS Profile

You mentioned using this AWS profile:
```bash
export AWS_PROFILE=juandaserniCelliaLabsSuperA
```

Make sure this is set in your terminal before running any AWS commands.

## Step 1: Create Neon Database

### 1.1 Sign up at Neon
```bash
# Open in browser
https://neon.tech
```

### 1.2 Create Project
- **Project Name**: customer-support-vpc
- **Region**: US West (Oregon) - to match us-west-2
- **PostgreSQL Version**: 15 or 16

### 1.3 Get Connection Details
After creating the project, you'll get:
```
Host: ep-xxx-xxx-xxx.us-west-2.aws.neon.tech
Database: neondb
User: your_username
Password: (auto-generated, copy this!)
Port: 5432
```

**⚠️ IMPORTANT**: Save these credentials securely!

### 1.4 Create Database Schema

Connect to your Neon database:
```bash
# Install psql if you don't have it
# Ubuntu/Debian: sudo apt-get install postgresql-client
# Mac: brew install postgresql

# Connect to Neon
psql "postgresql://YOUR_USER:YOUR_PASSWORD@YOUR_HOST/neondb?sslmode=require"
```

Then run this SQL (from NEON_MIGRATION_GUIDE.md):
```sql
-- Users table
CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(100) NOT NULL UNIQUE,
    full_name VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Products table  
CREATE TABLE products (
    product_id SERIAL PRIMARY KEY,
    product_name VARCHAR(100) NOT NULL,
    category VARCHAR(50),
    price DECIMAL(10, 2) NOT NULL,
    stock_quantity INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Orders table
CREATE TABLE orders (
    order_id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(user_id),
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(20) DEFAULT 'pending',
    total_amount DECIMAL(10, 2)
);

-- Order Items table
CREATE TABLE order_items (
    order_item_id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES orders(order_id),
    product_id INTEGER REFERENCES products(product_id),
    quantity INTEGER NOT NULL,
    unit_price DECIMAL(10, 2) NOT NULL
);

-- Insert mock data (optional for testing)
INSERT INTO users (username, email, full_name) VALUES
('john_doe', 'john@example.com', 'John Doe'),
('jane_smith', 'jane@example.com', 'Jane Smith'),
('bob_wilson', 'bob@example.com', 'Bob Wilson');

INSERT INTO products (product_name, category, price, stock_quantity) VALUES
('Laptop Pro', 'Electronics', 1299.99, 50),
('Wireless Mouse', 'Electronics', 29.99, 200),
('Office Chair', 'Furniture', 299.99, 30),
('Desk Lamp', 'Lighting', 49.99, 100);

INSERT INTO orders (user_id, status, total_amount) VALUES
(1, 'completed', 1329.98),
(2, 'pending', 349.98),
(3, 'shipped', 79.98);

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
(1, 1, 1, 1299.99),
(1, 2, 1, 29.99),
(2, 3, 1, 299.99),
(2, 4, 1, 49.99),
(3, 2, 2, 29.99);
```

## Step 2: Deploy Infrastructure

### 2.1 Set Your AWS Profile
```bash
export AWS_PROFILE=juandaserniCelliaLabsSuperA

# Verify it's set
echo $AWS_PROFILE
aws sts get-caller-identity
```

### 2.2 Deploy VPC Stack (with NAT Gateway)
```bash
cd /home/juandaserni/Documents/amazon-bedrock-agentcore-samples/02-use-cases/customer-support-assistant-vpc

aws cloudformation create-stack \
  --stack-name csvpc-neon-vpc-dev \
  --template-body file://cloudformation/vpc-stack-neon.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2

# Wait for completion (takes ~5-10 minutes due to NAT Gateway)
aws cloudformation wait stack-create-complete \
  --stack-name csvpc-neon-vpc-dev \
  --region us-west-2

echo "✅ VPC Stack created successfully!"
```

### 2.3 Deploy Neon Configuration Stack
```bash
# Replace with YOUR Neon credentials
NEON_HOST="ep-xxx-xxx-xxx.us-west-2.aws.neon.tech"
NEON_DATABASE="neondb"
NEON_USER="your_username"
NEON_PASSWORD="your_password"

aws cloudformation create-stack \
  --stack-name csvpc-neon-config-dev \
  --template-body file://cloudformation/neon-config-stack.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=NeonHost,ParameterValue="$NEON_HOST" \
    ParameterKey=NeonDatabase,ParameterValue="$NEON_DATABASE" \
    ParameterKey=NeonUser,ParameterValue="$NEON_USER" \
    ParameterKey=NeonPassword,ParameterValue="$NEON_PASSWORD" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2

# Wait for completion (~2 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name csvpc-neon-config-dev \
  --region us-west-2

echo "✅ Neon Configuration Stack created successfully!"
```

### 2.4 Deploy Remaining Stacks

You'll need to deploy the other stacks (Cognito, MCP, Gateway) if they don't exist yet. Then deploy the Agent Runtime stack:

```bash
# Deploy Agent Runtime Stack (after other stacks are ready)
aws cloudformation create-stack \
  --stack-name csvpc-neon-agent-dev \
  --template-body file://cloudformation/agent-server-stack-neon.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=VPCStackName,ParameterValue=csvpc-neon-vpc-dev \
    ParameterKey=CognitoStackName,ParameterValue=YOUR_COGNITO_STACK \
    ParameterKey=MCPStackName,ParameterValue=YOUR_MCP_STACK \
    ParameterKey=GatewayStackName,ParameterValue=YOUR_GATEWAY_STACK \
    ParameterKey=NeonStackName,ParameterValue=csvpc-neon-config-dev \
    ParameterKey=ModelID,ParameterValue="global.anthropic.claude-sonnet-4-20250514-v1:0" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2

# This takes 30-40 minutes (builds Docker image, creates runtime)
aws cloudformation wait stack-create-complete \
  --stack-name csvpc-neon-agent-dev \
  --region us-west-2

echo "✅ Agent Runtime Stack created successfully!"
```

## Step 3: Test Your Deployment

### 3.1 Verify Neon Connection
```bash
# Test from your local machine
psql "postgresql://$NEON_USER:$NEON_PASSWORD@$NEON_HOST/$NEON_DATABASE?sslmode=require" \
  -c "SELECT COUNT(*) FROM users;"
```

### 3.2 Check Agent Runtime
```bash
# Get Agent Runtime ARN
AGENT_RUNTIME_ARN=$(aws ssm get-parameter \
  --name /app/customersupportvpc/agentcore/agent_runtime_arn \
  --query 'Parameter.Value' \
  --output text \
  --region us-west-2)

echo "Agent Runtime ARN: $AGENT_RUNTIME_ARN"

# Check runtime status
aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id $(basename $AGENT_RUNTIME_ARN) \
  --region us-west-2
```

### 3.3 Test Agent with Query
```bash
# Use the test client (if available)
cd /home/juandaserni/Documents/amazon-bedrock-agentcore-samples/02-use-cases/customer-support-assistant-vpc

# Make sure to set AWS_PROFILE first
export AWS_PROFILE=juandaserniCelliaLabsSuperA

# Run test
uv run python test/connect_agent.py

# Try queries like:
# "Get all users from the database"
# "Show me products in the Electronics category"
# "What orders are pending?"
```

## Cost Monitor

### Expected Monthly Costs

**With Neon Free Tier:**
- NAT Gateway: $32.40
- NAT Data Transfer (1GB): ~$5
- Other AWS services: ~$10
- **Total: ~$47-52/month**

**With Neon Launch Plan ($19/month):**
- Neon: $19
- NAT Gateway: $32.40
- NAT Data Transfer: ~$5
- Other AWS services: ~$10
- **Total: ~$66-71/month**

### Savings vs Aurora
- **Original Aurora cost**: ~$288/month
- **Neon cost**: ~$47-71/month
- **Savings**: $217-241/month (76-83% reduction)

## Troubleshooting

### Issue: Can't connect to Neon from agent
**Solution**: Check Security Group allows outbound on port 5432
```bash
aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=csvpc-neon-dev-AgentRuntime-SG" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --region us-west-2
```

### Issue: NAT Gateway not routing
**Solution**: Verify route table has 0.0.0.0/0 → NAT Gateway
```bash
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=csvpc-neon-dev-Private-Routes" \
  --query 'RouteTables[0].Routes' \
  --region us-west-2
```

### Issue: Agent can't retrieve Neon secret
**Solution**: Check IAM role has SecretsManager permission
```bash
aws iam get-role-policy \
  --role-name csvpc-neon-dev-agent-runtime-execution-role \
  --policy-name AgentCoreRuntimeExecutionPolicy \
  --region us-west-2
```

## Cleanup (when done testing)

```bash
export AWS_PROFILE=juandaserniCelliaLabsSuperA

# Delete in reverse order
aws cloudformation delete-stack --stack-name csvpc-neon-agent-dev --region us-west-2
aws cloudformation delete-stack --stack-name csvpc-neon-config-dev --region us-west-2
aws cloudformation delete-stack --stack-name csvpc-neon-vpc-dev --region us-west-2

# Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name csvpc-neon-agent-dev --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name csvpc-neon-config-dev --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name csvpc-neon-vpc-dev --region us-west-2

echo "✅ All stacks deleted!"
```

## Files Created Summary

### Documentation (3 files)
- ✅ `NEON_MIGRATION_GUIDE.md` - Complete migration guide
- ✅ `NEON_IMPLEMENTATION.md` - Implementation details
- ✅ `DEPLOY_NEON.md` - This deployment guide

### CloudFormation (3 stacks)
- ✅ `cloudformation/vpc-stack-neon.yaml` - VPC with NAT Gateway
- ✅ `cloudformation/neon-config-stack.yaml` - Neon credentials
- ✅ `cloudformation/agent-server-stack-neon.yaml` - Agent runtime

### Agent Code (3 files)
- ✅ `agent/context.py` - Updated for Neon
- ✅ `agent/main.py` - Using Neon MCP client
- ✅ `agent/utils.py` - Has get_secret function

## Next Steps

1. ✅ Create Neon account and database (Step 1)
2. ✅ Run SQL schema creation (Step 1.4)
3. ✅ Deploy VPC stack (Step 2.2)
4. ✅ Deploy Neon config stack (Step 2.3)
5. ✅ Deploy agent stack (Step 2.4)
6. ✅ Test deployment (Step 3)

## Support

- **Documentation**: See `NEON_MIGRATION_GUIDE.md` for detailed architecture
- **Implementation**: See `NEON_IMPLEMENTATION.md` for code changes
- **Issues**: Check CloudWatch Logs for agent errors

## Success! 🎉

Once deployed, your Customer Support Assistant will be using:
- ✅ Neon serverless PostgreSQL (83% cost savings)
- ✅ NAT Gateway for secure internet access
- ✅ Same functionality as Aurora version
- ✅ Auto-scaling database (Neon handles this)
- ✅ Same high availability
