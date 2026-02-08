#!/usr/bin/env bash
#
# deploy-azure-aci.sh — Deploy OpenClaw Gateway to Azure Container Instances
#
# Deploys a two-container group: Caddy (HTTPS via Let's Encrypt) + OpenClaw Gateway.
# Idempotent: safe to re-run for updates (rebuilds image, recreates container).
#
# Usage:
#   ./scripts/deploy-azure-aci.sh                          # Interactive prompts
#   AZURE_ACR_NAME=myacr ./scripts/deploy-azure-aci.sh     # Override defaults via env
#
set -euo pipefail

# ─── Defaults (override via environment variables) ────────────────────────────
# NOTE: ACR and storage account names must be globally unique across all Azure
# tenants. The defaults below are likely taken — always set your own.

AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-openclaw-rg}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus}"
AZURE_ACR_NAME="${AZURE_ACR_NAME:-}"
AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
AZURE_FILE_SHARE="${AZURE_FILE_SHARE:-openclaw-state}"
AZURE_CADDY_SHARE="${AZURE_CADDY_SHARE:-caddy-data}"
AZURE_CONTAINER_NAME="${AZURE_CONTAINER_NAME:-openclaw-gateway}"
AZURE_DNS_LABEL="${AZURE_DNS_LABEL:-openclaw-gateway}"
AZURE_CPU="${AZURE_CPU:-1}"
AZURE_MEMORY="${AZURE_MEMORY:-2}"
AZURE_CUSTOM_DOMAIN="${AZURE_CUSTOM_DOMAIN:-}"

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

for ns in Microsoft.ContainerRegistry Microsoft.ContainerInstance Microsoft.Storage; do
  STATE="$(az provider show --namespace "$ns" --query registrationState --output tsv 2>/dev/null || echo "NotRegistered")"
  if [[ "$STATE" != "Registered" ]]; then
    info "Registering provider $ns..."
    az provider register --namespace "$ns" --wait
  fi
done

# ─── Collect configuration ────────────────────────────────────────────────────

info "Configure deployment (press Enter to accept defaults)"
echo

prompt_var AZURE_RESOURCE_GROUP  "Resource group"           "$AZURE_RESOURCE_GROUP"
prompt_var AZURE_LOCATION        "Azure region"             "$AZURE_LOCATION"
prompt_var AZURE_ACR_NAME        "Container registry name (globally unique)" "${AZURE_ACR_NAME:-openclawacr}"
prompt_var AZURE_STORAGE_ACCOUNT "Storage account name (globally unique)"    "${AZURE_STORAGE_ACCOUNT:-openclawstorage}"
prompt_var AZURE_FILE_SHARE      "File share name"          "$AZURE_FILE_SHARE"
prompt_var AZURE_CONTAINER_NAME  "Container instance name"  "$AZURE_CONTAINER_NAME"
prompt_var AZURE_DNS_LABEL       "DNS label (FQDN prefix)"  "$AZURE_DNS_LABEL"
prompt_var AZURE_CPU             "CPU cores"                "$AZURE_CPU"
prompt_var AZURE_MEMORY          "Memory (GB)"              "$AZURE_MEMORY"
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

FQDN="${AZURE_DNS_LABEL}.${AZURE_LOCATION}.azurecontainer.io"

echo
info "Deployment summary:"
echo "  Resource group:   $AZURE_RESOURCE_GROUP"
echo "  Location:         $AZURE_LOCATION"
echo "  Registry:         $AZURE_ACR_NAME"
echo "  Storage account:  $AZURE_STORAGE_ACCOUNT"
echo "  Container:        $AZURE_CONTAINER_NAME"
echo "  FQDN:             $FQDN"
echo "  CPU / Memory:     ${AZURE_CPU} vCPU / ${AZURE_MEMORY} GB"
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
# ACI runs linux/amd64. On Apple Silicon, Docker cross-compiles via QEMU.
# ACR Tasks (az acr build) may not be available on all subscription tiers,
# so we build locally and push.

IMAGE_TAG="${ACR_LOGIN_SERVER}/openclaw:latest"

info "Building image for linux/amd64 (this may take several minutes)..."
docker build --platform linux/amd64 -t "$IMAGE_TAG" -f "$REPO_ROOT/Dockerfile" "$REPO_ROOT"

info "Pushing image to ACR..."
az acr login --name "$AZURE_ACR_NAME"
docker push "$IMAGE_TAG"

# ─── 4. Import Caddy image ───────────────────────────────────────────────────
# Import Caddy into ACR to avoid Docker Hub rate limits during ACI pull.

if az acr repository show --name "$AZURE_ACR_NAME" --repository caddy &>/dev/null; then
  info "Caddy image already in ACR, skipping import..."
else
  info "Importing Caddy image into ACR..."
  az acr import \
    --name "$AZURE_ACR_NAME" \
    --source docker.io/library/caddy:2-alpine \
    --image caddy:2-alpine \
    --output none
fi

# ─── 5. Storage Account & File Shares ────────────────────────────────────────

if az storage account show --name "$AZURE_STORAGE_ACCOUNT" --resource-group "$AZURE_RESOURCE_GROUP" &>/dev/null; then
  info "Storage account '$AZURE_STORAGE_ACCOUNT' already exists, reusing..."
else
  STOR_AVAIL="$(az storage account check-name --name "$AZURE_STORAGE_ACCOUNT" --query nameAvailable --output tsv)"
  if [[ "$STOR_AVAIL" != "true" ]]; then
    error "Storage account name '$AZURE_STORAGE_ACCOUNT' is already taken globally. Set a unique name via AZURE_STORAGE_ACCOUNT."
  fi
  info "Creating storage account '$AZURE_STORAGE_ACCOUNT'..."
  az storage account create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_STORAGE_ACCOUNT" \
    --location "$AZURE_LOCATION" \
    --sku Standard_LRS \
    --output none
fi

STORAGE_KEY="$(az storage account keys list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --query '[0].value' \
  --output tsv)"

for share in "$AZURE_FILE_SHARE" "$AZURE_CADDY_SHARE"; do
  info "Creating file share '$share' (no-op if exists)..."
  az storage share create \
    --account-name "$AZURE_STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --name "$share" \
    --quota 5 \
    --output none
done

# ─── 6. Upload initial config ────────────────────────────────────────────────
# On first deploy, write a minimal config that disables device pairing for the
# Control UI (since there is no CLI access in ACI to approve devices).

if ! az storage file show \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name "$AZURE_FILE_SHARE" \
  --path openclaw.json &>/dev/null; then
  info "Uploading initial openclaw.json config..."
  TMP_CFG="$(mktemp)"
  cat > "$TMP_CFG" <<'CFGEOF'
{
  "gateway": {
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
CFGEOF
  az storage file upload \
    --account-name "$AZURE_STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --share-name "$AZURE_FILE_SHARE" \
    --source "$TMP_CFG" \
    --path openclaw.json \
    --output none
  rm -f "$TMP_CFG"
else
  info "Config file already exists on file share, keeping it."
fi

# ─── 6b. Upload Caddyfile ───────────────────────────────────────────────────
# Build a Caddyfile that serves both the Azure FQDN and any custom domain.

CADDY_DOMAINS="$FQDN"
if [[ -n "${AZURE_CUSTOM_DOMAIN:-}" ]]; then
  CADDY_DOMAINS="$FQDN, $AZURE_CUSTOM_DOMAIN"
  info "Caddy will serve: $FQDN + $AZURE_CUSTOM_DOMAIN"
else
  info "Caddy will serve: $FQDN (no custom domain set)"
fi

info "Uploading Caddyfile..."
TMP_CADDY="$(mktemp)"
cat > "$TMP_CADDY" <<CADDYEOF
${CADDY_DOMAINS} {
	reverse_proxy localhost:18789
}
CADDYEOF
az storage file upload \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name "$AZURE_CADDY_SHARE" \
  --source "$TMP_CADDY" \
  --path Caddyfile \
  --output none
rm -f "$TMP_CADDY"

# ─── 7. ACR Credentials ──────────────────────────────────────────────────────

ACR_USERNAME="$(az acr credential show \
  --name "$AZURE_ACR_NAME" \
  --query username \
  --output tsv)"
ACR_PASSWORD="$(az acr credential show \
  --name "$AZURE_ACR_NAME" \
  --query 'passwords[0].value' \
  --output tsv)"

# ─── 8. Build secure env vars for YAML ───────────────────────────────────────

SECURE_ENV_YAML=""
SECURE_ENV_YAML+="
          - name: OPENCLAW_GATEWAY_TOKEN
            secureValue: \"$OPENCLAW_GATEWAY_TOKEN\""
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  SECURE_ENV_YAML+="
          - name: ANTHROPIC_API_KEY
            secureValue: \"$ANTHROPIC_API_KEY\""
fi
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  SECURE_ENV_YAML+="
          - name: OPENAI_API_KEY
            secureValue: \"$OPENAI_API_KEY\""
fi

# ─── 9. Generate deployment YAML ─────────────────────────────────────────────
# ACI multi-container groups require YAML deployment (not CLI flags).

DEPLOY_YAML="$(mktemp)"
cat > "$DEPLOY_YAML" <<YAMLEOF
apiVersion: 2021-10-01
location: ${AZURE_LOCATION}
name: ${AZURE_CONTAINER_NAME}
properties:
  containers:
    - name: caddy
      properties:
        image: ${ACR_LOGIN_SERVER}/caddy:2-alpine
        ports:
          - port: 443
            protocol: TCP
          - port: 80
            protocol: TCP
        resources:
          requests:
            cpu: 0.25
            memoryInGb: 0.5
        command:
          - caddy
          - run
          - --config
          - /data/Caddyfile
          - --adapter
          - caddyfile
        volumeMounts:
          - name: caddy-data
            mountPath: /data

    - name: openclaw
      properties:
        image: ${ACR_LOGIN_SERVER}/openclaw:latest
        ports:
          - port: 18789
            protocol: TCP
          - port: 18790
            protocol: TCP
        resources:
          requests:
            cpu: $(echo "$AZURE_CPU - 0.25" | bc)
            memoryInGb: $(echo "$AZURE_MEMORY - 0.5" | bc)
        command:
          - node
          - openclaw.mjs
          - gateway
          - --allow-unconfigured
          - --bind
          - lan
          - --port
          - "18789"
        environmentVariables:
          - name: HOME
            value: /home/node
          - name: NODE_ENV
            value: production
          - name: OPENCLAW_PREFER_PNPM
            value: "1"${SECURE_ENV_YAML}
        volumeMounts:
          - name: openclaw-state
            mountPath: /home/node/.openclaw

  imageRegistryCredentials:
    - server: ${ACR_LOGIN_SERVER}
      username: ${ACR_USERNAME}
      password: "${ACR_PASSWORD}"

  ipAddress:
    type: Public
    dnsNameLabel: ${AZURE_DNS_LABEL}
    ports:
      - port: 443
        protocol: TCP
      - port: 80
        protocol: TCP

  osType: Linux
  restartPolicy: Always

  volumes:
    - name: openclaw-state
      azureFile:
        shareName: ${AZURE_FILE_SHARE}
        storageAccountName: ${AZURE_STORAGE_ACCOUNT}
        storageAccountKey: "${STORAGE_KEY}"
    - name: caddy-data
      azureFile:
        shareName: ${AZURE_CADDY_SHARE}
        storageAccountName: ${AZURE_STORAGE_ACCOUNT}
        storageAccountKey: "${STORAGE_KEY}"

type: Microsoft.ContainerInstance/containerGroups
YAMLEOF

# ─── 10. Delete existing container (if updating) ─────────────────────────────

if az container show \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_CONTAINER_NAME" &>/dev/null; then
  info "Deleting existing container '$AZURE_CONTAINER_NAME' for update..."
  az container delete \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_CONTAINER_NAME" \
    --yes \
    --output none
fi

# ─── 11. Create Container Group ──────────────────────────────────────────────

info "Creating container group (Caddy + OpenClaw)..."
az container create \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --file "$DEPLOY_YAML" \
  --output none

rm -f "$DEPLOY_YAML"

# ─── 12. Wait for startup and get status ─────────────────────────────────────

info "Waiting for container to start..."
sleep 10

STATE="$(az container show \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_CONTAINER_NAME" \
  --query 'instanceView.state' \
  --output tsv)"

# ─── Done ─────────────────────────────────────────────────────────────────────

echo
info "Deployment complete!"
echo
echo "  State:       $STATE"
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
echo "Verify:"
echo "  az container show -g $AZURE_RESOURCE_GROUP -n $AZURE_CONTAINER_NAME --query instanceView.state"
echo "  az container logs -g $AZURE_RESOURCE_GROUP -n $AZURE_CONTAINER_NAME --container-name openclaw"
echo "  az container logs -g $AZURE_RESOURCE_GROUP -n $AZURE_CONTAINER_NAME --container-name caddy"
echo
echo "Cleanup (deletes everything):"
echo "  az group delete --name $AZURE_RESOURCE_GROUP --yes --no-wait"
echo
