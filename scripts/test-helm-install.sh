#!/bin/bash
set -euo pipefail

echo "=== Harbor Helm Installation Test ==="
echo "Starting at: $(date)"

# Configuration
CUSTOMER_NAME="GitHub CI"           # HARDCODED - matches KOTS test
NAMESPACE="harbor-enterprise"       # HARDCODED - matches KOTS test namespace
EXTERNAL_URL="http://localhost:8080"  # HARDCODED - port-forward target

# Validate required environment variables
if [[ -z "${TEST_VERSION:-}" ]]; then
    echo "❌ TEST_VERSION environment variable is required"
    exit 1
fi

if [[ -z "${REPLICATED_API_TOKEN:-}" ]]; then
    echo "❌ REPLICATED_API_TOKEN environment variable is required"
    exit 1
fi

# Support custom channel (default: unstable)
CHANNEL="${CHANNEL:-unstable}"
echo "Using channel: ${CHANNEL}"
echo "Installing Helm chart for version: ${TEST_VERSION}"

# Get customer details using inspect (cleaner than ls + filter)
echo "Getting customer credentials for: ${CUSTOMER_NAME}..."
CUSTOMER_JSON=$(replicated customer inspect --customer "${CUSTOMER_NAME}" --output json)

CUSTOMER_EMAIL=$(echo "$CUSTOMER_JSON" | jq -r '.email')
LICENSE_ID=$(echo "$CUSTOMER_JSON" | jq -r '.license_id')

if [[ -z "$CUSTOMER_EMAIL" || "$CUSTOMER_EMAIL" == "null" ]]; then
    echo "❌ Failed to get customer email for ${CUSTOMER_NAME}"
    exit 1
fi

if [[ -z "$LICENSE_ID" || "$LICENSE_ID" == "null" ]]; then
    echo "❌ Failed to get license ID for ${CUSTOMER_NAME}"
    exit 1
fi

echo "✅ Customer email: ${CUSTOMER_EMAIL}"
# DO NOT output LICENSE_ID - it's sensitive

# Login to Replicated registry
echo "Logging in to Replicated registry..."
echo "${LICENSE_ID}" | helm registry login registry.replicated.com \
    --username "${CUSTOMER_EMAIL}" \
    --password-stdin

echo "✅ Logged in to Replicated registry"

# Verify test values file exists
if [[ ! -f "test/helm-values.yaml" ]]; then
    echo "❌ Test values file not found at test/helm-values.yaml"
    exit 1
fi

echo "✅ Test values file verified"

# Install Harbor via Helm from Replicated registry
echo "Installing Harbor from Replicated registry..."
echo "Chart: oci://registry.replicated.com/harbor-enterprise/${CHANNEL}/harbor"
echo "Version: 1.18.0"  # HARDCODED - Harbor chart version from Chart.yaml
echo "Values: test/helm-values.yaml"

helm install harbor \
  oci://registry.replicated.com/harbor-enterprise/${CHANNEL}/harbor \
  --version 1.18.0 \
  --namespace ${NAMESPACE} \
  --create-namespace \
  --values test/helm-values.yaml \
  --username "${CUSTOMER_EMAIL}" \
  --password "${LICENSE_ID}" \
  --wait \
  --timeout 10m

echo "✅ Helm installation complete!"

# Verify all pods are running
echo "Verifying pod status..."
kubectl get pods -n ${NAMESPACE}

# Wait for StatefulSets (database dependencies)
echo "Waiting for PostgreSQL StatefulSet to have ready replicas..."
kubectl wait statefulset/harbor-database --for=jsonpath='{.status.readyReplicas}'=1 -n ${NAMESPACE} --timeout=300s

echo "Waiting for Redis StatefulSet to have ready replicas..."
kubectl wait statefulset/harbor-redis --for=jsonpath='{.status.readyReplicas}'=1 -n ${NAMESPACE} --timeout=300s

echo "Waiting for Trivy StatefulSet to have ready replicas..."
kubectl wait statefulset/harbor-trivy --for=jsonpath='{.status.readyReplicas}'=1 -n ${NAMESPACE} --timeout=300s

# Wait for Deployments
echo "Waiting for Harbor Core deployment to be available..."
kubectl wait deployment/harbor-core --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Portal deployment to be available..."
kubectl wait deployment/harbor-portal --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Registry deployment to be available..."
kubectl wait deployment/harbor-registry --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Jobservice deployment to be available..."
kubectl wait deployment/harbor-jobservice --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Nginx deployment to be available..."
kubectl wait deployment/harbor-nginx --for=condition=available -n ${NAMESPACE} --timeout=300s

# Wait for Replicated SDK
echo "Waiting for Replicated SDK deployment to be available..."
kubectl wait deployment/replicated --for=condition=available -n ${NAMESPACE} --timeout=300s

# Wait for Services to have endpoints
echo "Waiting for Harbor service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/harbor -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Core service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/harbor-core -n ${NAMESPACE} --timeout=300s

echo "Waiting for Replicated SDK service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/replicated -n ${NAMESPACE} --timeout=300s

echo "All resources verified and ready!"

# Verify images are from proxy registry
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

# Verify pull secret exists
echo "Verifying replicated-pull-secret was created..."
kubectl get secret replicated-pull-secret -n ${NAMESPACE}

echo "✅ Pull secret exists"

# Test Harbor UI accessibility
echo "Testing Harbor UI accessibility..."

# Start port-forward in background
kubectl port-forward -n ${NAMESPACE} service/harbor 8080:80 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!

# Wait for port forward to establish
echo "Waiting for port forward to establish..."
sleep 10

# Test UI accessibility using the same pattern as other tests
echo "Testing Harbor UI at ${EXTERNAL_URL}..."
if curl -f -s ${EXTERNAL_URL} > /dev/null 2>&1; then
    echo "✅ Harbor UI is accessible"
else
    echo "❌ Harbor UI not accessible"
    kill $PORT_FORWARD_PID || true
    exit 1
fi

# Verify HTTP 200 status
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${EXTERNAL_URL})
echo "HTTP Status: ${HTTP_STATUS}"

if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "❌ Harbor UI returned HTTP ${HTTP_STATUS}"
    kill $PORT_FORWARD_PID || true
    exit 1
fi

echo "✅ Harbor UI returned HTTP 200"

# Cleanup port forward
kill $PORT_FORWARD_PID || true
sleep 2

echo "Final deployment status:"
kubectl get deployment,statefulset,service -n ${NAMESPACE}

echo "=== Harbor Helm Installation Test PASSED ==="
echo "Completed at: $(date)"
