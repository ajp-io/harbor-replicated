#!/bin/bash
set -euo pipefail

echo "=== Harbor Embedded Cluster Installation Test ==="
echo "Starting at: $(date)"

# Validate required environment variables
if [[ -z "${LICENSE_ID:-}" ]]; then
    echo "❌ LICENSE_ID environment variable is required"
    exit 1
fi

if [[ -z "${HOSTNAME:-}" ]]; then
    echo "❌ HOSTNAME environment variable is required"
    exit 1
fi

echo "✅ Harbor will be accessible at: http://${HOSTNAME}"

echo "Updating config values with ingress hostname..."
cp test/config-values.yaml /tmp/config-values.yaml
sed -i "s/value: \"harbor.local\"/value: \"$HOSTNAME\"/" /tmp/config-values.yaml

echo "Downloading Embedded Cluster installation assets for version: ${TEST_VERSION}"

curl -f "https://updates.alexparker.info/embedded/harbor-enterprise/unstable/${TEST_VERSION}" \
  -H "Authorization: ${LICENSE_ID}" \
  -o harbor-enterprise-unstable.tgz

echo "Extracting installation assets..."
tar -xzf harbor-enterprise-unstable.tgz

echo "Verifying extracted files..."
ls -la

echo "Installing Harbor Enterprise with Embedded Cluster..."
echo "This may take several minutes..."

# This command blocks until installation completes
sudo ./harbor-enterprise install \
  --license license.yaml \
  --config-values /tmp/config-values.yaml \
  --admin-console-password "TestAdminPassword123!" \
  -y

echo "Installation complete! Verifying cluster and pods..."

# Set kubectl path and kubeconfig
KUBECTL="sudo KUBECONFIG=/var/lib/embedded-cluster/k0s/pki/admin.conf /var/lib/embedded-cluster/bin/kubectl"

echo "Checking cluster status..."
$KUBECTL get nodes

echo "Checking all resources..."
$KUBECTL get deployment,statefulset,service -n kotsadm | grep harbor || true

# Wait for StatefulSets first (dependencies)
echo "Waiting for PostgreSQL StatefulSet to have ready replicas..."
$KUBECTL wait statefulset/harbor-database --for=jsonpath='{.status.readyReplicas}'=1 -n kotsadm --timeout=300s

echo "Waiting for Redis StatefulSet to have ready replicas..."
$KUBECTL wait statefulset/harbor-redis --for=jsonpath='{.status.readyReplicas}'=1 -n kotsadm --timeout=300s

echo "Waiting for Trivy StatefulSet to have ready replicas..."
$KUBECTL wait statefulset/harbor-trivy --for=jsonpath='{.status.readyReplicas}'=1 -n kotsadm --timeout=300s

# Wait for Deployments (Harbor depends on database/cache)
echo "Waiting for Harbor Core deployment to be available..."
$KUBECTL wait deployment/harbor-core --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for Harbor Portal deployment to be available..."
$KUBECTL wait deployment/harbor-portal --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for Harbor Registry deployment to be available..."
$KUBECTL wait deployment/harbor-registry --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for Harbor Jobservice deployment to be available..."
$KUBECTL wait deployment/harbor-jobservice --for=condition=available -n kotsadm --timeout=300s

# Wait for Services to have endpoints (confirms they have healthy backends)
echo "Waiting for PostgreSQL service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.subsets}' endpoints/harbor-database -n kotsadm --timeout=300s

echo "Waiting for Redis service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.subsets}' endpoints/harbor-redis -n kotsadm --timeout=300s

echo "Waiting for Harbor Core service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.subsets}' endpoints/harbor-core -n kotsadm --timeout=300s

echo "Waiting for Harbor Portal service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.subsets}' endpoints/harbor-portal -n kotsadm --timeout=300s

echo "Waiting for Harbor Registry service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.subsets}' endpoints/harbor-registry -n kotsadm --timeout=300s

echo "Waiting for Harbor Jobservice service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.subsets}' endpoints/harbor-jobservice -n kotsadm --timeout=300s

echo "Waiting for Trivy service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.subsets}' endpoints/harbor-trivy -n kotsadm --timeout=300s

echo "All resources verified and ready!"

# Verify NGINX Ingress Controller
echo "Checking NGINX Ingress Controller..."
$KUBECTL get deployment/ingress-nginx-controller -n ingress-nginx || {
    echo "❌ NGINX Ingress Controller not found"
    exit 1
}

echo "Waiting for NGINX Ingress Controller to be available..."
$KUBECTL wait deployment/ingress-nginx-controller --for=condition=available -n ingress-nginx --timeout=300s

# Check ingress resources
echo "Checking Harbor Ingress resources..."
$KUBECTL get ingress -n kotsadm | grep harbor || {
    echo "❌ Harbor Ingress resource not found"
    exit 1
}

# Test Harbor UI accessibility via ingress
echo "Testing Harbor UI accessibility via ingress at: http://${HOSTNAME}"
for i in {1..10}; do
    echo "Attempt $i/10: Testing Harbor UI..."
    if curl -f -s -I "http://${HOSTNAME}" | grep -q "HTTP/[0-9.]\+ 200"; then
        echo "✅ Harbor UI is accessible via ingress!"
        break
    elif [[ $i -eq 10 ]]; then
        echo "❌ Harbor UI not accessible after 10 attempts"
        echo "Debugging ingress configuration..."
        $KUBECTL get ingress -n kotsadm -o yaml
        $KUBECTL get service -n ingress-nginx
        exit 1
    else
        echo "Harbor UI not ready yet, waiting 30 seconds..."
        sleep 30
    fi
done

echo "Cluster verification complete!"

echo "=== Harbor Embedded Cluster Installation Test PASSED ==="
echo "✅ Harbor is accessible at: http://${HOSTNAME}"
echo "Completed at: $(date)"