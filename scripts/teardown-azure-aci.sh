#!/usr/bin/env bash
#
# teardown-azure-aci.sh — Remove Azure Container Instances deployment
#
# Cleans up ACI resources after migrating to a VM deployment:
#   - Deletes the ACI container group (stops billing immediately)
#   - Deletes ACI-specific file shares (openclaw-state, caddy-data)
#   - Optionally deletes the storage account
#
# Keeps:
#   - Resource group (openclaw-rg) — still used by VM
#   - Container registry (ACR) — still used by VM
#
# Usage:
#   ./scripts/teardown-azure-aci.sh
#   AZURE_STORAGE_ACCOUNT=mystore ./scripts/teardown-azure-aci.sh
#
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-openclaw-rg}"
AZURE_CONTAINER_NAME="${AZURE_CONTAINER_NAME:-openclaw-gateway}"
AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
AZURE_FILE_SHARE="${AZURE_FILE_SHARE:-openclaw-state}"
AZURE_CADDY_SHARE="${AZURE_CADDY_SHARE:-caddy-data}"

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

# ─── Preflight ────────────────────────────────────────────────────────────────

if ! command -v az &>/dev/null; then
  error "Azure CLI (az) not found. Install it: https://aka.ms/InstallAzureCLI"
fi

if ! az account show &>/dev/null; then
  info "Not logged in to Azure. Running 'az login'..."
  az login
fi

# ─── Collect configuration ────────────────────────────────────────────────────

info "Configure teardown (press Enter to accept defaults)"
echo

prompt_var AZURE_RESOURCE_GROUP  "Resource group"          "$AZURE_RESOURCE_GROUP"
prompt_var AZURE_CONTAINER_NAME  "ACI container name"      "$AZURE_CONTAINER_NAME"
prompt_var AZURE_STORAGE_ACCOUNT "Storage account name"    "${AZURE_STORAGE_ACCOUNT:-openclawstorage}"
prompt_var AZURE_FILE_SHARE      "State file share name"   "$AZURE_FILE_SHARE"
prompt_var AZURE_CADDY_SHARE     "Caddy file share name"   "$AZURE_CADDY_SHARE"

echo
info "This will delete the following ACI resources:"
echo "  Container group:  $AZURE_CONTAINER_NAME"
echo "  File share:       $AZURE_FILE_SHARE"
echo "  File share:       $AZURE_CADDY_SHARE"
echo
info "These resources will be KEPT:"
echo "  Resource group:   $AZURE_RESOURCE_GROUP"
echo "  Container registry (ACR)"
echo

if [[ -t 0 ]]; then
  printf 'Proceed with teardown? [y/N] '
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# ─── 1. Delete ACI container group ──────────────────────────────────────────

if az container show \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_CONTAINER_NAME" &>/dev/null; then
  info "Deleting ACI container group '$AZURE_CONTAINER_NAME'..."
  az container delete \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_CONTAINER_NAME" \
    --yes \
    --output none
  info "Container group deleted. ACI billing stopped."
else
  info "Container group '$AZURE_CONTAINER_NAME' not found, skipping."
fi

# ─── 2. Delete file shares ──────────────────────────────────────────────────

if az storage account show --name "$AZURE_STORAGE_ACCOUNT" --resource-group "$AZURE_RESOURCE_GROUP" &>/dev/null; then
  STORAGE_KEY="$(az storage account keys list \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --account-name "$AZURE_STORAGE_ACCOUNT" \
    --query '[0].value' \
    --output tsv)"

  for share in "$AZURE_FILE_SHARE" "$AZURE_CADDY_SHARE"; do
    if az storage share show \
      --account-name "$AZURE_STORAGE_ACCOUNT" \
      --account-key "$STORAGE_KEY" \
      --name "$share" &>/dev/null; then
      info "Deleting file share '$share'..."
      az storage share delete \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --name "$share" \
        --output none
    else
      info "File share '$share' not found, skipping."
    fi
  done

  # Check if the storage account has any remaining shares
  REMAINING="$(az storage share list \
    --account-name "$AZURE_STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --query 'length(@)' \
    --output tsv)"

  if [[ "$REMAINING" == "0" ]]; then
    echo
    if [[ -t 0 ]]; then
      printf 'Storage account has no remaining file shares. Delete it too? [y/N] '
      read -r del_storage
      if [[ "$del_storage" =~ ^[Yy] ]]; then
        info "Deleting storage account '$AZURE_STORAGE_ACCOUNT'..."
        az storage account delete \
          --resource-group "$AZURE_RESOURCE_GROUP" \
          --name "$AZURE_STORAGE_ACCOUNT" \
          --yes \
          --output none
        info "Storage account deleted."
      else
        info "Keeping storage account '$AZURE_STORAGE_ACCOUNT'."
      fi
    else
      info "Storage account '$AZURE_STORAGE_ACCOUNT' has no remaining shares but keeping it (non-interactive mode)."
    fi
  else
    info "Storage account '$AZURE_STORAGE_ACCOUNT' still has $REMAINING file share(s), keeping it."
  fi
else
  info "Storage account '$AZURE_STORAGE_ACCOUNT' not found, skipping."
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo
info "ACI teardown complete!"
echo
echo "  Deleted: ACI container group, file shares"
echo "  Kept:    Resource group, ACR"
echo
echo "  Your VM deployment is unaffected."
echo
