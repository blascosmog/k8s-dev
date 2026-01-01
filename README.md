# k8s-dev

A development environment for Kubernetes applications with pre-configured manifests and Helm values.

> ⚠️ **IMPORTANT DISCLAIMER**: This is an academic/laboratory project designed for learning and development purposes. **DO NOT deploy in a production environment exposed to the internet** without proper security hardening (firewalls, fail2ban, intrusion detection, regular security updates, etc.). The configurations provided use example values that must be customized for your environment.

## Overview

This repository contains Kubernetes manifests and Helm values for deploying various applications in a development environment. It demonstrates Infrastructure as Code (IaC) principles and container orchestration best practices for educational purposes.

## Structure

```
.
├── README.md                    # This file
├── install.sh                   # Installation script
├── manifests/                   # Kubernetes YAML manifests
│   ├── portainer-admin.yaml    # Portainer with RBAC fix
│   ├── heimdall-manual.yaml    # Heimdall with hostPath persistence
│   ├── n8n-deployment.yaml     # n8n workflow automation
│   └── web-demo/               # Web demo applications
└── helm-values/                 # Helm chart values
    ├── crowdsec-values.yaml    # CrowdSec configuration
    └── adguard-values.yaml     # AdGuard Home configuration
```

## Prerequisites

- Kubernetes cluster (1.19+) or K3s
- kubectl configured to access your cluster
- Helm 3.x (for Helm deployments)
- Storage directories at `/mnt/apps/` (or modify paths in manifests)
- Administrative access to your cluster

### Network Configuration Note

The example configurations in this repository use:
- **Local IP**: `192.168.1.200` (RFC1918 private address range)
  - This is a private, non-routable IP address used within your local area network (LAN)
  - Safe to use in documentation as it cannot be accessed from the public internet
  - **Action Required**: Replace with your actual server's local IP address in all manifests
- **VPN Access**: References to Tailscale IPs use placeholder format `100.x.y.z`
  - **Action Required**: Replace with your actual Tailscale IP after configuration

## Security Configuration

🔒 **BEFORE DEPLOYMENT**, review and configure the following:

1. **Review all YAML manifests** in the `manifests/` directory
2. **Update placeholder values**:
   - IP addresses (replace `192.168.1.200` with your server IP)
   - Usernames (manifests use UID/GID `1000:1000` - verify this matches your system)
   - Any `CHANGE_ME` or placeholder values
3. **Secrets Management**: This repository does not include credentials. You must:
   - Configure authentication in AdGuard Home web UI (first boot)
   - Set Portainer admin password (first login)
   - Configure CrowdSec enrollment keys if using CrowdSec Console
   - Never commit real credentials to version control
4. **Storage Paths**: Ensure the following directories exist with proper permissions:
   ```bash
   sudo mkdir -p /mnt/apps/{portainer,heimdall,n8n}
   sudo chown -R 1000:1000 /mnt/apps/  # Adjust UID/GID as needed
   ```

## Installation

### Quick Start (Interactive Mode)

**After reviewing the security section above**, run the installation script:

```bash
chmod +x install.sh
./install.sh
```

The script will run in **interactive mode** by default, asking you for confirmation before deploying each application:

- ✅ **Core infrastructure checks** run automatically (root privileges, kubectl, cluster connectivity, storage)
- ❓ **Application deployments** require your confirmation:
  - Portainer (Container Management UI)
  - Heimdall (Application Dashboard)
  - n8n (Workflow Automation)
  - Web Demo (Sample Application)

**Example interaction:**
```
Deploy Portainer (Container Management UI)? [Y/n] y
✓ Portainer deployed successfully

Deploy Heimdall (Application Dashboard)? [Y/n] n
ℹ Skipping Heimdall deployment...
```

### Non-Interactive Mode

To deploy all applications automatically without prompts:

```bash
INTERACTIVE_MODE=false ./install.sh
```

This is useful for automation scripts or CI/CD pipelines.

### Manual Installation

#### Deploy Portainer

```bash
kubectl apply -f manifests/portainer-admin.yaml
```

#### Deploy Heimdall

```bash
kubectl apply -f manifests/heimdall-manual.yaml
```

#### Deploy n8n

```bash
kubectl apply -f manifests/n8n-deployment.yaml
```

#### Deploy with Helm

```bash
# Install CrowdSec
helm repo add crowdsec https://crowdsecurity.github.io/helm-charts
helm install crowdsec crowdsec/crowdsec -f helm-values/crowdsec-values.yaml

# Install AdGuard Home
helm repo add adguard https://charts.adguard.com
helm install adguard adguard/adguard-home -f helm-values/adguard-values.yaml
```

## Applications

### Portainer
- **Purpose**: Container management UI
- **Access**: Check service after deployment
- **Note**: Includes RBAC ClusterRoleBinding fix for proper permissions

### Heimdall
- **Purpose**: Application dashboard
- **Persistence**: hostPath at `/mnt/apps/heimdall`
- **Note**: Ensure the host path exists before deployment

### n8n
- **Purpose**: Workflow automation platform
- **Features**: API integrations and automation

### CrowdSec
- **Purpose**: Security automation and threat detection
- **Configuration**: See `helm-values/crowdsec-values.yaml`

### AdGuard Home
- **Purpose**: Network-wide ad blocking
- **Configuration**: See `helm-values/adguard-values.yaml`

## Usage

After installation, access the applications through their respective services:

```bash
# List all services
kubectl get services --all-namespaces

# Check pod status
kubectl get pods --all-namespaces

# Port forward to access locally (example)
kubectl port-forward -n portainer svc/portainer 9000:9000
```

### Access URLs

Assuming your server IP is `192.168.1.200` (replace with your actual IP):

- **Portainer**: http://192.168.1.200:30777
- **Heimdall**: http://192.168.1.200:30088
- **n8n**: http://192.168.1.200:30080
- **Web Demo**: http://192.168.1.200:30090

## GitOps Workflow

This repository is designed to serve as the **Source of Truth** for your Kubernetes deployments using GitOps principles via Portainer.

### What is GitOps?

GitOps is a modern deployment methodology where:
- Git repository = Single source of truth for infrastructure
- Changes to manifests trigger automatic deployments
- Rollbacks are as simple as reverting a Git commit
- Full audit trail of who changed what and when

### Setting Up GitOps with Portainer

1. **Access Portainer** web interface (http://YOUR_SERVER_IP:30777)

2. **Navigate to Stacks** (left sidebar) → **+ Add stack**

3. **Select "Repository" as the build method**

4. **Configure the Git connection**:
   ```
   Name: k8s-dev-gitops
   Repository URL: https://github.com/YOUR_USERNAME/k8s-dev
   Repository reference: refs/heads/main (or master)
   Manifest path: manifests/web-demo/demo-app.yaml
   Authentication: 
     - Public repos: Leave disabled
     - Private repos: Enable and add Personal Access Token
   ```

5. **Enable GitOps updates**:
   - Toggle **"GitOps updates"** to ON
   - **Mechanism**: Select "Polling" (checks for changes periodically)
   - **Fetch interval**: 5m (checks every 5 minutes)
   - **Force redeployment**: Enable (ensures changes are applied)

6. **Deploy**: Click the blue "Deploy the stack" button

### How It Works

Once configured:

1. You make changes to YAML files in this repository
2. Commit and push to GitHub
3. Portainer polls the repository every 5 minutes
4. When changes are detected, Portainer automatically applies them to your cluster
5. You can view the deployment status in real-time through Portainer's UI

### GitOps Best Practices

- **Branch Strategy**: Use `main` for production, `dev` for testing
- **Pull Requests**: Review changes before merging to main
- **Atomic Commits**: One logical change per commit
- **Meaningful Messages**: "Add CrowdSec deployment" not "update stuff"
- **Testing**: Test manifests locally before pushing:
  ```bash
  kubectl apply --dry-run=client -f manifests/your-app.yaml
  ```

### Webhook Alternative (Advanced)

For instant deployments instead of polling:

1. In Portainer, note the webhook URL when enabling GitOps
2. In GitHub: Repository → Settings → Webhooks → Add webhook
3. Paste Portainer's webhook URL
4. Content type: `application/json`
5. Events: Select "Just the push event"

**Note**: Webhooks require Portainer to be accessible from the internet. In home labs behind CGNAT, use Tailscale or polling instead.

## Troubleshooting

### Portainer RBAC Issues
If Portainer cannot access cluster resources, verify the ClusterRoleBinding is created:

```bash
kubectl get clusterrolebinding portainer
```

### Heimdall Persistence
Ensure the host path exists:

```bash
sudo mkdir -p /mnt/apps/heimdall
sudo chown -R 1000:1000 /mnt/apps/heimdall
```

## Security Considerations

### For Production Use

If adapting this project for production, consider:

1. **Network Security**:
   - Use NetworkPolicies to restrict pod-to-pod communication
   - Implement ingress with TLS/SSL certificates (Let's Encrypt)
   - Deploy behind a firewall with strict rules
   - Use VPN (like Tailscale/WireGuard) for remote access instead of exposing services

2. **Secrets Management**:
   - Use Kubernetes Secrets or external secret managers (Vault, Sealed Secrets)
   - Never store credentials in Git repositories
   - Rotate credentials regularly

3. **Access Control**:
   - Review and restrict RBAC permissions (the cluster-admin role is overly permissive)
   - Implement Pod Security Standards/Policies
   - Enable audit logging

4. **Container Security**:
   - Scan images for vulnerabilities (Trivy, Clair)
   - Use specific image tags instead of `latest`
   - Run containers as non-root users
   - Implement resource limits and quotas

5. **Monitoring & Updates**:
   - Deploy security monitoring (CrowdSec, Falco)
   - Keep Kubernetes and applications updated
   - Monitor logs for suspicious activity
   - Implement backup strategies

### Responsible Disclosure

If you discover security vulnerabilities in these configurations, please report them responsibly via GitHub Issues (without disclosing exploit details publicly).

## Contributing

Feel free to submit issues and enhancement requests! Please follow security best practices when contributing.

## License

This project is provided as-is for educational and development purposes. No warranty is provided. Use at your own risk.