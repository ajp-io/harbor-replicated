#!/bin/bash
set -euo pipefail

echo "=== Harbor Helm Installation Test (EKS + LoadBalancer + cert-manager) ==="
echo "Starting at: $(date)"

# Configuration
CUSTOMER_NAME="GitHub CI"
NAMESPACE="harbor-enterprise"
INGRESS_NGINX_NAMESPACE="ingress-nginx"
CERT_MANAGER_NAMESPACE="cert-manager"

# Validate required environment variables
if [[ -z "${TEST_VERSION:-}" ]]; then
    echo "❌ TEST_VERSION environment variable is required"
    exit 1
fi

if [[ -z "${REPLICATED_API_TOKEN:-}" ]]; then
    echo "❌ REPLICATED_API_TOKEN environment variable is required"
    exit 1
fi

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
  --set crds.enabled=true \
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
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb" \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="internet-facing" \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"="true" \
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

# Create Harbor values with actual LoadBalancer hostname
echo "Creating Harbor values with LoadBalancer hostname..."
cat > /tmp/harbor-values.yaml <<EOF
expose:
  type: ingress
  tls:
    certSource: secret
    secret:
      secretName: harbor-tls
  ingress:
    hosts:
      core: ${LB_HOSTNAME}
    className: nginx

externalURL: https://${LB_HOSTNAME}
EOF

echo "✅ Harbor values created"

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

# Wait for StatefulSets
echo "Waiting for PostgreSQL StatefulSet..."
kubectl wait statefulset/harbor-database --for=jsonpath='{.status.readyReplicas}'=1 -n ${NAMESPACE} --timeout=300s

echo "Waiting for Redis StatefulSet..."
kubectl wait statefulset/harbor-redis --for=jsonpath='{.status.readyReplicas}'=1 -n ${NAMESPACE} --timeout=300s

echo "Waiting for Trivy StatefulSet..."
kubectl wait statefulset/harbor-trivy --for=jsonpath='{.status.readyReplicas}'=1 -n ${NAMESPACE} --timeout=300s

# Wait for Deployments
echo "Waiting for Harbor Core deployment..."
kubectl wait deployment/harbor-core --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Portal deployment..."
kubectl wait deployment/harbor-portal --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Registry deployment..."
kubectl wait deployment/harbor-registry --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Jobservice deployment..."
kubectl wait deployment/harbor-jobservice --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Replicated SDK deployment..."
kubectl wait deployment/replicated --for=condition=available -n ${NAMESPACE} --timeout=300s

# Wait for ingress-nginx controller
echo "Waiting for ingress-nginx controller..."
kubectl wait deployment/ingress-nginx-controller --for=condition=available -n ${INGRESS_NGINX_NAMESPACE} --timeout=300s

# Verify Ingress created
echo "Verifying Harbor ingress..."
kubectl get ingress -n ${NAMESPACE}

echo "✅ All resources verified and ready"

# Verify images from proxy registry
echo "Verifying images are from proxy registry..."
HARBOR_CORE_IMAGE=$(kubectl get deployment harbor-core -n ${NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}')
REPLICATED_IMAGE=$(kubectl get deployment replicated -n ${NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}')

echo "Harbor Core image: ${HARBOR_CORE_IMAGE}"
echo "Replicated SDK image: ${REPLICATED_IMAGE}"

if [[ ! "${HARBOR_CORE_IMAGE}" =~ images\.alexparker\.info ]]; then
    echo "❌ Harbor Core image is not from proxy registry"
    exit 1
fi

if [[ ! "${REPLICATED_IMAGE}" =~ images\.alexparker\.info ]]; then
    echo "❌ Replicated SDK image is not from proxy registry"
    exit 1
fi

echo "✅ All images confirmed from proxy registry"

# Verify pull secret
echo "Verifying replicated-pull-secret..."
kubectl get secret replicated-pull-secret -n ${NAMESPACE}
echo "✅ Pull secret exists"

# Test Harbor UI accessibility
echo "Testing Harbor UI accessibility via LoadBalancer..."

# Wait for LoadBalancer health checks and DNS propagation
echo "Waiting for LoadBalancer health checks to pass and DNS to propagate..."
sleep 60

# Test with retry logic
echo "Testing Harbor UI at ${EXTERNAL_URL}..."
MAX_RETRIES=10
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  # Using -k because we're using self-signed certificates
  # (production environments would use a trusted CA or their own internal CA)
  if curl -k -f -s "${EXTERNAL_URL}" > /dev/null 2>&1; then
    echo "✅ Harbor UI is accessible via LoadBalancer"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "⏳ Retry $RETRY_COUNT/$MAX_RETRIES - waiting for DNS propagation and health checks..."
      sleep 15
    else
      echo "❌ Harbor UI not accessible after $MAX_RETRIES retries"
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
  fi
done

# Verify HTTP 200 status
HTTP_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" "${EXTERNAL_URL}")
echo "HTTP Status: ${HTTP_STATUS}"

if [[ "$HTTP_STATUS" == "200" ]]; then
  echo "✅ Harbor UI returned HTTP 200"
else
  echo "❌ Harbor UI returned HTTP ${HTTP_STATUS}"
  exit 1
fi

echo ""
echo "Final deployment status:"
kubectl get deployment,statefulset,service,ingress -n ${NAMESPACE}
echo ""
kubectl get service -n ${INGRESS_NGINX_NAMESPACE}

echo ""
echo "=== Harbor Helm Installation Test PASSED ==="
echo "Completed at: $(date)"
