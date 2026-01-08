# Cyrus AI - Production Docker Image
# This Dockerfile builds a production-ready container for Cyrus
# Supports both self-hosted and cloud deployments

FROM node:20-alpine AS base

# Install system dependencies
# - git: Required for repository operations and worktrees
# - jq: Required for Claude Code output parsing
# - openssh-client: Required for Git SSH authentication
# - github-cli (gh): Optional but recommended for PR creation
RUN apk add --no-cache \
    git \
    jq \
    openssh-client \
    bash \
    curl

# Install GitHub CLI (optional - comment out if not creating PRs)
RUN apk add --no-cache github-cli

# Set working directory
WORKDIR /app

# Copy package files
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/cli/package.json ./apps/cli/
COPY packages/*/package.json ./packages/*/

# Install pnpm
RUN npm install -g pnpm@10.13.1

# Install dependencies
RUN pnpm install --frozen-lockfile --prod=false

# Copy source code
COPY . .

# Build all packages
RUN pnpm build

# Create cyrus user for security (non-root)
RUN addgroup -g 1000 cyrus && \
    adduser -D -u 1000 -G cyrus cyrus

# Create data directories
RUN mkdir -p /data/cyrus && \
    chown -R cyrus:cyrus /data/cyrus

# Create directories for Git/GitHub config
RUN mkdir -p /home/cyrus/.ssh && \
    mkdir -p /home/cyrus/.config/gh && \
    chown -R cyrus:cyrus /home/cyrus

# Switch to cyrus user
USER cyrus

# Set environment variables
ENV NODE_ENV=production
ENV CYRUS_HOME=/data/cyrus
ENV HOME=/home/cyrus

# Expose default port (can be overridden)
EXPOSE 3456

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:${CYRUS_SERVER_PORT:-3456}/health || exit 1

# Default command - starts Cyrus
CMD ["node", "/app/apps/cli/dist/src/app.js"]
