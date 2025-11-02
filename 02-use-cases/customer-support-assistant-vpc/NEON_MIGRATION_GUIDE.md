# Migration Guide: Aurora PostgreSQL to Neon

This guide covers the steps to migrate the Customer Support Assistant VPC project from AWS Aurora PostgreSQL to Neon serverless database.

## Overview of Changes

### Architecture Changes
1. **VPC Connectivity**: Added NAT Gateway and Internet Gateway for outbound internet access to Neon
2. **Database**: Replaced Aurora PostgreSQL with Neon serverless database
3. **MCP Client**: Changed from AWS postgres-mcp-server (RDS Data API) to standard PostgreSQL MCP client
4. **Cost**: Reduced from ~$293/month to potentially $0-19/month depending on usage

### What Was Removed
- Aurora PostgreSQL cluster and instance
- RDS Data API VPC endpoint
- psycopg2 Lambda layer build pipeline
- CodeBuild project for layer building
- DB subnet groups for Aurora
- Aurora-specific security groups
- Enhanced Monitoring for RDS

### What Was Added
- Internet Gateway for VPC
- NAT Gateway in public subnet
- Public subnets for NAT Gateway
- Elastic IP for NAT Gateway
- Neon configuration stack with Secrets Manager
- Direct PostgreSQL connection using psycopg2

## Prerequisites

### 1. Create Neon Account and Database

1. **Sign up for Neon**:
   - Visit https://neon.tech
   - Sign up for a free account or choose a paid plan

2. **Create a Project**:
   ```
   Project Name: customer-support-vpc
   Region: US West (Oregon) - to match us-west-2
   PostgreSQL Version: 15 or 16
   ```

3. **Get Connection Details**:
   ```
   Host: ep-xxx-xxx.us-west-2.aws.neon.tech
   Database: neondb (or your custom name)
   User: your_username
   Password: your_password
   Port: 5432
   ```

4. **Create Database Schema**:
   
   Connect to Neon using psql or the Neon SQL Editor and run:

   ```sql
   -- Users table
   CREATE TABLE users (
       id SERIAL PRIMARY KEY,
       customer_id VARCHAR(20) UNIQUE NOT NULL,
       username VARCHAR(50) UNIQUE NOT NULL,
       email VARCHAR(100) UNIQUE NOT NULL,
       first_name VARCHAR(50),
       last_name VARCHAR(50),
       created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
   );

   -- Products table
   CREATE TABLE products (
       id SERIAL PRIMARY KEY,
       name VARCHAR(100) NOT NULL,
       description TEXT,
       price DECIMAL(10,2),
       category VARCHAR(50),
       stock_quantity INTEGER DEFAULT 0,
       created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
   );

   -- Orders table
   CREATE TABLE orders (
       id SERIAL PRIMARY KEY,
       customer_id VARCHAR(20) REFERENCES users(customer_id),
       total_amount DECIMAL(10,2),
       status VARCHAR(20) DEFAULT 'pending',
       order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
   );

   -- Insert mock users
   INSERT INTO users (customer_id, username, email, first_name, last_name) VALUES
   ('CUST001', 'john_doe', 'john.doe@example.com', 'John', 'Doe'),
   ('CUST002', 'jane_smith', 'jane.smith@example.com', 'Jane', 'Smith'),
   ('CUST003', 'bob_johnson', 'bob.johnson@example.com', 'Bob', 'Johnson'),
   ('CUST004', 'alice_brown', 'alice.brown@example.com', 'Alice', 'Brown'),
   ('CUST005', 'charlie_davis', 'charlie.davis@example.com', 'Charlie', 'Davis');

   -- Insert mock products
   INSERT INTO products (name, description, price, category, stock_quantity) VALUES
   ('Laptop Pro', 'High-performance laptop for professionals', 1299.99, 'Electronics', 50),
   ('Wireless Mouse', 'Ergonomic wireless mouse', 29.99, 'Electronics', 100),
   ('Coffee Mug', 'Ceramic coffee mug with company logo', 12.99, 'Office Supplies', 200),
   ('Desk Chair', 'Comfortable ergonomic office chair', 299.99, 'Furniture', 25),
   ('USB Cable', 'High-speed USB-C cable', 19.99, 'Electronics', 150),
   ('Notebook', 'Spiral-bound notebook', 5.99, 'Office Supplies', 300),
   ('Monitor Stand', 'Adjustable monitor stand', 79.99, 'Office Supplies', 75),
   ('Keyboard', 'Mechanical keyboard with backlight', 89.99, 'Electronics', 60),
   ('Water Bottle', 'Stainless steel water bottle', 24.99, 'Office Supplies', 120),
   ('Webcam', 'HD webcam for video calls', 59.99, 'Electronics', 40);

   -- Insert mock orders
   INSERT INTO orders (customer_id, total_amount, status) VALUES
   ('CUST001', 1329.98, 'completed'),
   ('CUST002', 42.98, 'pending'),
   ('CUST003', 299.99, 'shipped'),
   ('CUST001', 89.99, 'completed'),
   ('CUST004', 37.98, 'pending');
   ```

## Deployment

### Step 1: Deploy Infrastructure

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

### Step 2: Verify Deployment

```bash
# Test the agent
uv run python test/connect_agent.py

# Test MCP server
uv run python test/connect_mcp.py

# Test Gateway
uv run python test/connect_gateway.py --prompt "Get customer profile for CUST001"
```

## Cost Comparison

### Before (Aurora)
```
Aurora db.r5.large: $292/month
Storage: $1/month
Total: ~$293/month
```

### After (Neon Free Tier)
```
Compute: $0 (within 191.9 hours/month)
Storage: $0 (within 0.5 GB)
NAT Gateway: $32/month + data transfer
Total: ~$32-40/month
```

### After (Neon Launch Plan)
```
Base: $19/month
NAT Gateway: $32/month + data transfer
Total: ~$51-60/month
```

**Net Savings**: $233-242/month (80-83% reduction)

## Architecture Differences

### Connection Method

**Before (Aurora)**:
```python
# Used RDS Data API (no direct connection)
aurora_client = MCPClient(
    lambda: stdio_client(
        StdioServerParameters(
            command="awslabs.postgres-mcp-server",
            args=[
                "--resource_arn", AURORA_CLUSTER_ARN,
                "--secret_arn", AURORA_SECRET_ARN,
                "--database", AURORA_DATABASE,
                "--region", AWS_REGION,
                "--readonly", "True",
            ]
        )
    )
)
```

**After (Neon)**:
```python
# Direct PostgreSQL connection via internet
neon_connection_string = f"postgresql://{user}:{password}@{host}:{port}/{database}"

neon_client = MCPClient(
    lambda: stdio_client(
        StdioServerParameters(
            command="uvx",
            args=["mcp-server-postgres", neon_connection_string]
        )
    )
)
```

### Network Path

**Before (Aurora)**:
```
Agent Runtime (VPC)
  → RDS Data API VPC Endpoint
  → Aurora (Same VPC)
```

**After (Neon)**:
```
Agent Runtime (VPC)
  → NAT Gateway
  → Internet Gateway
  → Public Internet (TLS encrypted)
  → Neon Infrastructure
```

## Troubleshooting

### Connection Issues

1. **Check NAT Gateway**:
   ```bash
   aws ec2 describe-nat-gateways \
     --filter "Name=vpc-id,Values=<vpc-id>" \
     --region us-west-2
   ```

2. **Verify Neon Credentials**:
   ```bash
   aws secretsmanager get-secret-value \
     --secret-id /app/customersupportvpc/neon/credentials \
     --region us-west-2
   ```

3. **Test Direct Connection**:
   ```bash
   psql "postgresql://user:pass@host:5432/db?sslmode=require"
   ```

### Performance Issues

- **Cold Starts**: Neon may have sub-second cold starts after inactivity
- **Latency**: Expect 10-50ms additional latency vs Aurora in same VPC
- **Scaling**: Neon auto-scales; no manual intervention needed

## Rollback Procedure

If you need to revert to Aurora:

1. **Keep Original Templates**: The old CloudFormation templates are preserved
2. **Export Neon Data**: Use `pg_dump` to backup Neon data
3. **Redeploy Aurora Stack**: Use the original `deploy.sh` without Neon parameters
4. **Import Data**: Use `psql` to import data into Aurora

## Security Considerations

### Data in Transit
- All connections to Neon use TLS 1.2+
- Credentials stored in AWS Secrets Manager with KMS encryption

### Data at Rest
- Neon provides encryption at rest
- Less control over encryption keys compared to AWS KMS

### Network Security
- VPC now has internet connectivity (NAT Gateway)
- Outbound traffic only; no inbound from internet
- Security groups restrict traffic appropriately

## Monitoring

### Neon Dashboard
- Access: https://console.neon.tech
- Metrics: Query performance, connection count, storage usage
- Logs: Query logs and error logs

### AWS CloudWatch
- NAT Gateway metrics still available
- VPC Flow Logs capture outbound traffic
- Agent Runtime logs unchanged

## Support

- **Neon Issues**: https://neon.tech/docs or support@neon.tech
- **AWS Issues**: AWS Support Console
- **Project Issues**: GitHub repository

## Next Steps

1. Monitor costs for first month
2. Adjust Neon plan based on actual usage
3. Consider Aurora Serverless v2 if need AWS-native solution
4. Implement connection pooling if needed (PgBouncer)
