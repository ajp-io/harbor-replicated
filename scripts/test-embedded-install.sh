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

echo "✅ Harbor will be accessible at: https://${HOSTNAME}"

echo "Updating config values with ingress hostname..."
# Replace harbor.local with actual hostname using a more reliable approach
ESCAPED_HOSTNAME=$(printf '%s\n' "$HOSTNAME" | sed 's/[[\.*^$()+?{|]/\\&/g')
sed -i "s/harbor\\.local/$ESCAPED_HOSTNAME/g" /tmp/config-values.yaml

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

# Wait for Harbor to deploy asynchronously after EC installation
echo "Waiting 90 seconds for Harbor resources to deploy asynchronously..."
sleep 90

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

echo "Waiting for Replicated SDK deployment to be available..."
$KUBECTL wait deployment/replicated --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for Replicated SDK service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.subsets}' endpoints/replicated -n kotsadm --timeout=300s

echo "All resources verified and ready!"

# Verify cert-manager
echo "Checking cert-manager deployment..."
$KUBECTL get deployment/cert-manager -n kotsadm || {
    echo "❌ cert-manager deployment not found"
    exit 1
}

echo "Waiting for cert-manager to be available..."
$KUBECTL wait deployment/cert-manager --for=condition=available -n kotsadm --timeout=300s

echo "Checking cert-manager-webhook deployment..."
$KUBECTL get deployment/cert-manager-webhook -n kotsadm || {
    echo "❌ cert-manager-webhook deployment not found"
    exit 1
}

echo "Waiting for cert-manager-webhook to be available..."
$KUBECTL wait deployment/cert-manager-webhook --for=condition=available -n kotsadm --timeout=300s

echo "Checking cert-manager-cainjector deployment..."
$KUBECTL get deployment/cert-manager-cainjector -n kotsadm || {
    echo "❌ cert-manager-cainjector deployment not found"
    exit 1
}

echo "Waiting for cert-manager-cainjector to be available..."
$KUBECTL wait deployment/cert-manager-cainjector --for=condition=available -n kotsadm --timeout=300s

# Verify NGINX Ingress Controller
echo "Checking NGINX Ingress Controller..."
$KUBECTL get deployment/ingress-nginx-controller -n kotsadm || {
    echo "❌ NGINX Ingress Controller not found"
    exit 1
}

echo "Waiting for NGINX Ingress Controller to be available..."
$KUBECTL wait deployment/ingress-nginx-controller --for=condition=available -n kotsadm --timeout=300s

# Check cert-manager resources
echo "Checking ClusterIssuer for Let's Encrypt..."
$KUBECTL get clusterissuer letsencrypt-prod || {
    echo "❌ Let's Encrypt ClusterIssuer not found"
    exit 1
}

echo "Checking Certificate resource for Harbor..."
$KUBECTL get certificate -n kotsadm | grep harbor || {
    echo "❌ Harbor Certificate resource not found"
    exit 1
}

# Check ingress resources
echo "Checking Harbor Ingress resources..."
$KUBECTL get ingress -n kotsadm | grep harbor || {
    echo "❌ Harbor Ingress resource not found"
    exit 1
}

# Validate Let's Encrypt certificate status
echo "Checking Let's Encrypt certificate status..."
CERT_NAME=$($KUBECTL get certificate -n kotsadm -o name | grep harbor | head -1 | cut -d'/' -f2)
if [[ -n "$CERT_NAME" ]]; then
    echo "Found certificate: $CERT_NAME"
    $KUBECTL describe certificate "$CERT_NAME" -n kotsadm | grep -E "(Status|Ready|Message)" || true

    # Check if certificate is ready
    if $KUBECTL get certificate "$CERT_NAME" -n kotsadm -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
        echo "✅ Let's Encrypt certificate is ready"
    else
        echo "⚠️  Let's Encrypt certificate is not ready yet"
        echo "Certificate status:"
        $KUBECTL get certificate "$CERT_NAME" -n kotsadm -o yaml | grep -A10 "status:"
    fi
else
    echo "❌ No Harbor certificate found"
fi

# Test Harbor UI accessibility via HTTPS ingress
echo "Testing Harbor UI accessibility via HTTPS ingress at: https://${HOSTNAME}"
for i in {1..10}; do
    echo "Attempt $i/10: Testing Harbor UI via HTTPS..."
    if curl -f -s -I -k "https://${HOSTNAME}" | grep -q "HTTP/[0-9.]\+ 200"; then
        echo "✅ Harbor UI is accessible via HTTPS ingress!"

        # Test with valid certificate (no -k flag)
        echo "Testing certificate validity..."
        if curl -f -s -I "https://${HOSTNAME}" | grep -q "HTTP/[0-9.]\+ 200"; then
            echo "✅ Harbor UI accessible with valid Let's Encrypt certificate!"
        else
            echo "⚠️  Harbor UI accessible but certificate may not be valid"
        fi
        break
    elif [[ $i -eq 10 ]]; then
        echo "❌ Harbor UI not accessible via HTTPS after 10 attempts"
        echo "Debugging ingress configuration..."
        $KUBECTL get ingress -n kotsadm -o yaml
        $KUBECTL get service -n ingress-nginx
        exit 1
    else
        echo "Harbor UI not ready yet, waiting 30 seconds..."
        sleep 30
    fi
done

# Test HTTP to HTTPS redirect
echo "Testing HTTP to HTTPS redirect..."
if curl -s -I "http://${HOSTNAME}" | grep -q "Location: https://"; then
    echo "✅ HTTP to HTTPS redirect is working!"
else
    echo "⚠️  HTTP to HTTPS redirect may not be configured properly"
fi

echo "Cluster verification complete!"

echo "=== Harbor Embedded Cluster Installation Test PASSED ==="
echo "✅ Harbor is accessible at: https://${HOSTNAME}"
echo "Completed at: $(date)"