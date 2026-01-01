# k8s-dev

A development environment for Kubernetes applications with pre-configured manifests and Helm values.

## Overview

This repository contains Kubernetes manifests and Helm values for deploying various applications in a development environment.

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

- Kubernetes cluster (1.19+)
- kubectl configured to access your cluster
- Helm 3.x (for Helm deployments)

## Installation

### Quick Start

Run the installation script:

```bash
chmod +x install.sh
./install.sh
```

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
kubectl get services

# Port forward to access locally (example)
kubectl port-forward svc/portainer 9000:9000
```

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

## Contributing

Feel free to submit issues and enhancement requests!

## License

This project is provided as-is for development purposes.