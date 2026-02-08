---
summary: "Deploy OpenClaw Gateway to an Azure VM with Docker Compose, Caddy HTTPS, and local-disk SQLite"
read_when:
  - You want OpenClaw running 24/7 on Azure
  - You want a VM-based deployment with SSH access
  - You want to deploy to Azure with fast local-disk storage
title: "Azure VM"
---

# Azure VM

**Goal:** OpenClaw Gateway running on an [Azure VM](https://learn.microsoft.com/en-us/azure/virtual-machines/) (B1ms) with Docker Compose, HTTPS via Caddy/Let's Encrypt, and SQLite on local disk for fast I/O.

This replaces the previous [Azure ACI deployment](/install/azure-aci). Compared to ACI, the VM approach gives you:

- **SSH access** for debugging and log tailing
- **Local disk storage** instead of network-mounted file shares (faster SQLite)
- **Lower cost**: ~$20/month (VM + ACR) vs ~$40-55/month (ACI + storage)

## What you need

- Azure account with an active subscription
- [Azure CLI](https://aka.ms/InstallAzureCLI) (`az`) installed and logged in
- [Docker Desktop](https://docs.docker.com/get-docker/) installed and running
- OpenClaw repo cloned locally
- Model auth: Anthropic API key (or other provider keys)

## Architecture

```
[Internet] --> [VM Public IP:80/443]
                    |
              [Caddy container] <-- TLS termination, Let's Encrypt
                    | reverse_proxy
              [OpenClaw container:18789] <-- Gateway + agents
                    |
              [Local disk: /opt/openclaw/state] <-- SQLite DBs, sessions, config
```

The deployment creates two Docker Compose services on the VM:

- **Caddy** listens on ports 80/443, auto-provisions a Let's Encrypt certificate, and reverse-proxies to the gateway
- **OpenClaw Gateway** listens on port 18789 internally

Both containers communicate via a Docker network. SQLite databases live on the VM's local disk at `/opt/openclaw/state`, not on network-mounted storage.

## Quick start

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw
./scripts/deploy-azure-vm.sh
```

The script prompts for configuration interactively. Press Enter to accept defaults.

**Important:** ACR names must be globally unique across all Azure tenants. Use a unique suffix (e.g., your initials).

### Non-interactive deployment

Pre-set environment variables to skip prompts:

```bash
export AZURE_ACR_NAME=myopenclawacr
export AZURE_DNS_LABEL=my-openclaw
export OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
export ANTHROPIC_API_KEY=sk-ant-...

./scripts/deploy-azure-vm.sh
```

## What the script does

1. Registers required Azure resource providers (first-time only)
2. Creates a resource group
3. Creates an Azure Container Registry (Basic SKU)
4. Builds the Docker image locally for `linux/amd64` and pushes to ACR
5. Creates a network security group allowing SSH (22), HTTP (80), HTTPS (443)
6. Creates a B1ms VM (1 vCPU, 2 GB RAM) with Ubuntu 24.04 LTS
7. Installs Docker and Docker Compose on the VM via SSH
8. Logs the VM into ACR and pulls the latest image
9. Generates Docker Compose config (Caddy + OpenClaw) and deploys
10. Prints the HTTPS URL with the gateway token for first-time access

## Access the Control UI

After deployment, the script prints a URL like:

```
https://my-openclaw.eastus.cloudapp.azure.com/?token=<your-token>
```

Open that URL in your browser. The token is saved to local storage on first visit.

## SSH access

Unlike ACI, you get full SSH access to the VM:

```bash
ssh openclaw@<public-ip>

# Or via FQDN:
ssh openclaw@my-openclaw.eastus.cloudapp.azure.com
```

## Manage containers

SSH into the VM and use Docker Compose:

```bash
cd /opt/openclaw

# View logs
docker compose logs -f
docker compose logs -f openclaw
docker compose logs -f caddy

# Restart services
docker compose restart

# Check status
docker compose ps

# Rebuild and restart (after a new image push)
docker compose pull
docker compose up -d
```

## Updating

To deploy a new version, re-run the script from your local machine. It rebuilds the image, pushes it, and redeploys the containers. Your state persists on disk.

```bash
git pull
./scripts/deploy-azure-vm.sh
```

Subsequent image pushes are faster because Docker layer caching means only changed layers are uploaded.

## Configuration

### Resource defaults

| Resource           | Default            | Env var                |
| ------------------ | ------------------ | ---------------------- |
| Resource group     | `openclaw-rg`      | `AZURE_RESOURCE_GROUP` |
| Location           | `eastus`           | `AZURE_LOCATION`       |
| Container registry | (prompted)         | `AZURE_ACR_NAME`       |
| VM name            | `openclaw-vm`      | `AZURE_VM_NAME`        |
| VM size            | `Standard_B1ms`    | `AZURE_VM_SIZE`        |
| Admin username     | `openclaw`         | `AZURE_VM_ADMIN`       |
| DNS label          | `openclaw-gateway` | `AZURE_DNS_LABEL`      |
| Custom domain      | (none)             | `AZURE_CUSTOM_DOMAIN`  |

### API keys

Pass provider keys as environment variables before running the script:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
./scripts/deploy-azure-vm.sh
```

These are stored in `/opt/openclaw/.env` on the VM (readable only by root).

### Editing the gateway config

SSH into the VM and edit the config directly:

```bash
ssh openclaw@<public-ip>
sudo nano /opt/openclaw/state/openclaw.json

# Restart to apply
cd /opt/openclaw && sudo docker compose restart openclaw
```

### Custom domain

To use a custom domain (e.g., `rocklawbstah.jhsconsulting.net`):

1. Set `AZURE_CUSTOM_DOMAIN=rocklawbstah.jhsconsulting.net` when running the script
2. Create an A record pointing your domain to the VM's public IP
3. Caddy will auto-provision a Let's Encrypt certificate for the custom domain

## Cost estimate

| Resource                | Monthly cost |
| ----------------------- | ------------ |
| VM (B1ms: 1 vCPU, 2 GB) | ~$15         |
| ACR Basic               | ~$5          |
| OS disk (30 GB)         | ~$1          |
| **Total**               | **~$21**     |

See [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/) for exact estimates.

## Migrating from ACI

If you previously deployed with [Azure ACI](/install/azure-aci):

1. Deploy the VM: `./scripts/deploy-azure-vm.sh`
2. Verify the VM deployment works (check the Control UI URL)
3. Tear down ACI: `./scripts/teardown-azure-aci.sh`

The teardown script deletes the ACI container group and file shares but keeps the resource group and ACR (shared with the VM deployment).

To migrate your existing state from ACI file shares to the VM:

```bash
# Download state from ACI file share
az storage file download-batch \
  --account-name <storage-account> \
  --source openclaw-state \
  --destination /tmp/openclaw-state

# Upload to VM
scp -r /tmp/openclaw-state/* openclaw@<vm-ip>:/tmp/openclaw-state/
ssh openclaw@<vm-ip> 'sudo cp -r /tmp/openclaw-state/* /opt/openclaw/state/ && sudo chown -R 1000:1000 /opt/openclaw/state/'

# Restart to pick up migrated state
ssh openclaw@<vm-ip> 'cd /opt/openclaw && sudo docker compose restart openclaw'
```

## Cleanup

Delete just the VM (keep ACR for redeployment):

```bash
az vm delete -g openclaw-rg -n openclaw-vm --yes
az network public-ip delete -g openclaw-rg -n openclaw-vm-ip
```

Delete everything (VM, ACR, all resources):

```bash
az group delete --name openclaw-rg --yes --no-wait
```

## Troubleshooting

### VM creation fails with quota error

```
Operation could not be completed as it results in exceeding approved quota
```

Your subscription may have vCPU limits. Check your quota:

```bash
az vm list-usage --location eastus --output table
```

Request a quota increase in the Azure portal, or try a different region.

### Docker not starting on the VM

SSH in and check Docker status:

```bash
ssh openclaw@<public-ip>
sudo systemctl status docker
sudo journalctl -u docker --no-pager -n 50
```

### Caddy certificate errors

Caddy needs ports 80 and 443 open. Verify NSG rules:

```bash
az network nsg rule list -g openclaw-rg --nsg-name openclaw-vm-nsg --output table
```

Also ensure your DNS A record (for custom domains) is pointing to the correct IP.

### Container keeps restarting

Check logs:

```bash
ssh openclaw@<public-ip>
cd /opt/openclaw && docker compose logs --tail 100 openclaw
```

Common causes: missing API keys in `.env`, insufficient memory (upgrade VM size).

### Cannot SSH into VM

Verify the NSG allows port 22:

```bash
az network nsg rule show -g openclaw-rg --nsg-name openclaw-vm-nsg -n AllowSSH
```

Check that your SSH key is set up correctly. The script uses `--generate-ssh-keys` which stores keys in `~/.ssh/`.
