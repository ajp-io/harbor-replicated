#!/bin/bash
set -euo pipefail

echo "=== Harbor KOTS Installation Test ==="
echo "Starting at: $(date)"

# Configuration
CUSTOMER_NAME="GitHub CI"
NAMESPACE="harbor-enterprise"
APP_NAME="harbor-enterprise"
SHARED_PASSWORD="TestAdminPassword123!"

# Validate required environment variables
if [[ -z "${TEST_VERSION:-}" ]]; then
    echo "❌ TEST_VERSION environment variable is required"
    exit 1
fi

if [[ -z "${REPLICATED_API_TOKEN:-}" ]]; then
    echo "❌ REPLICATED_API_TOKEN environment variable is required"
    exit 1
fi

echo "Installing KOTS for version: ${TEST_VERSION}"

# Install KOTS CLI
echo "Installing KOTS CLI..."
curl https://kots.io/install | bash

# Verify KOTS installation
echo "Verifying KOTS installation..."
kubectl kots version

# Download license using Replicated CLI (more reliable than curl API)
echo "Downloading license for customer: ${CUSTOMER_NAME}..."
replicated customer download-license --customer "${CUSTOMER_NAME}" > /tmp/license.yaml

echo "License downloaded successfully"

# Verify config values file exists
if [[ ! -f "/tmp/config-values.yaml" ]]; then
    echo "❌ Config values file not found at /tmp/config-values.yaml"
    exit 1
fi

echo "Config values file verified"

# Note: KOTS will create the namespace automatically, so we don't need to create it manually

# Install application using KOTS
echo "Installing ${APP_NAME} with KOTS..."
echo "This may take several minutes..."

kubectl kots install ${APP_NAME}/unstable \
  --shared-password "${SHARED_PASSWORD}" \
  --license-file /tmp/license.yaml \
  --config-values /tmp/config-values.yaml \
  --namespace ${NAMESPACE} \
  --no-port-forward \
  --wait-duration 10m

echo "KOTS installation complete! Verifying deployments..."

# Wait for PostgreSQL StatefulSet first (dependencies)
echo "Waiting for PostgreSQL StatefulSet to have ready replicas..."
kubectl wait statefulset/harbor-database --for=jsonpath='{.status.readyReplicas}'=1 -n ${NAMESPACE} --timeout=300s

echo "Waiting for Redis StatefulSet to have ready replicas..."
kubectl wait statefulset/harbor-redis --for=jsonpath='{.status.readyReplicas}'=1 -n ${NAMESPACE} --timeout=300s

echo "Waiting for Trivy StatefulSet to have ready replicas..."
kubectl wait statefulset/harbor-trivy --for=jsonpath='{.status.readyReplicas}'=1 -n ${NAMESPACE} --timeout=300s

# Wait for Deployments (Harbor depends on database/cache)
echo "Waiting for Harbor Core deployment to be available..."
kubectl wait deployment/harbor-core --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Portal deployment to be available..."
kubectl wait deployment/harbor-portal --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Registry deployment to be available..."
kubectl wait deployment/harbor-registry --for=condition=available -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Jobservice deployment to be available..."
kubectl wait deployment/harbor-jobservice --for=condition=available -n ${NAMESPACE} --timeout=300s

# Wait for Services to have endpoints (confirms they have healthy backends)
echo "Waiting for PostgreSQL service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/harbor-database -n ${NAMESPACE} --timeout=300s

echo "Waiting for Redis service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/harbor-redis -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Core service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/harbor-core -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Portal service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/harbor-portal -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Registry service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/harbor-registry -n ${NAMESPACE} --timeout=300s

echo "Waiting for Harbor Jobservice service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/harbor-jobservice -n ${NAMESPACE} --timeout=300s

echo "Waiting for Trivy service to have endpoints..."
kubectl wait --for=jsonpath='{.subsets}' endpoints/harbor-trivy -n ${NAMESPACE} --timeout=300s

echo "All resources verified and ready!"

# Show final status
echo "Checking final deployment status..."
kubectl get deployment,statefulset,service -n ${NAMESPACE} | grep harbor

echo "Testing Harbor UI accessibility through KOTS admin console..."
# Start admin console in background
kubectl kots admin-console --namespace ${NAMESPACE} &
KOTS_PID=$!

# Wait for port forward to establish
echo "Waiting for admin console port forward to establish..."
sleep 15

# Test UI accessibility
echo "Testing Harbor UI at localhost:30002..."
if curl -f -s http://localhost:30002 > /dev/null 2>&1; then
    echo "✅ Harbor UI is accessible through KOTS admin console"
else
    echo "❌ Harbor UI not accessible through KOTS admin console"
    kill $KOTS_PID || true
    exit 1
fi

# Cleanup admin console
echo "Cleaning up admin console port forward..."
kill $KOTS_PID || true
sleep 2

echo "Cluster verification complete!"

echo "=== Harbor KOTS Installation Test PASSED ==="
echo "Completed at: $(date)"