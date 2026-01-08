# Ticketlayer AWS Deployment Guide

Complete step-by-step guide for deploying Cyrus on AWS with nginx reverse proxy for the ticketlayer GitHub organization.

---

## Overview

This guide walks you through:
1. Setting up AWS EC2 instance
2. Configuring domain and SSL with nginx
3. Installing Docker and Cyrus
4. Configuring GitHub access for private ticketlayer repos
5. Setting up Linear OAuth integration
6. Adding ticketlayer repositories (backstage-api, backstage-app, etc.)

**Estimated setup time:** 30-45 minutes

---

## Prerequisites Checklist

Before you begin, ensure you have:

- [ ] AWS account with EC2 access
- [ ] Domain name you control (for cyrus.yourdomain.com)
- [ ] Linear workspace with admin access
- [ ] GitHub account with access to ticketlayer organization
- [ ] Claude Code installed locally (to get OAuth token)
- [ ] SSH key pair for accessing AWS

---

## Part 1: AWS EC2 Setup

### Step 1.1: Launch EC2 Instance

1. **Go to AWS EC2 Console:**
   - Navigate to: https://console.aws.amazon.com/ec2/
   - Select your preferred region (e.g., us-east-1)

2. **Launch Instance:**
   - Click **Launch Instance**
   - Name: `cyrus-production`

3. **Configure Instance:**
   ```
   AMI: Ubuntu Server 22.04 LTS (HVM), SSD Volume Type
   Instance Type: t3.medium (2 vCPU, 4 GB RAM)
   Key Pair: Select or create new key pair for SSH access
   ```

4. **Network Settings:**
   - VPC: Default (or your custom VPC)
   - Subnet: No preference
   - Auto-assign public IP: Enable

5. **Configure Security Group:**
   Create a new security group with these rules:
   ```
   Type         Protocol  Port Range  Source      Description
   SSH          TCP       22          Your IP     SSH access
   HTTP         TCP       80          0.0.0.0/0   HTTP for Let's Encrypt
   HTTPS        TCP       443         0.0.0.0/0   HTTPS for webhooks
   Custom TCP   TCP       3456        127.0.0.1   Cyrus (internal only)
   ```

6. **Configure Storage:**
   ```
   Root volume: 30 GB gp3 (general purpose SSD)
   ```

7. **Launch Instance**

### Step 1.2: Allocate Elastic IP

1. **Navigate to Elastic IPs:**
   - In EC2 Console sidebar: **Network & Security** → **Elastic IPs**

2. **Allocate New Address:**
   - Click **Allocate Elastic IP address**
   - Click **Allocate**

3. **Associate with Instance:**
   - Select the new Elastic IP
   - Click **Actions** → **Associate Elastic IP address**
   - Instance: Select `cyrus-production`
   - Click **Associate**

4. **Note the Elastic IP:**
   - Copy the IP address (e.g., `54.123.45.67`)
   - You'll use this for DNS configuration

### Step 1.3: Configure DNS

Point your domain to the Elastic IP:

1. **Go to your DNS provider** (Route 53, Cloudflare, etc.)

2. **Add A Record:**
   ```
   Type: A
   Name: cyrus (or your preferred subdomain)
   Value: 54.123.45.67 (your Elastic IP)
   TTL: 300 (5 minutes)
   ```

3. **Verify DNS propagation:**
   ```bash
   # On your local machine
   nslookup cyrus.yourdomain.com
   # Should return your Elastic IP
   ```

---

## Part 2: Server Setup

### Step 2.1: Connect to EC2 Instance

```bash
# SSH into your EC2 instance
ssh -i ~/.ssh/your-key.pem ubuntu@cyrus.yourdomain.com
```

### Step 2.2: Install Docker

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install Docker
sudo apt install -y docker.io docker-compose-v2

# Add ubuntu user to docker group
sudo usermod -aG docker ubuntu

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker

# Verify Docker installation
docker --version
docker compose version

# Log out and back in for group changes to take effect
exit
ssh -i ~/.ssh/your-key.pem ubuntu@cyrus.yourdomain.com
```

### Step 2.3: Install nginx and Certbot

```bash
# Install nginx and certbot for SSL
sudo apt install -y nginx certbot python3-certbot-nginx

# Verify nginx is running
sudo systemctl status nginx
```

### Step 2.4: Configure nginx Reverse Proxy

Create nginx configuration for Cyrus:

```bash
sudo nano /etc/nginx/sites-available/cyrus
```

Add this configuration:

```nginx
# Cyrus reverse proxy configuration
server {
    listen 80;
    server_name cyrus.yourdomain.com;

    # Allow Let's Encrypt verification
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Redirect all other traffic to HTTPS
    location / {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name cyrus.yourdomain.com;

    # SSL certificates (will be added by certbot)
    ssl_certificate /etc/letsencrypt/live/cyrus.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cyrus.yourdomain.com/privkey.pem;

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Logging
    access_log /var/log/nginx/cyrus_access.log;
    error_log /var/log/nginx/cyrus_error.log;

    # Proxy to Cyrus container
    location / {
        proxy_pass http://localhost:3456;
        proxy_http_version 1.1;

        # Headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeouts for long-running sessions
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;

        # Buffer settings
        proxy_buffering off;
        proxy_buffer_size 4k;
    }

    # Health check endpoint
    location /health {
        proxy_pass http://localhost:3456/health;
        access_log off;
    }
}
```

**Important:** Replace `cyrus.yourdomain.com` with your actual domain.

Enable the site:

```bash
# Enable the configuration
sudo ln -s /etc/nginx/sites-available/cyrus /etc/nginx/sites-enabled/

# Remove default site
sudo rm /etc/nginx/sites-enabled/default

# Test configuration
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx
```

### Step 2.5: Get SSL Certificate

```bash
# Request SSL certificate from Let's Encrypt
sudo certbot --nginx -d cyrus.yourdomain.com

# Follow the prompts:
# - Enter email address
# - Agree to terms of service
# - Choose to redirect HTTP to HTTPS (recommended)

# Verify SSL certificate
sudo certbot certificates

# Test auto-renewal
sudo certbot renew --dry-run
```

Your nginx reverse proxy with SSL is now configured!

---

## Part 3: Claude Code OAuth Token

Get your Claude Code OAuth token from your local machine.

### Option 1: Using claude setup-token

```bash
# On your LOCAL machine (where Claude Code is installed)
claude setup-token

# This will display your OAuth token
# Copy the entire token (starts with a long string)
```

### Option 2: Extract from config file

```bash
# On your LOCAL machine
cat ~/.config/claude/config.json

# Look for the "oauth" section:
{
  "oauth": {
    "access_token": "your-token-here",
    "refresh_token": "...",
    ...
  }
}

# Copy the "access_token" value
```

**Save this token** - you'll add it to `.env` in the next step.

---

## Part 4: Linear OAuth Application

Create a Linear OAuth application for Cyrus.

### Step 4.1: Create OAuth App

1. **Open Linear:**
   - Go to https://linear.app
   - Click workspace name → **Settings**

2. **Navigate to API:**
   - Sidebar: **Account** → **API**
   - Scroll to **OAuth Applications**

3. **Create Application:**
   - Click **Create new OAuth Application**
   - Fill in:
     ```
     Name: Cyrus
     Description: AI agent for automated development
     Callback URLs: https://cyrus.yourdomain.com/callback
     ```

4. **Enable Features:**
   - ✅ **Enable Client credentials**
   - ✅ **Enable Webhooks**

5. **Configure Webhooks:**
   - **Webhook URL:** `https://cyrus.yourdomain.com/webhook`
   - **App events:**
     - ✅ **Agent session events** (REQUIRED)
     - ✅ **Inbox notifications**
     - ✅ **Permission changes**

6. **Save and Copy Credentials:**
   - Click **Save**
   - Copy these values:
     - **Client ID**
     - **Client Secret** (shown only once!)
     - **Webhook Signing Secret**

---

## Part 5: Deploy Cyrus

### Step 5.1: Clone Repository

```bash
# On EC2 instance
cd ~
git clone https://github.com/ceedaragents/cyrus.git
cd cyrus
```

### Step 5.2: Configure Environment

```bash
# Copy the ticketlayer template
cp .env.ticketlayer.example .env

# Edit the file
nano .env
```

Fill in these values:

```bash
# Linear OAuth (from Part 4)
LINEAR_CLIENT_ID=client_id_xxx
LINEAR_CLIENT_SECRET=client_secret_xxx
LINEAR_WEBHOOK_SECRET=lin_whs_xxx

# Your domain
CYRUS_BASE_URL=https://cyrus.yourdomain.com

# Claude OAuth token (from Part 3)
CLAUDE_CODE_OAUTH_TOKEN=your-oauth-token-here

# Model preferences
CYRUS_DEFAULT_MODEL=opus
CYRUS_DEFAULT_FALLBACK_MODEL=sonnet

# Logging
CYRUS_LOG_LEVEL=info
```

Save and exit (Ctrl+O, Enter, Ctrl+X).

### Step 5.3: Build and Start Cyrus

```bash
# Build and start in detached mode
docker compose up -d --build

# View logs to verify startup
docker compose logs -f cyrus

# You should see:
# "Cyrus is starting..."
# "Listening on port 3456"
# "Waiting for configuration..."
```

Press Ctrl+C to exit log view.

---

## Part 6: GitHub Access Configuration

Configure SSH access for ticketlayer private repositories.

### Step 6.1: Generate SSH Key in Container

```bash
# Access container shell
docker compose exec cyrus bash

# Generate SSH key (inside container)
ssh-keygen -t ed25519 -C "cyrus@ticketlayer.com"

# Press Enter for default location
# Press Enter twice for no passphrase

# Display public key
cat ~/.ssh/id_ed25519.pub

# Copy the entire output (starts with "ssh-ed25519")
```

### Step 6.2: Add Deploy Key to GitHub Repositories

For **each** ticketlayer repository (backstage-api, backstage-app, etc.):

1. **Go to repository settings:**
   - Navigate to: `https://github.com/ticketlayer/REPO-NAME/settings/keys`

2. **Add deploy key:**
   - Click **Add deploy key**
   - Title: `Cyrus AI Agent`
   - Key: Paste the public key from above
   - ✅ **Allow write access** (required for commits and PRs)
   - Click **Add key**

**Alternative:** Use a GitHub account deploy key if you want access to all repos:
1. Go to: https://github.com/settings/keys
2. Click **New SSH key**
3. Title: `Cyrus AI Agent`
4. Paste the public key
5. Click **Add SSH key**

### Step 6.3: Configure Git

```bash
# Inside container (docker compose exec cyrus bash)
git config --global user.name "Cyrus AI"
git config --global user.email "cyrus@ticketlayer.com"

# Test GitHub connection
ssh -T git@github.com
# Should see: "Hi ticketlayer! You've successfully authenticated..."
```

### Step 6.4: Configure GitHub CLI for PR Creation

```bash
# Inside container
gh auth login

# Follow prompts:
# ? What account do you want to log into? GitHub.com
# ? What is your preferred protocol for Git operations? SSH
# ? Upload your SSH public key to your GitHub account? Skip
# ? How would you like to authenticate GitHub CLI? Login with a web browser

# Copy the one-time code shown
# Open the URL in your browser
# Paste the code and authorize

# Verify authentication
gh auth status
```

Exit the container:
```bash
exit
```

---

## Part 7: Initialize Cyrus

### Step 7.1: Authorize with Linear

```bash
# Start Linear OAuth flow
docker compose exec cyrus cyrus self-auth

# This will display a URL like:
# Open this URL in your browser:
# https://linear.app/oauth/authorize?client_id=...

# Copy the URL and open in your browser
# Click "Authorize" in Linear
# You should see: "Authorization successful!"
```

### Step 7.2: Add Ticketlayer Repositories

Add each repository you want Cyrus to manage:

```bash
# Add backstage-api
docker compose exec cyrus cyrus self-add-repo \
  git@github.com:ticketlayer/backstage-api.git \
  "Ticketlayer Workspace"

# Add backstage-app
docker compose exec cyrus cyrus self-add-repo \
  git@github.com:ticketlayer/backstage-app.git \
  "Ticketlayer Workspace"

# Add other repositories as needed
docker compose exec cyrus cyrus self-add-repo \
  git@github.com:ticketlayer/REPO-NAME.git \
  "Ticketlayer Workspace"
```

**Note:** Replace `"Ticketlayer Workspace"` with your actual Linear workspace name if different.

### Step 7.3: Verify Configuration

```bash
# Check token status
docker compose exec cyrus cyrus check-tokens

# View config file
docker compose exec cyrus cat /data/cyrus/config.json | jq .

# Should show your repositories with Linear tokens
```

---

## Part 8: Testing and Verification

### Step 8.1: Test Webhook Endpoint

```bash
# From your local machine
curl https://cyrus.yourdomain.com/health

# Should return: {"status":"ok"}
```

### Step 8.2: Create Test Issue in Linear

1. **Create a new Linear issue:**
   - Title: "Test Cyrus integration"
   - Description: "Please create a simple test file in the repo"
   - Team: One of your ticketlayer teams
   - Assign to: Cyrus (should appear as assignee after OAuth)

2. **Monitor Cyrus logs:**
   ```bash
   docker compose logs -f cyrus
   ```

3. **Watch for activity:**
   - Webhook received
   - Issue processing started
   - Claude session initiated
   - Git worktree created
   - Changes committed
   - PR created
   - Comment posted back to Linear

### Step 8.3: Verify Pull Request

1. **Check GitHub:**
   - Navigate to your ticketlayer repository
   - Look for a new PR from Cyrus
   - Review the changes

2. **Check Linear:**
   - Open the test issue
   - Should see Cyrus's comments with updates
   - Should see activity log of what Cyrus did

---

## Part 9: Configuration and Customization

### Step 9.1: Edit Repository Configuration

```bash
# Access the config file
docker compose exec cyrus nano /data/cyrus/config.json
```

Customize settings:

```json
{
  "repositories": [
    {
      "id": "...",
      "name": "backstage-api",
      "repositoryPath": "/data/cyrus/repos/backstage-api",

      // Tool permissions
      "allowedTools": [
        "Read(**)",
        "Edit(**)",
        "Bash(git:*)",
        "Bash(gh:*)",
        "Bash(npm:*)",
        "Task",
        "WebSearch"
      ],

      // Team-based routing
      "teamKeys": ["BACKEND", "API"],

      // Label-based AI modes
      "labelPrompts": {
        "debugger": {
          "labels": ["Bug", "Hotfix"],
          "allowedTools": "all"
        },
        "builder": {
          "labels": ["Feature", "Enhancement"],
          "allowedTools": "safe"
        },
        "scoper": {
          "labels": ["RFC", "Design"],
          "allowedTools": "readOnly"
        }
      }
    }
  ]
}
```

Save changes - Cyrus will auto-reload the config (no restart needed).

For full configuration options, see [CONFIG_FILE.md](./CONFIG_FILE.md).

### Step 9.2: Set Up Monitoring

Create a systemd service for auto-start on reboot:

```bash
sudo nano /etc/systemd/system/cyrus.service
```

Add:

```ini
[Unit]
Description=Cyrus AI Agent
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/ubuntu/cyrus
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
User=ubuntu

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl enable cyrus
sudo systemctl start cyrus
sudo systemctl status cyrus
```

### Step 9.3: Set Up Log Rotation

```bash
sudo nano /etc/logrotate.d/cyrus
```

Add:

```
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

### Step 9.4: Set Up Backups

Create backup script:

```bash
nano ~/backup-cyrus.sh
```

Add:

```bash
#!/bin/bash
BACKUP_DIR="/home/ubuntu/cyrus-backups"
DATE=$(date +%Y%m%d-%H%M%S)

mkdir -p "$BACKUP_DIR"

# Backup config and data
docker run --rm \
  -v cyrus-data:/data \
  -v "$BACKUP_DIR":/backup \
  alpine tar czf "/backup/cyrus-$DATE.tar.gz" /data

# Keep only last 7 backups
cd "$BACKUP_DIR"
ls -t | tail -n +8 | xargs -r rm

echo "Backup completed: cyrus-$DATE.tar.gz"
```

Make executable and add to cron:

```bash
chmod +x ~/backup-cyrus.sh
crontab -e
```

Add daily backup at 2 AM:

```
0 2 * * * /home/ubuntu/backup-cyrus.sh >> /home/ubuntu/backup.log 2>&1
```

---

## Part 10: Production Hardening

### Step 10.1: Enable UFW Firewall

```bash
# Enable UFW
sudo ufw enable

# Allow SSH, HTTP, HTTPS
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Deny direct access to Cyrus port
sudo ufw deny 3456/tcp

# Check status
sudo ufw status
```

### Step 10.2: Set Up CloudWatch Monitoring (Optional)

Install CloudWatch agent:

```bash
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i amazon-cloudwatch-agent.deb

# Configure CloudWatch agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-config-wizard
```

### Step 10.3: Enable Automatic Security Updates

```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

---

## Troubleshooting

### Webhook Not Received

```bash
# Check nginx logs
sudo tail -f /var/log/nginx/cyrus_error.log

# Check Cyrus logs
docker compose logs -f cyrus

# Test webhook endpoint
curl -X POST https://cyrus.yourdomain.com/webhook \
  -H "Content-Type: application/json" \
  -d '{"test": true}'
```

### SSL Certificate Issues

```bash
# Check certificate status
sudo certbot certificates

# Renew manually
sudo certbot renew --force-renewal

# Check nginx config
sudo nginx -t
```

### GitHub Authentication Failed

```bash
# Test SSH connection
docker compose exec cyrus ssh -T git@github.com

# Check SSH key
docker compose exec cyrus cat ~/.ssh/id_ed25519.pub

# Verify deploy keys in GitHub
# Check: https://github.com/ticketlayer/REPO/settings/keys
```

### Container Won't Start

```bash
# Check Docker logs
docker compose logs cyrus

# Verify environment variables
docker compose config

# Check disk space
df -h

# Restart Docker
sudo systemctl restart docker
docker compose up -d
```

### Linear Authorization Failed

```bash
# Verify credentials
cat .env | grep LINEAR

# Check Linear OAuth app settings
# Ensure callback URL matches CYRUS_BASE_URL

# Try authorization again
docker compose exec cyrus cyrus self-auth
```

---

## Maintenance

### Updating Cyrus

```bash
# Pull latest changes
cd ~/cyrus
git pull

# Rebuild and restart
docker compose down
docker compose up -d --build

# Verify
docker compose logs -f cyrus
```

### Viewing Logs

```bash
# Real-time logs
docker compose logs -f cyrus

# Last 100 lines
docker compose logs --tail=100 cyrus

# Logs from specific time
docker compose logs --since 1h cyrus
```

### Restarting Cyrus

```bash
# Restart container
docker compose restart cyrus

# Full restart
docker compose down && docker compose up -d
```

---

## Next Steps

✅ Cyrus is now running and monitoring your ticketlayer repositories!

**What to do next:**

1. **Create workflow labels in Linear:**
   - Add labels: "Bug", "Feature", "RFC"
   - Configure label-based routing in config.json

2. **Test with real issues:**
   - Create a bug fix issue
   - Create a feature request
   - Watch Cyrus process and create PRs

3. **Set up team routing:**
   - Configure `teamKeys` in config.json
   - Route different teams to appropriate repos

4. **Monitor performance:**
   - Check CloudWatch metrics
   - Review Cyrus logs regularly
   - Monitor GitHub PR quality

5. **Scale as needed:**
   - Add more repositories
   - Adjust EC2 instance size
   - Configure resource limits

---

## Support

- **Documentation:** [docs/](../docs/)
- **GitHub Issues:** https://github.com/ceedaragents/cyrus/issues
- **Discord:** https://discord.gg/prrtADHYTt

---

**Deployment complete!** 🎉

Your Cyrus instance is now running on AWS, connected to your ticketlayer GitHub organization and Linear workspace.
