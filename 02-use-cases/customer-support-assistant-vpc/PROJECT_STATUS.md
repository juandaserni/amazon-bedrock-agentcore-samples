# Customer Support Assistant VPC with Neon - Project Status & Troubleshooting

## Project Overview

This project deploys a customer support agent on AWS Bedrock AgentCore that:
- Runs in a VPC for security
- Uses **Neon PostgreSQL** (serverless database) instead of Aurora
- Connects to DynamoDB for product reviews
- Uses MCP servers and API Gateway for tools
- Uses Cognito for authentication

## Architecture

```
User → Cognito Auth → Agent Runtime (VPC) → {
    - Bedrock Model (Claude)
    - Neon PostgreSQL (customer data)
    - DynamoDB via MCP (product reviews)
    - API Gateway tools
}
```

## Current Status - What We've Deployed

✅ **Infrastructure (All Working):**
1. VPC with NAT Gateway
2. Neon database configuration
3. Cognito user authentication
4. DynamoDB tables
5. MCP server runtime
6. API Gateway
7. Agent Runtime container

✅ **Code Changes Made:**
1. Fixed `agent/main.py` - inlined SYSTEM_PROMPT to avoid import conflict
2. Fixed `agent/context.py` - added Neon database support
3. Fixed Lambda function - proper NetworkModeConfig handling

## Current Problem - Agent Not Responding

**Symptoms:**
```bash
👤 You: Hello
🤖 Assistant: [empty response]
```

**Root Cause Analysis:**

The agent returns empty responses, which means ONE of these issues:

### Issue 1: Docker Image Has Old Code ❌
- CodeBuild pulls from GitHub
- Your fixes are LOCAL but NOT in GitHub
- Docker image still has broken code with `from prompt import SYSTEM_PROMPT`

**Check:**
```bash
cd /home/juandaserni/Documents/amazon-bedrock-agentcore-samples
git status
```

If you see `modified: 02-use-cases/customer-support-assistant-vpc/agent/main.py`, then **this is the problem**.

### Issue 2: Agent Container Crashing ❓
- Python import error
- Missing dependencies
- Configuration error

**Check:**
```bash
# Look for errors in logs
aws logs filter-log-events \
  --log-group-name "/aws/vendedlogs/bedrock-agentcore/csvpcAgentRuntimeNeon-gXSm9F8HVd" \
  --start-time $(($(date +%s - 3600) * 1000)) \
  --filter-pattern "ERROR Exception Traceback" \
  --region us-west-2 \
  --query 'events[*].message' \
  --output text | tail -20
```

### Issue 3: Network Connectivity ❓
- Agent can't reach Neon database
- Agent can't reach MCP/Gateway
- VPC routing issues

**Check:**
```bash
# Verify NAT Gateway is available
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=*neon*" \
  --region us-west-2 \
  --query 'NatGateways[*].[NatGatewayId,State]' \
  --output table
```

## THE FIX - Step by Step

### Step 1: Verify Git Status (CRITICAL)

```bash
cd /home/juandaserni/Documents/amazon-bedrock-agentcore-samples
git status
```

**Expected output should show NO modified files in `agent/` directory.**

If you see modifications, you need to commit:

```bash
git add 02-use-cases/customer-support-assistant-vpc/agent/main.py
git commit -m "Fix: Inline SYSTEM_PROMPT to resolve import conflict"
git push origin main
```

### Step 2: Check Recent Agent Logs

```bash
cd /home/juandaserni/Documents/amazon-bedrock-agentcore-samples/02-use-cases/customer-support-assistant-vpc

export AWS_PROFILE=juandaserniCelliaLabsSuperA

# Get agent logs - look for ACTUAL errors
aws logs tail "/aws/vendedlogs/bedrock-agentcore/csvpcAgentRuntimeNeon-gXSm9F8HVd" \
  --since 2h \
  --region us-west-2 | grep -i "error\|exception\|failed\|traceback" | tail -30
```

**Share this output** - it will show the exact Python error!

### Step 3: Check Lambda Updated Runtime

```bash
# Check if Lambda successfully updated the runtime
aws logs tail "/aws/lambda/csvpc-neon-dev-agent-ecr-notification" \
  --since 2h \
  --region us-west-2 | tail -20
```

Look for:
- ✅ "Runtime updated successfully"
- ❌ "ValidationException" or other errors

### Step 4: Verify Current Docker Image

```bash
# What image is the runtime using?
aws ecr describe-images \
  --repository-name csvpc-neon-dev-agent-repository \
  --region us-west-2 \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imageTags[0],imagePushedAt]' \
  --output table
```

This shows the latest image. The agent should be using this.

## Most Likely Fix

Based on everything we've seen, the issue is:

1. **Your `main.py` fix is NOT in GitHub**
2. **CodeBuild keeps pulling OLD code**
3. **Docker image has broken code**
4. **Agent crashes on startup due to import error**

**The Solution:**

```bash
cd /home/juandaserni/Documents/amazon-bedrock-agentcore-samples

# 1. Verify main.py has the fix locally
grep -A 3 "System prompt - inline" 02-use-cases/customer-support-assistant-vpc/agent/main.py

# You should see:
# # System prompt - inline to avoid import conflicts with prompt/ directory
# SYSTEM_PROMPT = """

# 2. If fix is there, commit to GitHub
git add 02-use-cases/customer-support-assistant-vpc/agent/main.py
git commit -m "Fix: Inline SYSTEM_PROMPT to resolve import conflict with prompt/ directory"
git push origin main

# Wait 1 minute for GitHub to sync

# 3. Rebuild agent (pulls from GitHub)
cd 02-use-cases/customer-support-assistant-vpc
./rebuild-agent.sh

# This takes ~20 minutes
# After completion, test:
uv run python test/connect_agent.py
```

## Alternative: Quick Diagnostic

If you want to see what's wrong RIGHT NOW:

```bash
cd /home/juandaserni/Documents/amazon-bedrock-agentcore-samples/02-use-cases/customer-support-assistant-vpc

export AWS_PROFILE=juandaserniCelliaLabsSuperA

# Get last 100 lines of logs
aws logs tail "/aws/vendedlogs/bedrock-agentcore/csvpcAgentRuntimeNeon-gXSm9F8HVd" \
  --since 3h \
  --region us-west-2 \
  --format short > agent_logs.txt

# Look for errors
grep -i "error\|exception\|failed\|trac
