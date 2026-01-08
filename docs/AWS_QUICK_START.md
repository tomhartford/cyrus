# AWS Quick Start - Ticketlayer Deployment

Fast-track deployment guide for ticketlayer on AWS. For detailed instructions, see [TICKETLAYER_DEPLOYMENT.md](./TICKETLAYER_DEPLOYMENT.md).

---

## Prerequisites

- [ ] AWS account
- [ ] Domain name (for cyrus.yourdomain.com)
- [ ] Linear admin access
- [ ] GitHub access to ticketlayer org
- [ ] Claude Code OAuth token
- [ ] SSH key for AWS

---

## Part 1: AWS Setup (15 min)

### Launch EC2

```bash
# Instance: Ubuntu 22.04, t3.medium, 30GB storage
# Security Group: Allow 22, 80, 443
# Allocate and associate Elastic IP
# Configure DNS: A record → cyrus.yourdomain.com → Elastic IP
```

### Connect and Install

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@cyrus.yourdomain.com

# Install Docker
sudo apt update && sudo apt install -y docker.io docker-compose-v2 nginx certbot python3-certbot-nginx
sudo usermod -aG docker ubuntu
exit && ssh -i ~/.ssh/your-key.pem ubuntu@cyrus.yourdomain.com
```

---

## Part 2: nginx + SSL (10 min)

### Configure nginx

```bash
sudo nano /etc/nginx/sites-available/cyrus
```

**Paste this** (replace `cyrus.yourdomain.com`):

```nginx
server {
    listen 80;
    server_name cyrus.yourdomain.com;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$server_name$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name cyrus.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/cyrus.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cyrus.yourdomain.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://localhost:3456;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }
}
```

**Enable and get SSL:**

```bash
sudo ln -s /etc/nginx/sites-available/cyrus /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d cyrus.yourdomain.com
```

---

## Part 3: Linear OAuth (5 min)

1. Go to https://linear.app → Settings → API → OAuth Applications
2. Create new app:
   - Name: `Cyrus`
   - Callback: `https://cyrus.yourdomain.com/callback`
   - ✅ Client credentials
   - ✅ Webhooks → `https://cyrus.yourdomain.com/webhook`
   - ✅ Agent session events
3. **Copy:** Client ID, Client Secret, Webhook Secret

---

## Part 4: Claude OAuth Token (2 min)

**On your local machine** (where Claude Code is installed):

```bash
claude setup-token
# Copy the displayed token
```

---

## Part 5: Deploy Cyrus (5 min)

```bash
cd ~
git clone https://github.com/ceedaragents/cyrus.git
cd cyrus
cp .env.ticketlayer.example .env
nano .env
```

**Fill in:**
```bash
LINEAR_CLIENT_ID=xxx
LINEAR_CLIENT_SECRET=xxx
LINEAR_WEBHOOK_SECRET=xxx
CYRUS_BASE_URL=https://cyrus.yourdomain.com
CLAUDE_CODE_OAUTH_TOKEN=xxx
```

**Start:**
```bash
docker compose up -d --build
docker compose logs -f
```

---

## Part 6: GitHub Setup (5 min)

```bash
# Generate SSH key
docker compose exec cyrus ssh-keygen -t ed25519 -C "cyrus@ticketlayer.com"
docker compose exec cyrus cat ~/.ssh/id_ed25519.pub

# Add to GitHub:
# Go to: https://github.com/settings/keys
# Or: https://github.com/ticketlayer/REPO/settings/keys (per repo)
# Paste key, ✅ Allow write access

# Configure Git
docker compose exec cyrus git config --global user.name "Cyrus AI"
docker compose exec cyrus git config --global user.email "cyrus@ticketlayer.com"

# Configure GitHub CLI
docker compose exec cyrus gh auth login
# Follow prompts, use SSH protocol
```

---

## Part 7: Initialize (5 min)

```bash
# Authorize Linear
docker compose exec cyrus cyrus self-auth
# Open URL in browser, click Authorize

# Add repositories
docker compose exec cyrus cyrus self-add-repo \
  git@github.com:ticketlayer/backstage-api.git "Ticketlayer Workspace"

docker compose exec cyrus cyrus self-add-repo \
  git@github.com:ticketlayer/backstage-app.git "Ticketlayer Workspace"

# Verify
docker compose exec cyrus cyrus check-tokens
```

---

## Part 8: Test (2 min)

1. Create Linear issue in ticketlayer team
2. Assign to Cyrus
3. Watch logs: `docker compose logs -f cyrus`
4. Check GitHub for PR
5. Check Linear for updates

---

## Done! 🎉

Total time: ~45 minutes

**Common Commands:**

```bash
# View logs
docker compose logs -f cyrus

# Restart
docker compose restart cyrus

# Add repo
docker compose exec cyrus cyrus self-add-repo git@github.com:ticketlayer/REPO.git "Workspace"

# Check status
docker compose exec cyrus cyrus check-tokens

# Edit config
docker compose exec cyrus nano /data/cyrus/config.json
```

**Troubleshooting:**

- Webhooks not working? Check nginx logs: `sudo tail -f /var/log/nginx/cyrus_error.log`
- Can't connect to GitHub? Test SSH: `docker compose exec cyrus ssh -T git@github.com`
- Linear auth fails? Verify callback URL matches `CYRUS_BASE_URL`

**Full Guide:** [TICKETLAYER_DEPLOYMENT.md](./TICKETLAYER_DEPLOYMENT.md)
