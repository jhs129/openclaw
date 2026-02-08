---
summary: "Deploy OpenClaw Gateway to Azure Container Instances (ACI) with HTTPS via Let's Encrypt"
read_when:
  - You want OpenClaw running 24/7 on Azure
  - You want a serverless container deployment without managing VMs
  - You want to deploy to Azure Container Instances
title: "Azure ACI"
---

# Azure Container Instances

> **Superseded:** The [Azure VM deployment](/install/azure-vm) is now the recommended Azure option. It provides SSH access, faster local-disk storage for SQLite, and lower cost (~$20/month vs ~$40-55/month). This ACI guide remains for reference.

**Goal:** OpenClaw Gateway running on [Azure Container Instances](https://learn.microsoft.com/en-us/azure/container-instances/) with HTTPS (Let's Encrypt), persistent state, and automatic restarts.

## What you need

- Azure account with an active subscription
- [Azure CLI](https://aka.ms/InstallAzureCLI) (`az`) installed and logged in
- [Docker Desktop](https://docs.docker.com/get-docker/) installed and running
- OpenClaw repo cloned locally
- Model auth: Anthropic API key (or other provider keys)

## Architecture

```
[Browser] --HTTPS--> [Caddy (Let's Encrypt)] --HTTP--> [OpenClaw Gateway]
                            |                                  |
                      [Azure File Share]               [Azure File Share]
                       /data (certs)                /home/node/.openclaw
```

The deployment creates a two-container group in ACI:

- **Caddy** listens on ports 80/443, auto-provisions a Let's Encrypt certificate, and reverse-proxies to the gateway
- **OpenClaw Gateway** listens on port 18789 internally

Both containers share the same network namespace (like a Kubernetes pod), so Caddy reaches the gateway on `localhost:18789`.

**Persistent storage**: Two Azure File Shares — one for OpenClaw state, one for Caddy's certificate data.

## Quick start

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw
./scripts/deploy-azure-aci.sh
```

The script prompts for configuration interactively. Press Enter to accept defaults.

**Important:** ACR and storage account names must be globally unique across all Azure tenants. The script checks availability and will error if your chosen names are taken. Use a unique suffix (e.g., your initials).

### Non-interactive deployment

Pre-set environment variables to skip prompts:

```bash
export AZURE_ACR_NAME=myopenclawacr
export AZURE_STORAGE_ACCOUNT=myopenclawstore
export AZURE_DNS_LABEL=my-openclaw
export OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
export ANTHROPIC_API_KEY=sk-ant-...

./scripts/deploy-azure-aci.sh
```

## What the script does

1. Registers required Azure resource providers (first-time only)
2. Creates a resource group
3. Creates an Azure Container Registry (Basic SKU)
4. Builds the Docker image locally for `linux/amd64` and pushes to ACR
5. Imports the Caddy image into ACR (avoids Docker Hub rate limits)
6. Creates a storage account and two file shares (state + Caddy certs)
7. Uploads an initial `openclaw.json` config
8. Generates a deployment YAML and creates the multi-container group
9. Prints the HTTPS URL with the gateway token for first-time access

## Access the Control UI

After deployment, the script prints a URL like:

```
https://my-openclaw.eastus.azurecontainer.io/?token=<your-token>
```

Open that URL in your browser. The token is saved to local storage on first visit.

For subsequent visits, just go to:

```
https://my-openclaw.eastus.azurecontainer.io/
```

## Verify deployment

```bash
# Check container state
az container show -g openclaw-rg -n openclaw-gateway --query instanceView.state

# View gateway logs
az container logs -g openclaw-rg -n openclaw-gateway --container-name openclaw

# View Caddy/TLS logs
az container logs -g openclaw-rg -n openclaw-gateway --container-name caddy

# Follow gateway logs
az container logs -g openclaw-rg -n openclaw-gateway --container-name openclaw --follow
```

## Updating

To deploy a new version, re-run the script. It rebuilds the image, pushes it, and recreates the container group. Your state and Caddy certificates persist on the file shares.

```bash
git pull
./scripts/deploy-azure-aci.sh
```

Subsequent image pushes are faster because Docker layer caching means only changed layers are uploaded.

## Configuration

### Resource defaults

| Resource           | Default            | Env var                      |
| ------------------ | ------------------ | ---------------------------- |
| Resource group     | `openclaw-rg`      | `AZURE_RESOURCE_GROUP`       |
| Location           | `eastus`           | `AZURE_LOCATION`             |
| Container registry | (prompted)         | `AZURE_ACR_NAME`             |
| Storage account    | (prompted)         | `AZURE_STORAGE_ACCOUNT`      |
| File share         | `openclaw-state`   | `AZURE_FILE_SHARE`           |
| Container name     | `openclaw-gateway` | `AZURE_CONTAINER_NAME`       |
| DNS label          | `openclaw-gateway` | `AZURE_DNS_LABEL`            |
| CPU / Memory       | 1 vCPU / 2 GB      | `AZURE_CPU` / `AZURE_MEMORY` |

### API keys

Pass provider keys as environment variables before running the script:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
./scripts/deploy-azure-aci.sh
```

These are stored as secure environment variables in ACI (encrypted, not visible in the Azure portal).

### Editing the gateway config

The gateway reads `openclaw.json` from the Azure File Share. To update it:

```bash
# Download current config
az storage file download \
  --account-name <storage-account> \
  --share-name openclaw-state \
  --path openclaw.json \
  --dest /tmp/openclaw.json

# Edit locally, then upload
az storage file upload \
  --account-name <storage-account> \
  --share-name openclaw-state \
  --source /tmp/openclaw.json \
  --path openclaw.json

# Restart to apply
az container restart -g openclaw-rg -n openclaw-gateway
```

## Cost estimate

| Resource                 | Monthly cost |
| ------------------------ | ------------ |
| ACI (1 vCPU, 2 GB, 24/7) | ~$35-50      |
| ACR Basic                | ~$5          |
| Storage (file shares)    | ~$0.10       |
| **Total**                | **~$40-55**  |

See [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/) for exact estimates.

## Cleanup

Delete everything in one command:

```bash
az group delete --name openclaw-rg --yes --no-wait
```

This removes the resource group and all resources inside it (container, registry, storage).

## Security notes

- HTTPS is handled by Caddy with auto-provisioned Let's Encrypt certificates. Certs are persisted on the Caddy file share and auto-renewed.
- The gateway token is required for all connections. Treat it like a password.
- Secrets passed via `secureValue` in the deployment YAML are encrypted at rest and not visible in `az container show`.
- The initial config sets `gateway.controlUi.dangerouslyDisableDeviceAuth: true` because there is no CLI access in ACI to approve devices. For tighter security, set up device auth after initial access and remove this flag.
- For private networking, deploy into an [Azure Virtual Network](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-vnet).

## Troubleshooting

### MissingSubscriptionRegistration

```
The subscription is not registered to use namespace 'Microsoft.ContainerRegistry'
```

The script registers providers automatically. If you see this error, register manually:

```bash
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.ContainerInstance --wait
az provider register --namespace Microsoft.Storage --wait
```

### ACR Tasks not available

```
ACR Tasks requests are not permitted
```

Some Azure subscription tiers do not support ACR Tasks (cloud builds). The script builds locally with Docker instead. Make sure Docker Desktop is installed and running.

### Image OS type mismatch

```
The container image doesn't support specified OS 'Linux'
```

The image was built for ARM (Apple Silicon). The script always builds with `--platform linux/amd64` which is required by ACI. If you see this error, rebuild the image.

### Docker Hub rate limit / RegistryErrorResponse

```
An error response is received from the docker registry 'index.docker.io'
```

The script imports the Caddy image into your ACR to avoid this. If it still happens, wait a few minutes and retry.

### ACR or storage account name taken

Both must be globally unique across all Azure tenants. Pick a unique name with your initials or a random suffix:

```bash
AZURE_ACR_NAME=openclawjhs AZURE_STORAGE_ACCOUNT=openclawjhsstore ./scripts/deploy-azure-aci.sh
```

### Container stuck in "Waiting" or "Creating"

Check events for errors:

```bash
az container show -g openclaw-rg -n openclaw-gateway --query instanceView.events
```

Common causes: ACR credentials expired, image not found, or resource quota limits.

### "pairing required" in Control UI

The initial config uploaded by the script disables device pairing. If you see this error, the config may not have been written. Upload it manually:

```bash
echo '{"gateway":{"controlUi":{"dangerouslyDisableDeviceAuth":true}}}' > /tmp/openclaw.json
az storage file upload \
  --account-name <storage-account> \
  --share-name openclaw-state \
  --source /tmp/openclaw.json \
  --path openclaw.json
az container restart -g openclaw-rg -n openclaw-gateway
```

### OOM / container restarting

Increase memory:

```bash
AZURE_MEMORY=4 ./scripts/deploy-azure-aci.sh
```
