#!/bin/sh
set -eu

# One-shot bootstrap for a fresh Proxmox VM (Ubuntu Server LTS).
#
# Idempotent: re-running on an already-set-up host is safe — every
# step checks before installing/cloning.
#
# Assumptions:
#   - Run as a user with passwordless sudo.
#   - The host has outbound internet and a Cloudflare Tunnel token in
#     the operator's hands (passed via stdin or env, never on the
#     command line).
#
# Usage:
#   curl -fsSL ... | sh   (not recommended — read it first)
#   ./infra/deploy/setup-vm.sh

REPO_URL="${REPO_URL:-https://github.com/petronijus/kulturniprehled.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/kp}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"

step() { printf '\n=== %s ===\n' "$*"; }

# ---- 1. user + groups ----
step "ensuring '${DEPLOY_USER}' user exists"
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    sudo useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi

# ---- 2. docker ----
step "installing Docker + compose plugin"
if ! command -v docker >/dev/null 2>&1; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi
sudo usermod -aG docker "$DEPLOY_USER"

# ---- 3. repo ----
step "cloning repo into ${INSTALL_DIR}"
if [ ! -d "$INSTALL_DIR/.git" ]; then
    sudo mkdir -p "$INSTALL_DIR"
    sudo chown "$DEPLOY_USER:$DEPLOY_USER" "$INSTALL_DIR"
    sudo -u "$DEPLOY_USER" git clone "$REPO_URL" "$INSTALL_DIR"
else
    sudo -u "$DEPLOY_USER" git -C "$INSTALL_DIR" pull --ff-only
fi

# ---- 4. .env scaffold ----
step "scaffolding .env (operator must fill it in)"
if [ ! -f "$INSTALL_DIR/.env" ]; then
    sudo -u "$DEPLOY_USER" cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    sudo chmod 600 "$INSTALL_DIR/.env"
    echo
    echo "* edit $INSTALL_DIR/.env before bringing the stack up:"
    echo "    - POSTGRES_PASSWORD, MINIO_*, API_JWT_SECRET"
    echo "    - GOOGLE_OAUTH_CLIENT_ID + SECRET"
    echo "    - ANTHROPIC_API_KEY"
    echo "    - ALLOWED_EMAILS"
    echo "    - MINIO_PUBLIC_ENDPOINT=tickets.kp.example.com"
    echo "    - MINIO_PUBLIC_USE_SSL=true"
    echo "    - B2_ACCOUNT_ID / B2_APPLICATION_KEY / B2_BUCKET_NAME"
    echo "    - CLOUDFLARE_TUNNEL_TOKEN"
fi

# ---- 5. cloudflared config dir ----
step "preparing /etc/cloudflared"
sudo mkdir -p /etc/cloudflared
sudo chown root:root /etc/cloudflared

cat <<'NOTE'

Next steps:

1. Fill in /opt/kp/.env (every TODO).
2. Drop the Cloudflare Tunnel credentials JSON into /etc/cloudflared/
   and point /opt/kp/infra/cloudflared/config.yml at it (copy from
   config.example.yml, replace placeholders).
3. As 'deploy':
       cd /opt/kp
       docker compose --env-file .env -f infra/docker-compose.yml \
                                       -f infra/compose.prod.yml up -d
4. Wire the backup cron from infra/backup/cron.example into /etc/cron.d/kp.
5. Optional: install the GlitchTip overlay (infra/compose.glitchtip.yml,
   commented in compose.prod.yml).

NOTE
