# AWS Fargate Deployment Guide

Guide for deploying Cyrus on AWS Fargate (ECS). Fargate adds complexity due to its stateless/ephemeral nature - **EC2 is recommended** for simpler deployments.

---

## ⚠️ Important Considerations

**Fargate is designed for stateless applications.** Cyrus requires:
- ✅ Persistent storage (repos, worktrees, config)
- ✅ SSH keys for GitHub authentication
- ✅ GitHub CLI authentication state
- ✅ Git configuration

### Fargate Challenges

| Challenge | Solution | Complexity |
|-----------|----------|------------|
| Persistent volumes | EFS mount | Medium |
| SSH keys | AWS Secrets Manager + init script | Medium |
| GitHub CLI auth | EFS-backed config directory | Medium |
| Git config | Init script on container start | Low |
| Container replacement | State must survive restarts | High |
| Cold starts | Slower than EC2 | Low |

### When to Use Fargate

**Good for:**
- ✅ Teams with AWS infrastructure expertise
- ✅ Organizations already using ECS/Fargate
- ✅ Containerized infrastructure requirements
- ✅ Auto-scaling needs (though Cyrus is single-instance)

**Not good for:**
- ❌ Simple deployments (use EC2 instead)
- ❌ Cost-sensitive scenarios (EC2 is cheaper for 24/7 workloads)
- ❌ Teams without AWS EFS/ECS experience

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│           Application Load Balancer              │
│         (SSL termination, port 443)              │
└────────────────┬────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────┐
│         ECS Fargate Task (cyrus)                │
│  ┌───────────────────────────────────────────┐  │
│  │  Cyrus Container                          │  │
│  │  - Node.js application                    │  │
│  │  - Port 3456                              │  │
│  └───────────────────────────────────────────┘  │
│                                                  │
│  Mounts:                                         │
│  - /data/cyrus → EFS (persistent)               │
│  - /root/.ssh → EFS (SSH keys)                  │
│  - /root/.config/gh → EFS (GitHub CLI)          │
└──────────────────────────────────────────────────┘
                 │
                 │
┌────────────────▼────────────────────────────────┐
│           Elastic File System (EFS)              │
│  - Cyrus data (config.json, repos, worktrees)  │
│  - SSH keys for GitHub                          │
│  - GitHub CLI auth state                        │
└──────────────────────────────────────────────────┘
```

---

## Prerequisites

- [ ] AWS account with ECS, EFS, ECR access
- [ ] AWS CLI configured locally
- [ ] Docker installed locally
- [ ] Domain with Route 53 (or external DNS)
- [ ] Linear admin access
- [ ] GitHub access to your organization
- [ ] Claude Code OAuth token

---

## Part 1: Create AWS Resources

### Step 1.1: Create EFS File System

```bash
# Create EFS file system
aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value=cyrus-data \
  --region us-east-1

# Note the FileSystemId (e.g., fs-0123456789abcdef)
EFS_ID="fs-0123456789abcdef"
```

### Step 1.2: Create EFS Mount Targets

```bash
# Get your VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)

# Get subnet IDs (use at least 2 AZs for redundancy)
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text)

# Create security group for EFS
EFS_SG=$(aws ec2 create-security-group \
  --group-name cyrus-efs-sg \
  --description "Security group for Cyrus EFS" \
  --vpc-id $VPC_ID \
  --output text --query 'GroupId')

# Allow NFS from ECS tasks
aws ec2 authorize-security-group-ingress \
  --group-id $EFS_SG \
  --protocol tcp \
  --port 2049 \
  --source-group $EFS_SG

# Create mount targets in each subnet
for SUBNET_ID in $SUBNET_IDS; do
  aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $SUBNET_ID \
    --security-groups $EFS_SG
done
```

### Step 1.3: Create ECR Repository

```bash
# Create ECR repository for Cyrus image
aws ecr create-repository \
  --repository-name cyrus \
  --region us-east-1

# Note the repository URI
ECR_URI=$(aws ecr describe-repositories --repository-names cyrus --query 'repositories[0].repositoryUri' --output text)
echo "ECR URI: $ECR_URI"
```

### Step 1.4: Create Secrets in AWS Secrets Manager

```bash
# Create secret for Linear OAuth
aws secretsmanager create-secret \
  --name cyrus/linear-oauth \
  --description "Linear OAuth credentials for Cyrus" \
  --secret-string '{
    "CLIENT_ID": "your_linear_client_id",
    "CLIENT_SECRET": "your_linear_client_secret",
    "WEBHOOK_SECRET": "your_linear_webhook_secret"
  }'

# Create secret for Claude OAuth token
aws secretsmanager create-secret \
  --name cyrus/claude-token \
  --description "Claude Code OAuth token" \
  --secret-string '{
    "OAUTH_TOKEN": "your_claude_oauth_token"
  }'

# Create secret for GitHub SSH private key
# First, generate the key locally or use existing one
aws secretsmanager create-secret \
  --name cyrus/github-ssh-key \
  --description "GitHub SSH private key for Cyrus" \
  --secret-string file://~/.ssh/id_ed25519
```

---

## Part 2: Build and Push Docker Image

### Step 2.1: Update Dockerfile for Fargate

Create `Dockerfile.fargate`:

```dockerfile
FROM node:20-alpine AS base

# Install system dependencies
RUN apk add --no-cache \
    git \
    jq \
    openssh-client \
    bash \
    curl \
    github-cli

WORKDIR /app

# Copy package files
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/cli/package.json ./apps/cli/
COPY packages/*/package.json ./packages/*/

# Install pnpm and dependencies
RUN npm install -g pnpm@10.13.1
RUN pnpm install --frozen-lockfile --prod=false

# Copy source and build
COPY . .
RUN pnpm build

# Create cyrus user
RUN addgroup -g 1000 cyrus && \
    adduser -D -u 1000 -G cyrus cyrus

# Create directories
RUN mkdir -p /data/cyrus /root/.ssh /root/.config/gh && \
    chown -R cyrus:cyrus /data/cyrus

# Copy init script
COPY docker/fargate-init.sh /usr/local/bin/fargate-init.sh
RUN chmod +x /usr/local/bin/fargate-init.sh

USER cyrus

ENV NODE_ENV=production
ENV CYRUS_HOME=/data/cyrus
ENV HOME=/home/cyrus

EXPOSE 3456

# Use init script as entrypoint
ENTRYPOINT ["/usr/local/bin/fargate-init.sh"]
CMD ["node", "/app/apps/cli/dist/src/app.js"]
```

### Step 2.2: Create Init Script

Create `docker/fargate-init.sh`:

```bash
#!/bin/bash
set -e

echo "[Fargate Init] Starting initialization..."

# Configure Git
if [ ! -f /root/.gitconfig ]; then
  echo "[Fargate Init] Configuring Git..."
  git config --global user.name "Cyrus AI"
  git config --global user.email "cyrus@example.com"
fi

# Set up SSH keys from AWS Secrets Manager (if not mounted from EFS)
if [ -n "$SSH_KEY_SECRET_ARN" ] && [ ! -f /root/.ssh/id_ed25519 ]; then
  echo "[Fargate Init] Setting up SSH key from Secrets Manager..."

  # Fetch SSH key from Secrets Manager
  SSH_KEY=$(aws secretsmanager get-secret-value \
    --secret-id "$SSH_KEY_SECRET_ARN" \
    --query SecretString \
    --output text)

  mkdir -p /root/.ssh
  echo "$SSH_KEY" > /root/.ssh/id_ed25519
  chmod 600 /root/.ssh/id_ed25519

  # Add GitHub to known hosts
  ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null
fi

# Ensure proper permissions on EFS mounts
if [ -d /data/cyrus ]; then
  echo "[Fargate Init] Checking EFS mount permissions..."
  chown -R cyrus:cyrus /data/cyrus 2>/dev/null || true
fi

echo "[Fargate Init] Initialization complete. Starting Cyrus..."

# Execute the main command
exec "$@"
```

### Step 2.3: Build and Push Image

```bash
# Build the image
docker build -f Dockerfile.fargate -t cyrus:latest .

# Authenticate to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_URI

# Tag and push
docker tag cyrus:latest $ECR_URI:latest
docker push $ECR_URI:latest
```

---

## Part 3: Create ECS Resources

### Step 3.1: Create ECS Cluster

```bash
aws ecs create-cluster \
  --cluster-name cyrus-cluster \
  --region us-east-1
```

### Step 3.2: Create IAM Roles

**Task Execution Role** (for pulling images and secrets):

```bash
# Create trust policy
cat > task-execution-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role
aws iam create-role \
  --role-name cyrusEcsTaskExecutionRole \
  --assume-role-policy-document file://task-execution-trust-policy.json

# Attach AWS managed policy
aws iam attach-role-policy \
  --role-name cyrusEcsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Create custom policy for Secrets Manager access
cat > secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "kms:Decrypt"
      ],
      "Resource": [
        "arn:aws:secretsmanager:us-east-1:*:secret:cyrus/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name cyrusEcsTaskExecutionRole \
  --policy-name SecretsManagerAccess \
  --policy-document file://secrets-policy.json
```

**Task Role** (for runtime permissions):

```bash
# Create task role for runtime operations
cat > task-role-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name cyrusEcsTaskRole \
  --assume-role-policy-document file://task-role-trust-policy.json
```

### Step 3.3: Create Task Definition

Create `task-definition.json`:

```json
{
  "family": "cyrus",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "2048",
  "memory": "4096",
  "executionRoleArn": "arn:aws:iam::YOUR_ACCOUNT_ID:role/cyrusEcsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::YOUR_ACCOUNT_ID:role/cyrusEcsTaskRole",
  "containerDefinitions": [
    {
      "name": "cyrus",
      "image": "YOUR_ECR_URI:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3456,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "CYRUS_BASE_URL",
          "value": "https://cyrus.yourdomain.com"
        },
        {
          "name": "CYRUS_SERVER_PORT",
          "value": "3456"
        },
        {
          "name": "CYRUS_HOME",
          "value": "/data/cyrus"
        },
        {
          "name": "CYRUS_HOST_EXTERNAL",
          "value": "true"
        },
        {
          "name": "LINEAR_DIRECT_WEBHOOKS",
          "value": "true"
        }
      ],
      "secrets": [
        {
          "name": "LINEAR_CLIENT_ID",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:YOUR_ACCOUNT_ID:secret:cyrus/linear-oauth:CLIENT_ID::"
        },
        {
          "name": "LINEAR_CLIENT_SECRET",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:YOUR_ACCOUNT_ID:secret:cyrus/linear-oauth:CLIENT_SECRET::"
        },
        {
          "name": "LINEAR_WEBHOOK_SECRET",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:YOUR_ACCOUNT_ID:secret:cyrus/linear-oauth:WEBHOOK_SECRET::"
        },
        {
          "name": "CLAUDE_CODE_OAUTH_TOKEN",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:YOUR_ACCOUNT_ID:secret:cyrus/claude-token:OAUTH_TOKEN::"
        }
      ],
      "mountPoints": [
        {
          "sourceVolume": "cyrus-data",
          "containerPath": "/data/cyrus",
          "readOnly": false
        },
        {
          "sourceVolume": "ssh-keys",
          "containerPath": "/root/.ssh",
          "readOnly": false
        },
        {
          "sourceVolume": "gh-config",
          "containerPath": "/root/.config/gh",
          "readOnly": false
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/cyrus",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:3456/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ],
  "volumes": [
    {
      "name": "cyrus-data",
      "efsVolumeConfiguration": {
        "fileSystemId": "fs-0123456789abcdef",
        "rootDirectory": "/cyrus-data",
        "transitEncryption": "ENABLED"
      }
    },
    {
      "name": "ssh-keys",
      "efsVolumeConfiguration": {
        "fileSystemId": "fs-0123456789abcdef",
        "rootDirectory": "/ssh-keys",
        "transitEncryption": "ENABLED"
      }
    },
    {
      "name": "gh-config",
      "efsVolumeConfiguration": {
        "fileSystemId": "fs-0123456789abcdef",
        "rootDirectory": "/gh-config",
        "transitEncryption": "ENABLED"
      }
    }
  ]
}
```

**Register the task definition:**

```bash
# Create CloudWatch log group first
aws logs create-log-group --log-group-name /ecs/cyrus

# Register task definition
aws ecs register-task-definition \
  --cli-input-json file://task-definition.json
```

---

## Part 4: Create Load Balancer and Service

### Step 4.1: Create Application Load Balancer

```bash
# Create security group for ALB
ALB_SG=$(aws ec2 create-security-group \
  --group-name cyrus-alb-sg \
  --description "Security group for Cyrus ALB" \
  --vpc-id $VPC_ID \
  --output text --query 'GroupId')

# Allow inbound HTTP and HTTPS
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0

# Create ALB
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name cyrus-alb \
  --subnets $SUBNET_IDS \
  --security-groups $ALB_SG \
  --scheme internet-facing \
  --type application \
  --output text --query 'LoadBalancers[0].LoadBalancerArn')

# Note the DNS name
aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' \
  --output text
```

### Step 4.2: Create Target Group

```bash
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
  --name cyrus-tg \
  --protocol HTTP \
  --port 3456 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --output text --query 'TargetGroups[0].TargetGroupArn')
```

### Step 4.3: Request SSL Certificate

```bash
# Request certificate from ACM
CERT_ARN=$(aws acm request-certificate \
  --domain-name cyrus.yourdomain.com \
  --validation-method DNS \
  --output text --query 'CertificateArn')

# Follow DNS validation instructions in ACM console
# Or use this command to get CNAME records to add to Route 53
aws acm describe-certificate \
  --certificate-arn $CERT_ARN \
  --query 'Certificate.DomainValidationOptions'
```

### Step 4.4: Create ALB Listeners

```bash
# HTTP listener (redirect to HTTPS)
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=redirect,RedirectConfig="{Protocol=HTTPS,Port=443,StatusCode=HTTP_301}"

# HTTPS listener
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=$CERT_ARN \
  --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN
```

### Step 4.5: Create ECS Service

```bash
# Create security group for ECS tasks
TASK_SG=$(aws ec2 create-security-group \
  --group-name cyrus-task-sg \
  --description "Security group for Cyrus ECS tasks" \
  --vpc-id $VPC_ID \
  --output text --query 'GroupId')

# Allow inbound from ALB on port 3456
aws ec2 authorize-security-group-ingress \
  --group-id $TASK_SG \
  --protocol tcp \
  --port 3456 \
  --source-group $ALB_SG

# Allow outbound to EFS
aws ec2 authorize-security-group-ingress \
  --group-id $EFS_SG \
  --protocol tcp \
  --port 2049 \
  --source-group $TASK_SG

# Create ECS service
aws ecs create-service \
  --cluster cyrus-cluster \
  --service-name cyrus-service \
  --task-definition cyrus \
  --desired-count 1 \
  --launch-type FARGATE \
  --platform-version LATEST \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
  --load-balancers targetGroupArn=$TARGET_GROUP_ARN,containerName=cyrus,containerPort=3456 \
  --health-check-grace-period-seconds 60
```

---

## Part 5: Initialize Cyrus

### Step 5.1: Configure DNS

Point your domain to the ALB:

```bash
# If using Route 53, create an alias record
aws route53 change-resource-record-sets \
  --hosted-zone-id YOUR_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "cyrus.yourdomain.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z35SXDOTRQ7X7K",
          "DNSName": "'"$ALB_DNS_NAME"'",
          "EvaluateTargetHealth": false
        }
      }
    }]
  }'
```

### Step 5.2: Configure GitHub SSH and CLI

Since we're using EFS, we need to set this up once:

```bash
# Get the task ID
TASK_ARN=$(aws ecs list-tasks --cluster cyrus-cluster --service-name cyrus-service --query 'taskArns[0]' --output text)

# Execute commands in the container
# Note: This requires Amazon ECS Exec to be enabled

# Generate SSH key
aws ecs execute-command \
  --cluster cyrus-cluster \
  --task $TASK_ARN \
  --container cyrus \
  --interactive \
  --command "ssh-keygen -t ed25519 -C 'cyrus@fargate' -f /root/.ssh/id_ed25519 -N ''"

# Get public key
aws ecs execute-command \
  --cluster cyrus-cluster \
  --task $TASK_ARN \
  --container cyrus \
  --command "cat /root/.ssh/id_ed25519.pub"

# Add to GitHub: https://github.com/settings/keys

# Configure Git
aws ecs execute-command \
  --cluster cyrus-cluster \
  --task $TASK_ARN \
  --container cyrus \
  --command "git config --global user.name 'Cyrus AI'"

aws ecs execute-command \
  --cluster cyrus-cluster \
  --task $TASK_ARN \
  --container cyrus \
  --command "git config --global user.email 'cyrus@example.com'"

# Configure GitHub CLI
aws ecs execute-command \
  --cluster cyrus-cluster \
  --task $TASK_ARN \
  --container cyrus \
  --interactive \
  --command "gh auth login"
```

### Step 5.3: Authorize Linear and Add Repositories

```bash
# Authorize with Linear
aws ecs execute-command \
  --cluster cyrus-cluster \
  --task $TASK_ARN \
  --container cyrus \
  --interactive \
  --command "cyrus self-auth"

# Add repositories
aws ecs execute-command \
  --cluster cyrus-cluster \
  --task $TASK_ARN \
  --container cyrus \
  --interactive \
  --command "cyrus self-add-repo git@github.com:yourorg/repo.git 'Your Workspace'"
```

---

## Cost Estimation

**Monthly costs for 24/7 operation:**

- ECS Fargate (2 vCPU, 4GB): ~$60/month
- EFS storage (10GB): ~$3/month
- ALB: ~$16/month
- Data transfer: ~$5-10/month
- Secrets Manager: ~$1/month

**Total: ~$85-90/month**

**Compare to EC2 (t3.medium):**
- EC2 instance: ~$30/month
- EBS storage (30GB): ~$3/month
- **Total: ~$33/month**

**Fargate is 2.5x more expensive than EC2** for this workload.

---

## Troubleshooting

### EFS Mount Issues

```bash
# Check EFS mount targets
aws efs describe-mount-targets --file-system-id $EFS_ID

# Verify security groups allow NFS (port 2049)
aws ec2 describe-security-groups --group-ids $EFS_SG $TASK_SG
```

### Task Keeps Restarting

```bash
# Check logs
aws logs tail /ecs/cyrus --follow

# Describe task to see stopped reason
aws ecs describe-tasks --cluster cyrus-cluster --tasks $TASK_ARN
```

### Cannot Access Container

```bash
# Enable ECS Exec on service
aws ecs update-service \
  --cluster cyrus-cluster \
  --service cyrus-service \
  --enable-execute-command

# Wait for new task to start
aws ecs execute-command --cluster cyrus-cluster --task $NEW_TASK_ARN --container cyrus --interactive --command "/bin/bash"
```

---

## Recommendation

**For most users, EC2 is simpler and cheaper:**
- ✅ Easier setup (no EFS, no complex IAM)
- ✅ 65% lower cost ($33 vs $90/month)
- ✅ Faster cold starts
- ✅ Simpler troubleshooting

**Use Fargate only if:**
- Your team already uses ECS/Fargate
- You need container orchestration features
- You have strict infrastructure-as-code requirements

See [TICKETLAYER_DEPLOYMENT.md](./TICKETLAYER_DEPLOYMENT.md) for the recommended EC2 deployment.
