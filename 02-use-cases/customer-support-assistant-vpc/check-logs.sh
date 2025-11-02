#!/bin/bash

# Get agent runtime ID
AGENT_RUNTIME_ARN=$(aws ssm get-parameter \
  --name /app/customersupportvpc/agentcore/agent_runtime_arn \
  --query 'Parameter.Value' \
  --output text \
  --region us-west-2)

RUNTIME_ID=$(echo "$AGENT_RUNTIME_ARN" | awk -F'/' '{print $NF}')

echo "Fetching recent agent logs..."
echo "Runtime ID: $RUNTIME_ID"
echo ""

# Get logs from last 30 minutes
aws logs filter-log-events \
  --log-group-name "/aws/vendedlogs/bedrock-agentcore/${RUNTIME_ID}" \
  --start-time $(($(date +%s - 1800) * 1000)) \
  --region us-west-2 \
  --query 'events[*].message' \
  --output text | \
  while IFS= read -r line; do
    echo "$line" | jq -r 'if type == "object" then . else . end' 2>/dev/null || echo "$line"
  done | tail -50
