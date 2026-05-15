#!/bin/bash
# 18-install-rancher.sh -- Install Rancher on the k3s cluster via Helm
#
# Installs:
#   1. cert-manager (Rancher prerequisite -- manages TLS certificates)
#   2. Rancher (in cattle-system namespace)
#
# Rancher is exposed via NodePort since servicelb is disabled.
# Access: https://<any-node-ip>:<nodeport>
# The self-signed certificate will show a browser warning -- that's normal.
#
# Run from your Mac with KUBECONFIG set:
#   export KUBECONFIG=~/.kube/homelab.yaml
#   bash 18-install-rancher.sh
#
# Requirements:
#   - helm installed (brew install helm)
#   - kubectl configured (KUBECONFIG=~/.kube/homelab.yaml)
#   - k3s cluster running with all nodes Ready

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

CERT_MANAGER_VERSION="v1.17.2"
RANCHER_CHANNEL="latest"            # 'latest' supports k8s 1.35+; 'stable' is behind
RANCHER_VERSION=""                  # empty = latest in channel
RANCHER_HOSTNAME="rancher.homelab"  # used in the TLS cert -- add to /etc/hosts

# Which node IP to use for NodePort access (m-k3s-server)
SERVER_IP="10.0.10.110"

echo "=== [18-install-rancher] Start ==="
echo "    cert-manager : ${CERT_MANAGER_VERSION}"
echo "    Rancher      : channel=${RANCHER_CHANNEL} ${RANCHER_VERSION:+(${RANCHER_VERSION})}"
echo "    Hostname     : ${RANCHER_HOSTNAME}"
echo "    Access via   : https://${SERVER_IP}:<nodeport>"
echo ""

# ------------------------------------------------------------------------------
# 0. Verify prerequisites
# ------------------------------------------------------------------------------
echo "==> [0] Verify prerequisites"

if ! command -v helm &>/dev/null; then
    echo "ERROR: helm not found -- brew install helm"
    exit 1
fi
if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found"
    exit 1
fi
if ! kubectl get nodes &>/dev/null; then
    echo "ERROR: kubectl cannot reach cluster -- check KUBECONFIG"
    exit 1
fi

NODE_COUNT=$(kubectl get nodes --no-headers | grep -c Ready)
echo "    Cluster     : OK (${NODE_COUNT} nodes Ready)"
helm version --short
echo ""

# ------------------------------------------------------------------------------
# 1. cert-manager
# ------------------------------------------------------------------------------
echo "==> [1] Install cert-manager ${CERT_MANAGER_VERSION}"

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "${CERT_MANAGER_VERSION}" \
    --set crds.enabled=true \
    --wait \
    --timeout 5m

echo "    cert-manager: installed"

# Wait for cert-manager pods
echo -n "    Waiting for cert-manager pods"
for i in $(seq 1 30); do
    READY=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null \
        | grep -c "Running" || echo 0)
    if [[ "${READY}" -ge 3 ]]; then
        echo " -- ${READY} pods Running"
        break
    fi
    echo -n "."
    sleep 5
    [[ $i -eq 30 ]] && echo "" && echo "WARN: cert-manager pods not all ready"
done

# ------------------------------------------------------------------------------
# 2. Rancher
# ------------------------------------------------------------------------------
echo ""
echo "==> [2] Install Rancher ${RANCHER_VERSION}"

helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update
helm repo update rancher-latest

# Build version flag -- empty means latest available
VERSION_FLAG=""
[[ -n "${RANCHER_VERSION}" ]] && VERSION_FLAG="--version ${RANCHER_VERSION}"

helm upgrade --install rancher rancher-latest/rancher \
    --namespace cattle-system \
    --create-namespace \
    ${VERSION_FLAG} \
    --set hostname="${RANCHER_HOSTNAME}" \
    --set bootstrapPassword=admin \
    --set ingress.tls.source=rancher \
    --set service.type=NodePort \
    --wait \
    --timeout 10m

echo "    Rancher: installed"

# ------------------------------------------------------------------------------
# 3. Get NodePort
# ------------------------------------------------------------------------------
echo ""
echo "==> [3] Get Rancher NodePort"

RANCHER_PORT=$(kubectl get svc rancher -n cattle-system \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")

if [[ -z "${RANCHER_PORT}" ]]; then
    RANCHER_PORT=$(kubectl get svc rancher -n cattle-system \
        -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "unknown")
fi

echo "    NodePort: ${RANCHER_PORT}"

# ------------------------------------------------------------------------------
# 4. Wait for Rancher to be Ready
# ------------------------------------------------------------------------------
echo ""
echo "==> [4] Wait for Rancher deployment"

kubectl rollout status deployment/rancher -n cattle-system --timeout=10m

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  [18-install-rancher] Complete"
echo ""
echo "  Rancher UI  : https://${SERVER_IP}:${RANCHER_PORT}"
echo "  (also works on any other node IP with the same port)"
echo ""
echo "  First login:"
echo "    Username : admin"
echo "    Password : admin  (you will be prompted to change it)"
echo ""
echo "  Optional -- add to /etc/hosts on your Mac for nicer URL:"
echo "    echo '${SERVER_IP} ${RANCHER_HOSTNAME}' | sudo tee -a /etc/hosts"
echo "    Then access: https://${RANCHER_HOSTNAME}:${RANCHER_PORT}"
echo ""
echo "  Useful commands:"
echo "    kubectl get pods -n cattle-system"
echo "    kubectl get pods -n cert-manager"
echo "    kubectl logs -n cattle-system -l app=rancher -f"
echo "================================================================"
