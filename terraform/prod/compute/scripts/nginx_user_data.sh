#!/bin/bash
set -e

# -----------------------------------------------------------------------------
# User Data Script for Nginx Reverse Proxy (Ubuntu 22.04 ARM64)
# Project: ${project_name}
# Environment: ${environment}
# Domain: ${domain}
# -----------------------------------------------------------------------------

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting nginx user data script ==="

export DEBIAN_FRONTEND=noninteractive

# Lock cleanup
killall apt apt-get 2>/dev/null || true
rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock

# -----------------------------------------------------------------------------
# System Update
# -----------------------------------------------------------------------------
echo "=== Updating system packages ==="
apt-get update
apt-get upgrade -y

# -----------------------------------------------------------------------------
# Install Nginx
# -----------------------------------------------------------------------------
echo "=== Installing Nginx ==="
apt-get install -y nginx

# -----------------------------------------------------------------------------
# Install AWS CLI v2 (aarch64)
# -----------------------------------------------------------------------------
echo "=== Installing AWS CLI v2 (aarch64) ==="
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
apt-get install -y unzip
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# -----------------------------------------------------------------------------
# SSM Agent
# -----------------------------------------------------------------------------
echo "=== Ensuring SSM Agent is running ==="
snap install amazon-ssm-agent --classic 2>/dev/null || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

# -----------------------------------------------------------------------------
# Useful tools
# -----------------------------------------------------------------------------
apt-get install -y htop vim curl wget jq net-tools tree

# -----------------------------------------------------------------------------
# Timezone
# -----------------------------------------------------------------------------
timedatectl set-timezone Asia/Seoul

# -----------------------------------------------------------------------------
# Nginx Configuration (base64 decoded to avoid $ escaping issues)
# -----------------------------------------------------------------------------
echo "=== Deploying Nginx configuration ==="

echo '${nginx_conf_b64}' | base64 -d > /etc/nginx/nginx.conf
echo '${upstream_conf_b64}' | base64 -d > /etc/nginx/conf.d/upstream.conf
echo '${security_conf_b64}' | base64 -d > /etc/nginx/conf.d/security.conf
echo '${metrics_conf_b64}' | base64 -d > /etc/nginx/conf.d/metrics.conf

rm -f /etc/nginx/conf.d/default.conf

echo '${site_conf_b64}' | base64 -d > /etc/nginx/sites-available/default
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# -----------------------------------------------------------------------------
# Certbot / Let's Encrypt
# -----------------------------------------------------------------------------
echo "=== Setting up Certbot ==="
apt-get install -y certbot python3-certbot-nginx
mkdir -p /var/www/certbot

if [ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
    echo "=== SSL cert not found — bootstrapping with HTTP-only config ==="
    cat > /etc/nginx/sites-available/certbot-bootstrap << 'BOOTSTRAP'
server {
    listen 80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 "Waiting for SSL setup";
        add_header Content-Type text/plain;
    }
}
BOOTSTRAP
    ln -sf /etc/nginx/sites-available/certbot-bootstrap /etc/nginx/sites-enabled/default
    nginx -t && systemctl start nginx

    certbot certonly --webroot -w /var/www/certbot \
        -d ${domain} \
        --non-interactive --agree-tos --email admin@${domain} \
        --deploy-hook "nginx -s reload"

    # Restore full config
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    nginx -t && nginx -s reload
else
    echo "=== SSL cert found — starting Nginx ==="
    nginx -t && systemctl start nginx
fi

systemctl enable nginx
systemctl enable certbot.timer
systemctl start certbot.timer

# -----------------------------------------------------------------------------
# ECR login helper
# -----------------------------------------------------------------------------
cat > /home/ubuntu/ecr-login.sh << 'ECREOF'
#!/bin/bash
REGION=$(TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && \
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
ECREOF
chmod +x /home/ubuntu/ecr-login.sh
chown ubuntu:ubuntu /home/ubuntu/ecr-login.sh

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo "==========================================="
echo "   Installation Verification"
echo "==========================================="
echo "Nginx: $(nginx -v 2>&1)"
echo "AWS CLI: $(aws --version)"
echo "SSM Agent: $(systemctl is-active snap.amazon-ssm-agent.amazon-ssm-agent.service)"
echo "Certbot: $(certbot --version 2>&1)"
echo "=== Nginx user data script completed ==="