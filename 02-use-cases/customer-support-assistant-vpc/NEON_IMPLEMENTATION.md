# Neon Implementation Guide

## Summary

I've prepared the infrastructure components to migrate from Aurora PostgreSQL to Neon serverless database. This guide explains what's been created and what you need to do next.

## What's Been Created

### 1. Documentation
- **NEON_MIGRATION_GUIDE.md**: Comprehensive migration guide covering architecture changes, costs, deployment, and troubleshooting
- **NEON_IMPLEMENTATION.md** (this file): Step-by-step implementation guide

### 2. CloudFormation Templates
- **vpc-stack-neon.yaml**: Modified VPC stack with NAT Gateway for internet connectivity to Neon
- **neon-config-stack.yaml**: New stack for storing Neon credentials in Secrets Manager

### 3. Key Changes Made

#### VPC Stack (vpc-stack-neon.yaml)
- ✅ Added Internet Gateway
- ✅ Added NAT Gateway with Elastic IP
- ✅ Added Public Subnet for NAT Gateway
- ✅ Modified Private Route Table to route to NAT Gateway
- ✅ Updated Security Groups to allow outbound HTTPS (443) and PostgreSQL (5432)
- ✅ Removed RDS Data API VPC Endpoint (not needed for Neon)
- ✅ Kept all other VPC endpoints for AWS services

#### Neon Config Stack (neon-config-stack.yaml)
- ✅ Stores Neon credentials in Secrets Manager with KMS encryption
- ✅ Creates SSM Parameters for easy access to connection details
- ✅ Provides connection string format

## What Still Needs To Be Done

### Phase 1: Prerequisites

#### 1. Create Neon Account and Database

1. **Sign up at** https://neon.tech
2. **Create a new project**:
   - Name: `customer-support-vpc`
   - Region: **US West (Oregon)** (to match us-west-2)
   - PostgreSQL Version: 15 or 16

3. **Get your connection details**:
   ```
   Host: ep-xxx-xxx-xxx.us-west-2.aws.neon.tech
   Database: neondb
   User: your_username
   Password: (auto-generated)
   Port: 5432
   ```

4. **Create the schema** using Neon SQL Editor or psql:
   ```bash
   # Connect to Neon
   psql "postgresql://user:pass@ep-xxx.us-west-2.aws.neon.tech/neondb?sslmode=require"
   ```

   Then run the SQL from `NEON_MIGRATION_GUIDE.md` (section: Create Database Schema)

### Phase 2: Agent Code Changes

You'll need to modify the agent code to use Neon instead of Aurora:

#### File: `agent/main.py`

**Current code** (lines ~50-60):
```python
# Aurora PostgreSQL environment variables
AURORA_CLUSTER_ARN = get_required_env("AURORA_CLUSTER_ARN")
AURORA_SECRET_ARN = get_required_env("AURORA_SECRET_ARN")
AURORA_DATABASE = get_required_env("AURORA_DATABASE")
AWS_REGION = os.getenv("AWS_REGION", MCP_REGION)
```

**Replace with**:
```python
# Neon PostgreSQL environment variables
NEON_SECRET_ARN = get_required_env("NEON_SECRET_ARN")
AWS_REGION = os.getenv("AWS_REGION", MCP_REGION)
```

**Current code** (lines ~150-170):
```python
aurora_mcp_env = {
    "FASTMCP_LOG_LEVEL": "DEBUG",
    "AWS_REGION": AWS_REGION,
    "AWS_DEFAULT_REGION": AWS_REGION,
}
aurora_client = MCPClient(
    lambda: stdio_client(
        StdioServerParameters(
            command="awslabs.postgres-mcp-server",
            args=[
                "--resource_arn",
                AURORA_CLUSTER_ARN,
                "--secret_arn",
                AURORA_SECRET_ARN,
                "--database",
                AURORA_DATABASE,
                "--region",
                AWS_REGION,
                "--readonly",
                "True",
            ],
            env=aurora_mcp_env,
        )
    )
)
```

**Replace with**:
```python
# Get Neon credentials from Secrets Manager
def get_neon_connection_string():
    secret = get_secret(NEON_SECRET_ARN)
    return f"postgresql://{secret['username']}:{secret['password']}@{secret['host']}:{secret['port']}/{secret['database']}?sslmode={secret.get('sslmode', 'require')}"

neon_connection_string = get_neon_connection_string()

neon_client = MCPClient(
    lambda: stdio_client(
        StdioServerParameters(
            command="uvx",
            args=[
                "mcp-server-postgres",
                neon_connection_string
            ]
        )
    )
)
```

**Current code** (lines ~185-190):
```python
# Store clients in context
CustomerSupportContext.set_mcp_client_ctx(mcp_client)
CustomerSupportContext.set_gateway_client_ctx(gateway_client)
CustomerSupportContext.set_aurora_mcp_client_ctx(aurora_client)
```

**Replace with**:
```python
# Store clients in context
CustomerSupportContext.set_mcp_client_ctx(mcp_client)
CustomerSupportContext.set_gateway_client_ctx(gateway_client)
CustomerSupportContext.set_neon_mcp_client_ctx(neon_client)  # Changed name
```

**Current code** (lines ~195-200):
```python
gateway_tools = gateway_client.list_tools_sync()
mcp_tools = mcp_client.list_tools_sync()
aurora_tools = aurora_client.list_tools_sync()
```

**Replace with**:
```python
gateway_tools = gateway_client.list_tools_sync()
mcp_tools = mcp_client.list_tools_sync()
neon_tools = neon_client.list_tools_sync()  # Changed name
```

**Current code** (lines ~205-210):
```python
agent = Agent(
    model=model,
    tools=gateway_tools + mcp_tools + aurora_tools,
    system_prompt=SYSTEM_PROMPT,
)

agent.tool.get_table_schema(table_name="users")
agent.tool.get_table_schema(table_name="products")
agent.tool.get_table_schema(table_name="orders")
```

**Replace with**:
```python
agent = Agent(
    model=model,
    tools=gateway_tools + mcp_tools + neon_tools,  # Changed name
    system_prompt=SYSTEM_PROMPT,
)

# Note: Schema discovery with Neon is handled by mcp-server-postgres automatically
```

**Current code** (cleanup section, lines ~240-250):
```python
aurora_client = CustomerSupportContext.get_aurora_mcp_client_ctx()
if aurora_client is not None:
    try:
        aurora_client.stop()
        logger.info("Aurora client stopped")
    except Exception as e:
        logger.error(f"Error stopping Aurora client: {e}")
```

**Replace with**:
```python
neon_client = CustomerSupportContext.get_neon_mcp_client_ctx()  # Changed name
if neon_client is not None:
    try:
        neon_client.stop()
        logger.info("Neon client stopped")
    except Exception as e:
        logger.error(f"Error stopping Neon client: {e}")
```

#### File: `agent/context.py`

You'll need to update the context variable name from `aurora_mcp_client_ctx` to `neon_mcp_client_ctx`:

```python
# Find and replace
aurora_mcp_client_ctx → neon_mcp_client_ctx
get_aurora_mcp_client_ctx → get_neon_mcp_client_ctx
set_aurora_mcp_client_ctx → set_neon_mcp_client_ctx
```

#### File: `agent/utils.py`

Add the `get_secret` function if it doesn't exist:

```python
import boto3
import json

def get_secret(secret_arn: str) -> dict:
    """Get secret from AWS Secrets Manager"""
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=secret_arn)
    return json.loads(response["SecretString"])
```

### Phase 3: CloudFormation Stack Changes

#### Create: `cloudformation/agent-server-stack-neon.yaml`

This is a modified version of `agent-server-stack.yaml`. Key changes:

**Environment Variables** (in the Agent Runtime resource):

**Remove**:
```yaml
AURORA_CLUSTER_ARN: !Sub '${AuroraStackName}-ClusterArn'
AURORA_SECRET_ARN: !Sub '${AuroraStackName}-DBCredentialsSecret'
AURORA_DATABASE: !Sub '${AuroraStackName}-DatabaseName'
```

**Add**:
```yaml
NEON_SECRET_ARN: !Sub '${NeonStackName}-SecretArn'
```

**Parameters** - Remove Aurora references:

**Remove**:
```yaml
AuroraStackName:
  Type: String
  Description: 'Name of the Aurora stack'
```

**Add**:
```yaml
NeonStackName:
  Type: String
  Description: 'Name of the Neon configuration stack'
```

#### Create: `cloudformation/customer-support-stack-neon.yaml`

This is the master stack that orchestrates all nested stacks. Modify it to:

1. Replace `aurora-postgres-stack.yaml` with `neon-config-stack.yaml`
2. Use `vpc-stack-neon.yaml` instead of `vpc-stack.yaml`
3. Use `agent-server-stack-neon.yaml` instead of `agent-server-stack.yaml`
4. Remove Aurora-related parameters and add Neon parameters

### Phase 4: Deployment Script Changes

#### Modify: `deploy.sh`

Add Neon credential parameters:

```bash
# Add these variables
NEON_HOST=""
NEON_DATABASE="neondb"
NEON_USER=""
NEON_PASSWORD=""

# Add these command line arguments
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
```

Update the CloudFormation parameters passed to the stack:

```bash
--parameters \
    ParameterKey=TemplateBaseURL,ParameterValue="$base_url" \
    ParameterKey=Environment,ParameterValue="$ENVIRONMENT" \
    ParameterKey=ModelID,ParameterValue="$MODEL_ID" \
    ParameterKey=AdminUserEmail,ParameterValue="$ADMIN_EMAIL" \
    ParameterKey=AdminUserPassword,ParameterValue="$ADMIN_PASSWORD" \
    ParameterKey=NeonHost,ParameterValue="$NEON_HOST" \
    ParameterKey=NeonDatabase,ParameterValue="$NEON_DATABASE" \
    ParameterKey=NeonUser,ParameterValue="$NEON_USER" \
    ParameterKey=NeonPassword,ParameterValue="$NEON_PASSWORD" \
```

## Deployment Steps

### Step 1: Set Up Neon Database

1. Create Neon account and project
2. Run the schema SQL (from NEON_MIGRATION_GUIDE.md)
3. Note down your connection credentials

### Step 2: Make Code Changes

1. Update `agent/main.py` with Neon client code
2. Update `agent/context.py` to rename Aurora → Neon references
3. Ensure `agent/utils.py` has `get_secret` function

### Step 3: Create Modified CloudFormation Templates

1. Create `cloudformation/agent-server-stack-neon.yaml`
2. Create `cloudformation/customer-support-stack-neon.yaml`
3. Update `deploy.sh` with Neon parameters

### Step 4: Deploy

```bash
./deploy.sh \
  --region us-west-2 \
  --env dev \
  --email admin@example.com \
  --password 'YourSecureP@ssw0rd' \
  --neon-host "ep-xxx-xxx.us-west-2.aws.neon.tech" \
  --neon-database "neondb" \
  --neon-user "your_username" \
  --neon-password "your_neon_password"
```

### Step 5: Test

```bash
# Test agent
uv run python test/connect_agent.py

# Test with a query
# "Get all users from the database"
# "Show me products in the Electronics category"
```

## Quick Start (If You Want Me To Continue)

Would you like me to:

1. ✅ **Create the modified agent code files** (`agent/main.py`, `agent/context.py`)
2. ✅ **Create the modified CloudFormation stacks** (`agent-server-stack-neon.yaml`, `customer-support-stack-neon.yaml`)
3. ✅ **Update the deployment script** (`deploy.sh`)
4. ✅ **Create a simplified README** for the Neon version

Just let me know and I'll create all the remaining files!

## Cost Estimate

### With Neon Free Tier
- NAT Gateway: ~$32/month
- NAT Data Transfer: ~$5-10/month  
- Other AWS services: ~$10/month (Gateway, MCP, DynamoDB)
- **Total: ~$47-52/month**
- **Savings vs Aurora: ~$241/month (83%)**

### With Neon Launch Plan ($19/month)
- Neon: $19/month
- NAT Gateway: ~$32/month
- NAT Data Transfer: ~$5-10/month
- Other AWS services: ~$10/month
- **Total: ~$66-71/month**
- **Savings vs Aurora: ~$222/month (76%)**

## Support

If you encounter issues:
- Check NEON_MIGRATION_GUIDE.md for troubleshooting
- Verify Neon credentials in Secrets Manager
- Check NAT Gateway is provisioned correctly
- Review CloudWatch Logs for agent errors
- Test direct connection to Neon with psql

## Next Steps

1. Review this implementation guide
2. Decide if you want me to create the remaining files
3. Set up your Neon database
4. Deploy and test!
