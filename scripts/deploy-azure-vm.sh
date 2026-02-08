#!/usr/bin/env bash
#
# deploy-azure-vm.sh — Deploy OpenClaw Gateway to an Azure VM with Docker Compose
#
# Creates a B1ms VM (1 vCPU, 2 GB RAM) running Docker Compose with Caddy (HTTPS)
# and OpenClaw Gateway. SQLite databases live on the VM's local disk for fast I/O.
#
# Idempotent: safe to re-run for updates (rebuilds image, redeploys containers).
#
# Usage:
#   ./scripts/deploy-azure-vm.sh                          # Interactive prompts
#   AZURE_ACR_NAME=myacr ./scripts/deploy-azure-vm.sh     # Override defaults via env
#
set -euo pipefail

# ─── Defaults (override via environment variables) ────────────────────────────
# NOTE: ACR names must be globally unique across all Azure tenants.

AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-openclaw-rg}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus}"
AZURE_ACR_NAME="${AZURE_ACR_NAME:-}"
AZURE_VM_NAME="${AZURE_VM_NAME:-openclaw-vm}"
AZURE_VM_SIZE="${AZURE_VM_SIZE:-Standard_B1ms}"
AZURE_VM_IMAGE="${AZURE_VM_IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"
AZURE_VM_ADMIN="${AZURE_VM_ADMIN:-openclaw}"
AZURE_DNS_LABEL="${AZURE_DNS_LABEL:-openclaw-gateway}"
AZURE_CUSTOM_DOMAIN="${AZURE_CUSTOM_DOMAIN:-}"
AZURE_NSG_NAME="${AZURE_NSG_NAME:-openclaw-vm-nsg}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

prompt_var() {
  local var_name="$1" prompt_text="$2" default_val="$3"
  local current_val="${!var_name:-$default_val}"
  if [[ -t 0 ]]; then
    printf '%s [%s]: ' "$prompt_text" "$current_val"
    read -r input
    if [[ -n "$input" ]]; then
      eval "$var_name=\$input"
    else
      eval "$var_name=\$current_val"
    fi
  else
    eval "$var_name=\$current_val"
  fi
}

prompt_secret() {
  local var_name="$1" prompt_text="$2" required="${3:-false}"
  local current_val="${!var_name:-}"
  if [[ -n "$current_val" ]]; then
    info "$prompt_text: (using value from environment)"
    return
  fi
  if [[ -t 0 ]]; then
    printf '%s: ' "$prompt_text"
    read -rs input
    echo
    eval "$var_name=\$input"
  fi
  if [[ "$required" == "true" && -z "${!var_name:-}" ]]; then
    error "$var_name is required. Set it via environment or enter interactively."
  fi
}

# ─── Preflight ────────────────────────────────────────────────────────────────

if ! command -v az &>/dev/null; then
  error "Azure CLI (az) not found. Install it: https://aka.ms/InstallAzureCLI"
fi

if ! command -v docker &>/dev/null; then
  error "Docker not found. Install Docker Desktop: https://docs.docker.com/get-docker/"
fi

# Ensure logged in
if ! az account show &>/dev/null; then
  info "Not logged in to Azure. Running 'az login'..."
  az login
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -f "$REPO_ROOT/Dockerfile" ]]; then
  error "Cannot find Dockerfile. Run this script from the openclaw repo root."
fi

# ─── Register resource providers (first-time only) ───────────────────────────

for ns in Microsoft.ContainerRegistry Microsoft.Compute Microsoft.Network; do
  STATE="$(az provider show --namespace "$ns" --query registrationState --output tsv 2>/dev/null || echo "NotRegistered")"
  if [[ "$STATE" != "Registered" ]]; then
    info "Registering provider $ns..."
    az provider register --namespace "$ns" --wait
  fi
done

# ─── Collect configuration ────────────────────────────────────────────────────

info "Configure deployment (press Enter to accept defaults)"
echo

prompt_var AZURE_RESOURCE_GROUP  "Resource group"                              "$AZURE_RESOURCE_GROUP"
prompt_var AZURE_LOCATION        "Azure region"                                "$AZURE_LOCATION"
prompt_var AZURE_ACR_NAME        "Container registry name (globally unique)"   "${AZURE_ACR_NAME:-openclawacr}"
prompt_var AZURE_VM_NAME         "VM name"                                     "$AZURE_VM_NAME"
prompt_var AZURE_VM_SIZE         "VM size"                                     "$AZURE_VM_SIZE"
prompt_var AZURE_VM_ADMIN        "VM admin username"                           "$AZURE_VM_ADMIN"
prompt_var AZURE_DNS_LABEL       "DNS label (FQDN prefix)"                     "$AZURE_DNS_LABEL"
prompt_var AZURE_CUSTOM_DOMAIN   "Custom domain (optional, e.g. rl.example.com)" "${AZURE_CUSTOM_DOMAIN:-}"

echo
prompt_secret OPENCLAW_GATEWAY_TOKEN "Gateway token (leave blank to auto-generate)" false
if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  info "Generated gateway token: $OPENCLAW_GATEWAY_TOKEN"
  warn "Save this token — you will need it to access the Control UI."
fi

prompt_secret ANTHROPIC_API_KEY   "Anthropic API key (optional)" false
prompt_secret OPENAI_API_KEY      "OpenAI API key (optional)" false

FQDN="${AZURE_DNS_LABEL}.${AZURE_LOCATION}.cloudapp.azure.com"

echo
info "Deployment summary:"
echo "  Resource group:   $AZURE_RESOURCE_GROUP"
echo "  Location:         $AZURE_LOCATION"
echo "  Registry:         $AZURE_ACR_NAME"
echo "  VM:               $AZURE_VM_NAME ($AZURE_VM_SIZE)"
echo "  Admin user:       $AZURE_VM_ADMIN"
echo "  FQDN:             $FQDN"
if [[ -n "${AZURE_CUSTOM_DOMAIN:-}" ]]; then
echo "  Custom domain:    $AZURE_CUSTOM_DOMAIN"
fi
echo

if [[ -t 0 ]]; then
  printf 'Proceed? [Y/n] '
  read -r confirm
  if [[ "$confirm" =~ ^[Nn] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# ─── 1. Resource Group ───────────────────────────────────────────────────────

info "Creating resource group '$AZURE_RESOURCE_GROUP' in '$AZURE_LOCATION'..."
az group create \
  --name "$AZURE_RESOURCE_GROUP" \
  --location "$AZURE_LOCATION" \
  --output none

# ─── 2. Container Registry ───────────────────────────────────────────────────

if az acr show --name "$AZURE_ACR_NAME" --resource-group "$AZURE_RESOURCE_GROUP" &>/dev/null; then
  info "Container registry '$AZURE_ACR_NAME' already exists, reusing..."
else
  AVAIL="$(az acr check-name --name "$AZURE_ACR_NAME" --query nameAvailable --output tsv)"
  if [[ "$AVAIL" != "true" ]]; then
    error "ACR name '$AZURE_ACR_NAME' is already taken globally. Set a unique name via AZURE_ACR_NAME."
  fi
  info "Creating container registry '$AZURE_ACR_NAME'..."
  az acr create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_ACR_NAME" \
    --sku Basic \
    --admin-enabled true \
    --output none
fi

ACR_LOGIN_SERVER="$(az acr show \
  --name "$AZURE_ACR_NAME" \
  --query loginServer \
  --output tsv)"
info "Registry server: $ACR_LOGIN_SERVER"

# ─── 3. Build & Push Image ───────────────────────────────────────────────────
# The VM runs linux/amd64. On Apple Silicon, Docker cross-compiles via QEMU.

IMAGE_TAG="${ACR_LOGIN_SERVER}/openclaw:latest"

info "Building image for linux/amd64 (this may take several minutes)..."
docker build --platform linux/amd64 -t "$IMAGE_TAG" -f "$REPO_ROOT/Dockerfile" "$REPO_ROOT"

info "Pushing image to ACR..."
az acr login --name "$AZURE_ACR_NAME"
docker push "$IMAGE_TAG"

# ─── 4. Create NSG ──────────────────────────────────────────────────────────

if az network nsg show --resource-group "$AZURE_RESOURCE_GROUP" --name "$AZURE_NSG_NAME" &>/dev/null; then
  info "NSG '$AZURE_NSG_NAME' already exists, reusing..."
else
  info "Creating network security group '$AZURE_NSG_NAME'..."
  az network nsg create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_NSG_NAME" \
    --location "$AZURE_LOCATION" \
    --output none
fi

# Allow SSH, HTTP, HTTPS
for rule_info in "AllowSSH:22:100" "AllowHTTP:80:110" "AllowHTTPS:443:120"; do
  IFS=: read -r rule_name port priority <<< "$rule_info"
  if ! az network nsg rule show --resource-group "$AZURE_RESOURCE_GROUP" --nsg-name "$AZURE_NSG_NAME" --name "$rule_name" &>/dev/null; then
    info "Adding NSG rule: $rule_name (port $port)..."
    az network nsg rule create \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --nsg-name "$AZURE_NSG_NAME" \
      --name "$rule_name" \
      --priority "$priority" \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --destination-port-ranges "$port" \
      --output none
  fi
done

# ─── 5. Create VM ────────────────────────────────────────────────────────────

if az vm show --resource-group "$AZURE_RESOURCE_GROUP" --name "$AZURE_VM_NAME" &>/dev/null; then
  info "VM '$AZURE_VM_NAME' already exists, skipping creation..."
else
  info "Creating VM '$AZURE_VM_NAME' ($AZURE_VM_SIZE)..."
  az vm create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_VM_NAME" \
    --image "$AZURE_VM_IMAGE" \
    --size "$AZURE_VM_SIZE" \
    --admin-username "$AZURE_VM_ADMIN" \
    --generate-ssh-keys \
    --nsg "$AZURE_NSG_NAME" \
    --public-ip-address "${AZURE_VM_NAME}-ip" \
    --public-ip-sku Standard \
    --os-disk-size-gb 30 \
    --output none

  info "Waiting for VM to be ready..."
  az vm wait \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_VM_NAME" \
    --created
fi

# ─── 6. Set DNS label on public IP ──────────────────────────────────────────

PUBLIC_IP_NAME="${AZURE_VM_NAME}-ip"
info "Setting DNS label '$AZURE_DNS_LABEL' on public IP..."
az network public-ip update \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$PUBLIC_IP_NAME" \
  --dns-name "$AZURE_DNS_LABEL" \
  --output none

VM_PUBLIC_IP="$(az network public-ip show \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$PUBLIC_IP_NAME" \
  --query ipAddress \
  --output tsv)"
info "VM public IP: $VM_PUBLIC_IP"

# ─── 7. Install Docker on the VM ────────────────────────────────────────────

info "Installing Docker on the VM (via SSH)..."
az vm run-command invoke \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_VM_NAME" \
  --command-id RunShellScript \
  --scripts '
    if command -v docker &>/dev/null; then
      echo "Docker already installed, skipping..."
      exit 0
    fi
    apt-get update
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker '"$AZURE_VM_ADMIN"'
  ' \
  --output none

# ─── 8. Log VM into ACR ─────────────────────────────────────────────────────

ACR_USERNAME="$(az acr credential show \
  --name "$AZURE_ACR_NAME" \
  --query username \
  --output tsv)"
ACR_PASSWORD="$(az acr credential show \
  --name "$AZURE_ACR_NAME" \
  --query 'passwords[0].value' \
  --output tsv)"

info "Logging VM into ACR..."
az vm run-command invoke \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_VM_NAME" \
  --command-id RunShellScript \
  --scripts "docker login ${ACR_LOGIN_SERVER} -u '${ACR_USERNAME}' -p '${ACR_PASSWORD}'" \
  --output none

# ─── 9. Pull latest image on VM ─────────────────────────────────────────────

info "Pulling latest image on VM..."
az vm run-command invoke \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_VM_NAME" \
  --command-id RunShellScript \
  --scripts "docker pull ${IMAGE_TAG}" \
  --output none

# ─── 10. Create directories and deploy config ───────────────────────────────

# Build Caddy domains
CADDY_DOMAINS="$FQDN"
if [[ -n "${AZURE_CUSTOM_DOMAIN:-}" ]]; then
  CADDY_DOMAINS="$FQDN, $AZURE_CUSTOM_DOMAIN"
  info "Caddy will serve: $FQDN + $AZURE_CUSTOM_DOMAIN"
else
  info "Caddy will serve: $FQDN (no custom domain set)"
fi

# Build .env contents
ENV_CONTENTS="OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}"
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  ENV_CONTENTS+="\nANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
fi
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  ENV_CONTENTS+="\nOPENAI_API_KEY=${OPENAI_API_KEY}"
fi

info "Setting up deployment files on VM..."
az vm run-command invoke \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_VM_NAME" \
  --command-id RunShellScript \
  --scripts '
    set -euo pipefail

    # Create directories
    mkdir -p /opt/openclaw/state
    mkdir -p /opt/openclaw/caddy-data
    mkdir -p /opt/openclaw/caddy-config

    # Set ownership to match container user (node = uid 1000)
    chown -R 1000:1000 /opt/openclaw/state

    # Write initial openclaw.json if not present
    if [[ ! -f /opt/openclaw/state/openclaw.json ]]; then
      cat > /opt/openclaw/state/openclaw.json <<CFGEOF
{
  "gateway": {
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
CFGEOF
      chown 1000:1000 /opt/openclaw/state/openclaw.json
    fi

    # Write .env file
    printf "'"${ENV_CONTENTS}"'\n" > /opt/openclaw/.env
    chmod 600 /opt/openclaw/.env

    # Write Caddyfile
    cat > /opt/openclaw/Caddyfile <<CADDYEOF
'"${CADDY_DOMAINS}"' {
	reverse_proxy openclaw:18789
}
CADDYEOF

    # Write docker-compose.yml
    cat > /opt/openclaw/docker-compose.yml <<COMPOSEEOF
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - /opt/openclaw/Caddyfile:/etc/caddy/Caddyfile:ro
      - /opt/openclaw/caddy-data:/data
      - /opt/openclaw/caddy-config:/config
    depends_on:
      - openclaw

  openclaw:
    image: '"${IMAGE_TAG}"'
    restart: unless-stopped
    env_file:
      - /opt/openclaw/.env
    environment:
      - HOME=/home/node
      - NODE_ENV=production
      - OPENCLAW_PREFER_PNPM=1
    volumes:
      - /opt/openclaw/state:/home/node/.openclaw
    command:
      - node
      - openclaw.mjs
      - gateway
      - --allow-unconfigured
      - --bind
      - lan
      - --port
      - "18789"
COMPOSEEOF

    echo "Deployment files created successfully."
  ' \
  --output none

# ─── 11. Start containers ───────────────────────────────────────────────────

info "Starting Docker Compose on VM..."
az vm run-command invoke \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_VM_NAME" \
  --command-id RunShellScript \
  --scripts '
    cd /opt/openclaw
    docker compose down --remove-orphans 2>/dev/null || true
    docker compose up -d
    sleep 5
    docker compose ps
  ' \
  --output tsv --query 'value[0].message'

# ─── Done ─────────────────────────────────────────────────────────────────────

echo
info "Deployment complete!"
echo
echo "  VM:          $AZURE_VM_NAME ($AZURE_VM_SIZE)"
echo "  Public IP:   $VM_PUBLIC_IP"
echo "  FQDN:        $FQDN"
if [[ -n "${AZURE_CUSTOM_DOMAIN:-}" ]]; then
echo "  Custom:      $AZURE_CUSTOM_DOMAIN"
fi
echo "  Control UI:  https://${FQDN}/"
echo
echo "  Gateway token: $OPENCLAW_GATEWAY_TOKEN"
echo
echo "  First-time access (paste into browser):"
echo "  https://${FQDN}/?token=${OPENCLAW_GATEWAY_TOKEN}"
if [[ -n "${AZURE_CUSTOM_DOMAIN:-}" ]]; then
echo "  https://${AZURE_CUSTOM_DOMAIN}/?token=${OPENCLAW_GATEWAY_TOKEN}"
fi
echo
echo "SSH access:"
echo "  ssh ${AZURE_VM_ADMIN}@${VM_PUBLIC_IP}"
echo "  ssh ${AZURE_VM_ADMIN}@${FQDN}"
echo
echo "Manage containers (via SSH):"
echo "  cd /opt/openclaw && docker compose logs -f"
echo "  cd /opt/openclaw && docker compose restart"
echo "  cd /opt/openclaw && docker compose ps"
echo
echo "Update deployment:"
echo "  ./scripts/deploy-azure-vm.sh    # Rebuilds image and redeploys"
echo
if [[ -n "${AZURE_CUSTOM_DOMAIN:-}" ]]; then
echo "Custom domain setup:"
echo "  Point an A record for ${AZURE_CUSTOM_DOMAIN} to ${VM_PUBLIC_IP}"
echo "  Caddy will auto-provision a Let's Encrypt certificate."
echo
fi
echo "Cleanup (deletes VM only, keeps ACR):"
echo "  az vm delete -g $AZURE_RESOURCE_GROUP -n $AZURE_VM_NAME --yes"
echo "  az network public-ip delete -g $AZURE_RESOURCE_GROUP -n ${PUBLIC_IP_NAME}"
echo
echo "Cleanup (deletes everything):"
echo "  az group delete --name $AZURE_RESOURCE_GROUP --yes --no-wait"
echo
