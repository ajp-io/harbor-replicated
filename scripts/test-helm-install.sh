#!/bin/bash
set -euo pipefail

# Load test helper library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"

test_header "Harbor Helm Installation Test (EKS + LoadBalancer + cert-manager)"

# Configuration
CUSTOMER_NAME="GitHub CI"
NAMESPACE="harbor-enterprise"
INGRESS_NGINX_NAMESPACE="ingress-nginx"
CERT_MANAGER_NAMESPACE="cert-manager"

# Validate required environment variables
validate_env_vars "TEST_VERSION" "REPLICATED_API_TOKEN" || exit 1

CHANNEL="${CHANNEL:-unstable}"
echo "Using channel: ${CHANNEL}"
echo "Installing Helm chart for version: ${TEST_VERSION}"

# Download license to get customer email and license ID
echo "Downloading license for customer: ${CUSTOMER_NAME}..."
replicated customer download-license --customer "${CUSTOMER_NAME}" > /tmp/license.yaml

CUSTOMER_EMAIL=$(yq eval '.spec.customerEmail' /tmp/license.yaml)
LICENSE_ID=$(yq eval '.spec.licenseID' /tmp/license.yaml)

if [[ -z "$CUSTOMER_EMAIL" || "$CUSTOMER_EMAIL" == "null" ]]; then
    echo "❌ Failed to get customer email from license file"
    exit 1
fi

if [[ -z "$LICENSE_ID" || "$LICENSE_ID" == "null" ]]; then
    echo "❌ Failed to get license ID from license file"
    exit 1
fi

echo "✅ Customer email: ${CUSTOMER_EMAIL}"
echo "✅ License ID retrieved"

# Login to Replicated registry
echo "Logging in to Replicated registry..."
echo "${LICENSE_ID}" | helm registry login charts.alexparker.info \
    --username "${CUSTOMER_EMAIL}" \
    --password-stdin

echo "✅ Logged in to Replicated registry"

# Get Harbor version from local Chart.yaml
HARBOR_VERSION=$(yq eval '.version' charts/harbor/Chart.yaml)

echo "Harbor chart version: ${HARBOR_VERSION}"

# Add upstream Helm repositories
echo "Adding upstream Helm repositories..."
helm repo add jetstack https://charts.jetstack.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install cert-manager from upstream
echo "Installing cert-manager from upstream Jetstack repository..."
helm install cert-manager jetstack/cert-manager \
  --version v1.16.2 \
  --namespace ${CERT_MANAGER_NAMESPACE} \
  --create-namespace \
  --values test/cert-manager-values.yaml \
  --wait \
  --timeout 5m

echo "✅ cert-manager installed"

# Wait for cert-manager webhooks to be ready
echo "Waiting for cert-manager webhooks to be ready..."
kubectl wait deployment/cert-manager-webhook --for=condition=available -n ${CERT_MANAGER_NAMESPACE} --timeout=300s

echo "✅ cert-manager webhooks ready"

# Create self-signed ClusterIssuer
echo "Creating self-signed ClusterIssuer..."
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

echo "✅ Self-signed ClusterIssuer created"

# Install ingress-nginx from upstream
echo "Installing ingress-nginx from upstream Kubernetes repository..."
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.11.3 \
  --namespace ${INGRESS_NGINX_NAMESPACE} \
  --create-namespace \
  --values test/ingress-nginx-values.yaml \
  --wait \
  --timeout 10m

echo "✅ ingress-nginx installed"

# Wait for LoadBalancer hostname
echo "Waiting for LoadBalancer to be provisioned..."
TIMEOUT=600
ELAPSED=0
INTERVAL=15

while [ $ELAPSED -lt $TIMEOUT ]; do
  LB_HOSTNAME=$(kubectl get service ingress-nginx-controller -n ${INGRESS_NGINX_NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

  if [[ -n "$LB_HOSTNAME" && "$LB_HOSTNAME" != "null" ]]; then
    echo "✅ LoadBalancer provisioned with hostname: ${LB_HOSTNAME}"
    EXTERNAL_URL="https://${LB_HOSTNAME}"
    break
  fi

  echo "⏳ Waiting for LoadBalancer... (${ELAPSED}s/${TIMEOUT}s)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ -z "$LB_HOSTNAME" || "$LB_HOSTNAME" == "null" ]]; then
  echo "❌ LoadBalancer failed to provision after ${TIMEOUT}s"
  kubectl describe service ingress-nginx-controller -n ${INGRESS_NGINX_NAMESPACE}
  exit 1
fi

echo "External URL will be: ${EXTERNAL_URL}"

# Create Harbor namespace
echo "Creating ${NAMESPACE} namespace..."
kubectl create namespace ${NAMESPACE}

# Create Certificate resource for LoadBalancer hostname (self-signed)
echo "Creating Certificate resource for ${LB_HOSTNAME} (self-signed via cert-manager)..."
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: harbor-tls
  namespace: ${NAMESPACE}
spec:
  secretName: harbor-tls
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  dnsNames:
    - ${LB_HOSTNAME}
EOF

echo "Waiting for cert-manager to issue certificate..."
kubectl wait certificate/harbor-tls --for=condition=Ready -n ${NAMESPACE} --timeout=300s

echo "✅ Certificate issued and ready"

# Prepare Harbor values with actual LoadBalancer hostname
echo "Preparing Harbor values with LoadBalancer hostname..."
cp test/harbor-values.yaml /tmp/harbor-values.yaml
yq eval -i ".expose.ingress.hosts.core = \"${LB_HOSTNAME}\"" /tmp/harbor-values.yaml
yq eval -i ".externalURL = \"https://${LB_HOSTNAME}\"" /tmp/harbor-values.yaml

echo "✅ Harbor values prepared with dynamic hostname"

# Install Harbor from Replicated registry
echo "Installing Harbor from Replicated registry..."
helm install harbor \
  oci://charts.alexparker.info/harbor-enterprise/${CHANNEL}/harbor \
  --version ${HARBOR_VERSION} \
  --namespace ${NAMESPACE} \
  --values /tmp/harbor-values.yaml \
  --username "${CUSTOMER_EMAIL}" \
  --password "${LICENSE_ID}" \
  --wait \
  --timeout 10m

echo "✅ Harbor installation complete"

# Verify pod status
echo "Verifying pod status..."
kubectl get pods -n ${NAMESPACE}

# Verify all Harbor resources (adds endpoint checks that Helm test was missing)
verify_harbor_installation "kubectl" "${NAMESPACE}"

# Verify ingress-nginx is ready (adds endpoint checks for consistency)
verify_nginx_ingress_installation "kubectl" "${INGRESS_NGINX_NAMESPACE}"

# Verify Ingress created
echo "Verifying Harbor ingress..."
kubectl get ingress -n ${NAMESPACE}

# Test Harbor UI accessibility
echo "Testing Harbor UI accessibility via LoadBalancer..."

# Wait for LoadBalancer health checks and DNS propagation
echo "Waiting for LoadBalancer health checks to pass and DNS to propagate..."
sleep 60

# Test with retry logic (using -k for self-signed certificates)
if ! test_harbor_ui "${EXTERNAL_URL}" 10 15 "-k -f -s"; then
    echo ""
    echo "=== Debugging Information ==="
    echo "Ingress details:"
    kubectl describe ingress -n ${NAMESPACE}
    echo ""
    echo "LoadBalancer service:"
    kubectl describe service ingress-nginx-controller -n ${INGRESS_NGINX_NAMESPACE}
    echo ""
    echo "Nginx controller logs:"
    kubectl logs -n ${INGRESS_NGINX_NAMESPACE} -l app.kubernetes.io/name=ingress-nginx --tail=50
    echo ""
    echo "Certificate status:"
    kubectl describe certificate harbor-tls -n ${NAMESPACE}
    exit 1
fi

echo ""
echo "Final deployment status:"
kubectl get deployment,statefulset,service,ingress -n ${NAMESPACE}
echo ""
kubectl get service -n ${INGRESS_NGINX_NAMESPACE}

echo ""
test_footer "Harbor Helm Installation Test"
