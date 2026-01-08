# Docker Deployment Guide

This guide explains how to deploy Cyrus in a Docker container for cloud or self-hosted environments. Docker provides consistent, portable deployment across different platforms and cloud providers.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Detailed Setup](#detailed-setup)
  - [1. Linear OAuth Application](#1-linear-oauth-application)
  - [2. Public URL Setup](#2-public-url-setup)
  - [3. Environment Configuration](#3-environment-configuration)
  - [4. Build and Run](#4-build-and-run)
  - [5. Initial Authorization](#5-initial-authorization)
  - [6. Git & GitHub Configuration](#6-git--github-configuration)
- [Cloud Deployment](#cloud-deployment)
- [Production Best Practices](#production-best-practices)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before deploying, ensure you have:

- **Docker** (20.10+) and **Docker Compose** (2.0+) installed
- **Linear workspace** with admin access
- **Claude Code API key** or OAuth token
- **Public URL** for webhooks (Cloudflare Tunnel, ngrok, or public server)
- **GitHub organization** repositories you want to automate

---

## Quick Start

For experienced users familiar with Linear OAuth and Docker:

```bash
# 1. Clone the repository
git clone https://github.com/ceedaragents/cyrus.git
cd cyrus

# 2. Configure environment
cp .env.example .env
# Edit .env with your values (see below)

# 3. Build and start
docker-compose up -d

# 4. Authorize with Linear
docker-compose exec cyrus cyrus self-auth

# 5. Add a repository
docker-compose exec cyrus cyrus self-add-repo https://github.com/yourorg/yourrepo.git "Your Workspace"

# 6. View logs
docker-compose logs -f cyrus
```

---

## Detailed Setup

### 1. Linear OAuth Application

Create a Linear OAuth application to receive webhooks and authorize with your workspace.

**Steps:**

1. **Open Linear Settings:**
   - Go to https://linear.app
   - Click your workspace name → **Settings**
   - Navigate to **Account** → **API** → **OAuth Applications**

2. **Create New Application:**
   - Click **Create new OAuth Application**
   - Fill in the form:
     ```
     Name: Cyrus
     Description: Self-hosted Cyrus AI agent
     Callback URLs: https://your-public-url.com/callback
     ```

3. **Enable Required Features:**
   - ✅ **Enable Client credentials**
   - ✅ **Enable Webhooks**
   - **Webhook URL:** `https://your-public-url.com/webhook`
   - **App events:** Check these boxes:
     - ✅ **Agent session events** (REQUIRED)
     - ✅ **Inbox notifications** (recommended)
     - ✅ **Permission changes** (recommended)

4. **Save and Copy Credentials:**
   - Click **Save**
   - Copy these values:
     - **Client ID** (e.g., `client_id_abc123...`)
     - **Client Secret** (shown once - save it!)
     - **Webhook Signing Secret** (in webhook settings)

For detailed instructions with screenshots, see [Self-Hosting Guide](./SELF_HOSTING.md#step-3-create-linear-oauth-application).

---

### 2. Public URL Setup

Cyrus needs a public URL to receive Linear webhooks and handle OAuth callbacks. Choose one option:

#### Option A: Cloudflare Tunnel (Recommended)

**Advantages:** Free, persistent URL, works behind firewalls, automatic HTTPS

1. **Create Cloudflare Account:**
   - Go to https://cloudflare.com and sign up (free tier)
   - Add your domain to Cloudflare

2. **Create Tunnel:**
   - Go to https://one.dash.cloudflare.com/
   - Navigate to **Access** → **Tunnels**
   - Click **Create a tunnel**
   - Name: `cyrus`
   - Copy the tunnel token (starts with `eyJ...`)

3. **Configure Public Hostname:**
   - Add public hostname: `cyrus.yourdomain.com`
   - Type: **HTTP**
   - URL: `localhost:3456`

4. **Add to Environment:**
   ```bash
   CYRUS_BASE_URL=https://cyrus.yourdomain.com
   CLOUDFLARE_TOKEN=eyJ...your_token_here
   ```

See [Cloudflare Tunnel Setup](./CLOUDFLARE_TUNNEL.md) for detailed instructions.

#### Option B: ngrok (Development/Testing)

**Advantages:** Quick setup, no domain needed
**Disadvantages:** URL changes on restart (unless paid plan)

```bash
# Install ngrok
brew install ngrok  # macOS
# or download from https://ngrok.com/download

# Start tunnel
ngrok http 3456

# Copy the HTTPS URL (e.g., https://abc123.ngrok.io)
# Add to .env:
CYRUS_BASE_URL=https://abc123.ngrok.io
```

#### Option C: Public Server/VPS

**Advantages:** Full control, permanent URL
**Requirements:** Server with public IP, domain, reverse proxy

```nginx
# Nginx reverse proxy example
server {
    listen 443 ssl http2;
    server_name cyrus.yourdomain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://localhost:3456;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

### 3. Environment Configuration

Configure Cyrus using environment variables in the `.env` file.

1. **Copy the example:**
   ```bash
   cp .env.example .env
   ```

2. **Edit .env with your values:**

   ```bash
   # REQUIRED: Linear OAuth
   LINEAR_DIRECT_WEBHOOKS=true
   LINEAR_CLIENT_ID=your_linear_client_id
   LINEAR_CLIENT_SECRET=your_linear_client_secret
   LINEAR_WEBHOOK_SECRET=your_linear_webhook_secret

   # REQUIRED: Public URL
   CYRUS_BASE_URL=https://your-public-url.com
   CYRUS_SERVER_PORT=3456

   # REQUIRED: Claude Code (choose one)
   ANTHROPIC_API_KEY=sk-ant-your-api-key
   # OR
   # CLAUDE_CODE_OAUTH_TOKEN=your-oauth-token

   # OPTIONAL: Cloudflare Tunnel
   # CLOUDFLARE_TOKEN=eyJ...your_cloudflare_token

   # OPTIONAL: Model preferences
   # CYRUS_DEFAULT_MODEL=opus
   # CYRUS_DEFAULT_FALLBACK_MODEL=sonnet

   # OPTIONAL: OpenAI (for Sora/DALL-E)
   # OPENAI_API_KEY=sk-your-openai-key

   # OPTIONAL: Logging
   # CYRUS_LOG_LEVEL=info
   ```

3. **Verify configuration:**
   ```bash
   # Check for required variables
   grep -E "LINEAR_CLIENT_ID|CYRUS_BASE_URL|ANTHROPIC_API_KEY" .env
   ```

**Security Note:** Never commit `.env` to version control. The `.gitignore` already excludes it.

---

### 4. Build and Run

Build the Docker image and start Cyrus:

#### Using Docker Compose (Recommended)

```bash
# Build and start in detached mode
docker-compose up -d --build

# View logs
docker-compose logs -f cyrus

# Stop Cyrus
docker-compose down

# Restart Cyrus
docker-compose restart cyrus
```

#### Using Docker CLI

```bash
# Build image
docker build -t cyrus:latest .

# Run container
docker run -d \
  --name cyrus \
  --env-file .env \
  -p 3456:3456 \
  -v cyrus-data:/data/cyrus \
  --restart unless-stopped \
  cyrus:latest

# View logs
docker logs -f cyrus

# Stop and remove
docker stop cyrus && docker rm cyrus
```

---

### 5. Initial Authorization

After starting Cyrus, authorize it with Linear and add repositories.

#### Authorize with Linear

```bash
# Start the OAuth flow
docker-compose exec cyrus cyrus self-auth

# This will:
# 1. Display an authorization URL
# 2. Open your browser (if possible)
# 3. After you authorize in Linear, save the tokens
```

**If running headless (no browser):**

The command will display a URL like:
```
Open this URL in your browser:
https://linear.app/oauth/authorize?client_id=...
```

Copy and paste this URL into a browser on another machine, complete authorization, and the callback will save tokens automatically.

#### Add Repositories

```bash
# Add a repository
docker-compose exec cyrus cyrus self-add-repo \
  https://github.com/yourorg/yourrepo.git \
  "Your Workspace Name"

# The repository will be cloned to /data/cyrus/repos/yourrepo
# Configuration is saved to /data/cyrus/config.json
```

#### Verify Setup

```bash
# Check token status
docker-compose exec cyrus cyrus check-tokens

# View configuration
docker-compose exec cyrus cat /data/cyrus/config.json
```

---

### 6. Git & GitHub Configuration

For Cyrus to create commits and pull requests, configure Git and GitHub CLI authentication.

#### Option A: Mount Your SSH Keys and GitHub Config

**Best for:** Local development, single-user deployments

1. **Edit docker-compose.yml:**

   Uncomment these volume mounts:
   ```yaml
   volumes:
     - cyrus-data:/data/cyrus
     - ~/.ssh:/home/cyrus/.ssh:ro
     - ~/.config/gh:/home/cyrus/.config/gh:ro
   ```

2. **Ensure SSH keys have correct permissions:**
   ```bash
   chmod 600 ~/.ssh/id_ed25519
   chmod 644 ~/.ssh/id_ed25519.pub
   ```

3. **Authenticate GitHub CLI on host:**
   ```bash
   gh auth login
   ```

4. **Restart container:**
   ```bash
   docker-compose restart cyrus
   ```

#### Option B: Configure Inside Container

**Best for:** Multi-user, production deployments

1. **Generate SSH key inside container:**
   ```bash
   docker-compose exec cyrus bash

   # Inside container:
   ssh-keygen -t ed25519 -C "cyrus@example.com"
   cat ~/.ssh/id_ed25519.pub
   # Copy and add to GitHub: https://github.com/settings/keys
   ```

2. **Configure Git:**
   ```bash
   docker-compose exec cyrus bash

   # Inside container:
   git config --global user.name "Cyrus AI"
   git config --global user.email "cyrus@example.com"
   ```

3. **Authenticate GitHub CLI:**
   ```bash
   docker-compose exec cyrus bash

   # Inside container:
   gh auth login --with-token < /path/to/token.txt
   # Or interactively:
   gh auth login
   ```

4. **Verify setup:**
   ```bash
   docker-compose exec cyrus gh auth status
   docker-compose exec cyrus git config --global user.name
   ```

For detailed instructions, see [Git & GitHub Setup](./GIT_GITHUB.md).

---

## Cloud Deployment

### AWS EC2

```bash
# 1. Launch EC2 instance (Ubuntu 22.04, t3.medium recommended)
# 2. Install Docker
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker ubuntu

# 3. Clone and configure
git clone https://github.com/ceedaragents/cyrus.git
cd cyrus
cp .env.example .env
# Edit .env with your values

# 4. Set up public URL (use Elastic IP or Cloudflare Tunnel)
# 5. Run Cyrus
docker compose up -d

# 6. Set up log rotation
sudo nano /etc/logrotate.d/cyrus
```

### Google Cloud Run

```bash
# 1. Build and push to Container Registry
gcloud builds submit --tag gcr.io/YOUR_PROJECT/cyrus

# 2. Deploy to Cloud Run
gcloud run deploy cyrus \
  --image gcr.io/YOUR_PROJECT/cyrus \
  --platform managed \
  --region us-central1 \
  --allow-unauthenticated \
  --set-env-vars-file .env

# 3. Configure Custom Domain for webhooks
```

### DigitalOcean Droplet

```bash
# 1. Create Droplet (Docker marketplace image)
# 2. SSH into droplet
ssh root@your-droplet-ip

# 3. Clone and configure
git clone https://github.com/ceedaragents/cyrus.git
cd cyrus
cp .env.example .env
# Edit .env

# 4. Run with Docker Compose
docker-compose up -d

# 5. Configure firewall
ufw allow 3456/tcp
ufw enable
```

### Azure Container Instances

```bash
# 1. Create resource group
az group create --name cyrus-rg --location eastus

# 2. Build and push to ACR
az acr build --registry yourregistry --image cyrus:latest .

# 3. Deploy to ACI
az container create \
  --resource-group cyrus-rg \
  --name cyrus \
  --image yourregistry.azurecr.io/cyrus:latest \
  --dns-name-label cyrus-yourorg \
  --ports 3456 \
  --environment-variables-file .env
```

---

## Production Best Practices

### 1. Persistent Storage

**Use external volumes for production:**

```yaml
# docker-compose.yml
volumes:
  cyrus-data:
    driver: local
    driver_opts:
      type: none
      device: /mnt/cyrus-storage
      o: bind
```

### 2. Secrets Management

**Use Docker secrets or cloud provider secrets:**

```yaml
# docker-compose.yml (with Docker Swarm)
services:
  cyrus:
    secrets:
      - linear_client_secret
      - anthropic_api_key

secrets:
  linear_client_secret:
    external: true
  anthropic_api_key:
    external: true
```

Or use environment variable files:

```bash
# Store secrets separately
docker-compose --env-file .env.production up -d
```

### 3. Monitoring and Logging

**Configure structured logging:**

```yaml
# docker-compose.yml
services:
  cyrus:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
        labels: "service=cyrus"
```

**Integrate with log aggregation:**

```bash
# Ship logs to CloudWatch, Datadog, etc.
docker-compose logs -f | your-log-shipper
```

### 4. Health Checks and Auto-Restart

```yaml
# docker-compose.yml
services:
  cyrus:
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3456/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

### 5. Resource Limits

```yaml
# docker-compose.yml
services:
  cyrus:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G
        reservations:
          cpus: '1'
          memory: 2G
```

### 6. Backup Strategy

```bash
# Backup config and repository data
docker run --rm \
  -v cyrus-data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/cyrus-backup-$(date +%Y%m%d).tar.gz /data

# Restore from backup
docker run --rm \
  -v cyrus-data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar xzf /backup/cyrus-backup-20240115.tar.gz -C /
```

### 7. Security Hardening

```dockerfile
# Dockerfile improvements:
# - Non-root user (already implemented)
# - Read-only root filesystem
# - Drop capabilities

# docker-compose.yml
services:
  cyrus:
    user: "1000:1000"
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    tmpfs:
      - /tmp
```

### 8. SSL/TLS Termination

Use a reverse proxy for SSL termination:

```yaml
# docker-compose.yml with Traefik
services:
  cyrus:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.cyrus.rule=Host(`cyrus.example.com`)"
      - "traefik.http.routers.cyrus.tls.certresolver=letsencrypt"

  traefik:
    image: traefik:v2.10
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml
```

---

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker-compose logs cyrus

# Common issues:
# 1. Missing required environment variables
docker-compose config

# 2. Port already in use
sudo lsof -i :3456

# 3. Volume permission issues
docker-compose exec cyrus ls -la /data/cyrus
```

### OAuth Authorization Fails

```bash
# 1. Verify CYRUS_BASE_URL matches Linear OAuth callback
echo $CYRUS_BASE_URL
# Should match: https://linear.app/settings/api

# 2. Check that public URL is accessible
curl https://your-public-url.com/health

# 3. Verify Linear credentials
docker-compose exec cyrus env | grep LINEAR
```

### Webhooks Not Received

```bash
# 1. Check webhook URL in Linear
# Settings > API > OAuth Applications > Your App > Webhook URL
# Should be: https://your-public-url.com/webhook

# 2. Verify Cyrus is listening
docker-compose exec cyrus netstat -tlnp | grep 3456

# 3. Test webhook endpoint
curl -X POST https://your-public-url.com/webhook \
  -H "Content-Type: application/json" \
  -d '{"test": true}'
```

### Git/GitHub Authentication Issues

```bash
# 1. Verify SSH keys
docker-compose exec cyrus ls -la ~/.ssh/

# 2. Test SSH connection
docker-compose exec cyrus ssh -T git@github.com

# 3. Check GitHub CLI auth
docker-compose exec cyrus gh auth status

# 4. Verify git config
docker-compose exec cyrus git config --global --list
```

### Claude Code Execution Fails

```bash
# 1. Verify Claude authentication
docker-compose exec cyrus env | grep ANTHROPIC

# 2. Check jq is installed
docker-compose exec cyrus which jq

# 3. Test Claude Code manually
docker-compose exec cyrus bash
# Inside container:
echo "test" | claude
```

### High Memory Usage

```bash
# 1. Monitor container stats
docker stats cyrus

# 2. Check worktree disk usage
docker-compose exec cyrus du -sh /data/cyrus/worktrees/*

# 3. Clean up old worktrees
# Configure repository cleanup in config.json

# 4. Set memory limits
# See: Production Best Practices > Resource Limits
```

### Logs Not Appearing

```bash
# 1. Check log level
docker-compose exec cyrus env | grep LOG_LEVEL

# 2. View real-time logs
docker-compose logs -f --tail=100 cyrus

# 3. Check log driver
docker inspect cyrus | grep LogConfig
```

### Configuration Not Updating

```bash
# 1. Verify config file syntax
docker-compose exec cyrus cat /data/cyrus/config.json | jq .

# 2. Watch for file changes (Cyrus auto-reloads)
docker-compose logs -f | grep "Configuration updated"

# 3. Manually restart if needed
docker-compose restart cyrus
```

---

## Next Steps

After successful deployment:

1. **Test the setup:**
   - Assign a Linear issue to Cyrus
   - Monitor logs: `docker-compose logs -f cyrus`
   - Verify issue is processed and PR created

2. **Configure repositories:**
   - Edit `/data/cyrus/config.json`
   - Set tool permissions, routing labels, AI modes
   - See [Configuration Reference](./CONFIG_FILE.md)

3. **Set up monitoring:**
   - Configure health checks
   - Set up log aggregation
   - Create alerts for failures

4. **Scale as needed:**
   - Add more repositories
   - Adjust resource limits
   - Implement backup strategy

---

## Support

For issues or questions:

- **Documentation:** [docs/](../docs/)
- **GitHub Issues:** https://github.com/ceedaragents/cyrus/issues
- **Discord:** https://discord.gg/prrtADHYTt

---

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](../LICENSE).
