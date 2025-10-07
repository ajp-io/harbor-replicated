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

# Support custom channel (default: unstable)
CHANNEL="${CHANNEL:-unstable}"
echo "Using channel: ${CHANNEL}"

curl -f "https://updates.alexparker.info/embedded/harbor-enterprise/${CHANNEL}/${TEST_VERSION}" \
  -H "Authorization: ${LICENSE_ID}" \
  -o harbor-enterprise-${CHANNEL}.tgz

echo "Extracting installation assets..."
tar -xzf harbor-enterprise-${CHANNEL}.tgz

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

# Helper function for polling resources with timeout
poll_for_resources() {
    local stage_name="$1"
    local timeout="$2"
    local check_command="$3"
    local poll_interval=5
    local elapsed=0

    echo "Stage: ${stage_name}"

    while [[ $elapsed -lt $timeout ]]; do
        echo "Checking for ${stage_name} (elapsed: ${elapsed}s/${timeout}s)..."

        if eval "$check_command"; then
            echo "✅ ${stage_name} detected after ${elapsed}s!"
            return 0
        fi

        if [[ $elapsed -ge $timeout ]]; then
            echo "⚠️  ${stage_name} timeout reached (${timeout}s) - proceeding anyway..."
            return 1
        fi

        echo "${stage_name} not ready yet, checking again in ${poll_interval}s..."
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    return 1
}

# Set kubectl path and kubeconfig
KUBECTL="sudo KUBECONFIG=/var/lib/embedded-cluster/k0s/pki/admin.conf /var/lib/embedded-cluster/bin/kubectl"

# Wait for components to deploy asynchronously after EC installation in correct order
echo "Waiting for components to deploy asynchronously in dependency order..."

# Stage 1: NGINX Ingress Controller (deployed first)
poll_for_resources "NGINX resources" 180 "$KUBECTL get deployment ingress-nginx-controller -n kotsadm >/dev/null 2>&1"

# Stage 2: cert-manager (deployed after NGINX)
poll_for_resources "cert-manager resources" 180 "$KUBECTL get deployment cert-manager -n kotsadm >/dev/null 2>&1 && $KUBECTL get deployment cert-manager-webhook -n kotsadm >/dev/null 2>&1 && $KUBECTL get deployment cert-manager-cainjector -n kotsadm >/dev/null 2>&1"

# Stage 3: Harbor (deployed after cert-manager)
poll_for_resources "Harbor resources" 180 "$KUBECTL get deployment harbor-core -n kotsadm >/dev/null 2>&1 && $KUBECTL get statefulset harbor-database -n kotsadm >/dev/null 2>&1 && $KUBECTL get statefulset harbor-redis -n kotsadm >/dev/null 2>&1"

# Wait for NGINX resources (deployed first)
echo "Waiting for NGINX Ingress Controller to be available..."
$KUBECTL wait deployment/ingress-nginx-controller --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for NGINX Ingress Controller service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=ingress-nginx-controller-admission -n kotsadm --timeout=300s

# Wait for cert-manager resources (deployed second)
echo "Waiting for cert-manager to be available..."
$KUBECTL wait deployment/cert-manager --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for cert-manager-webhook to be available..."
$KUBECTL wait deployment/cert-manager-webhook --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for cert-manager-cainjector to be available..."
$KUBECTL wait deployment/cert-manager-cainjector --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for cert-manager service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=cert-manager -n kotsadm --timeout=300s

echo "Waiting for cert-manager-webhook service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=cert-manager-webhook -n kotsadm --timeout=300s

# Wait for Harbor resources (deployed third)
echo "Waiting for PostgreSQL StatefulSet to have ready replicas..."
$KUBECTL wait statefulset/harbor-database --for=jsonpath='{.status.readyReplicas}'=1 -n kotsadm --timeout=300s

echo "Waiting for Redis StatefulSet to have ready replicas..."
$KUBECTL wait statefulset/harbor-redis --for=jsonpath='{.status.readyReplicas}'=1 -n kotsadm --timeout=300s

echo "Waiting for Trivy StatefulSet to have ready replicas..."
$KUBECTL wait statefulset/harbor-trivy --for=jsonpath='{.status.readyReplicas}'=1 -n kotsadm --timeout=300s

echo "Waiting for Harbor Core deployment to be available..."
$KUBECTL wait deployment/harbor-core --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for Harbor Portal deployment to be available..."
$KUBECTL wait deployment/harbor-portal --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for Harbor Registry deployment to be available..."
$KUBECTL wait deployment/harbor-registry --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for Harbor Jobservice deployment to be available..."
$KUBECTL wait deployment/harbor-jobservice --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for PostgreSQL service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=harbor-database -n kotsadm --timeout=300s

echo "Waiting for Redis service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=harbor-redis -n kotsadm --timeout=300s

echo "Waiting for Harbor Core service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=harbor-core -n kotsadm --timeout=300s

echo "Waiting for Harbor Portal service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=harbor-portal -n kotsadm --timeout=300s

echo "Waiting for Harbor Registry service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=harbor-registry -n kotsadm --timeout=300s

echo "Waiting for Harbor Jobservice service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=harbor-jobservice -n kotsadm --timeout=300s

echo "Waiting for Trivy service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=harbor-trivy -n kotsadm --timeout=300s

echo "Waiting for Replicated SDK deployment to be available..."
$KUBECTL wait deployment/replicated --for=condition=available -n kotsadm --timeout=300s

echo "Waiting for Replicated SDK service to have endpoints..."
$KUBECTL wait --for=jsonpath='{.endpoints[0]}' endpointslice -l kubernetes.io/service-name=replicated -n kotsadm --timeout=300s

echo "All resources verified and ready!"

# Check cert-manager resources
echo "Checking ClusterIssuer for Let's Encrypt..."
$KUBECTL get clusterissuer letsencrypt-staging || {
    echo "❌ Let's Encrypt staging ClusterIssuer not found"
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