#!/bin/bash
# Harbor Test Helper Library
# Shared functions for KOTS, Embedded Cluster, and Helm installation tests

set -euo pipefail

#######################################
# Environment Validation
#######################################

# Validates that required environment variables are set
# Arguments:
#   $@: Variable names to validate
# Returns:
#   0 if all variables are set, 1 otherwise
# Example:
#   validate_env_vars "TEST_VERSION" "REPLICATED_API_TOKEN" || exit 1
validate_env_vars() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Missing required environment variables: ${missing[*]}"
        return 1
    fi
    return 0
}

#######################################
# Test Output Formatting
#######################################

# Prints test header with timestamp
# Arguments:
#   $1: Test name
# Example:
#   test_header "Harbor KOTS Installation Test"
test_header() {
    local test_name="$1"
    echo "=== $test_name ==="
    echo "Starting at: $(date)"
}

# Prints test footer with timestamp
# Arguments:
#   $1: Test name
# Example:
#   test_footer "Harbor KOTS Installation Test"
test_footer() {
    local test_name="$1"
    echo "=== $test_name PASSED ==="
    echo "Completed at: $(date)"
}

#######################################
# Installation Verification (High-Level)
#######################################

# Verifies complete Harbor installation (resources + endpoints + status)
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "harbor-enterprise")
# Returns:
#   0 on success
# Example:
#   verify_harbor_installation "kubectl" "harbor-enterprise"
#   verify_harbor_installation "$KUBECTL" "kotsadm"
verify_harbor_installation() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-harbor-enterprise}"

    echo "Verifying Harbor installation..."

    # Wait for resources in dependency order
    wait_for_harbor_resources "$kubectl_cmd" "$namespace"

    # Check service endpoints
    wait_for_harbor_endpoints "$kubectl_cmd" "$namespace"

    # Display final status
    display_harbor_status "$kubectl_cmd" "$namespace"

    echo "✅ Harbor installation verified!"
}

# Verifies cert-manager installation (deployments + endpoints)
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "cert-manager")
# Returns:
#   0 on success
# Example:
#   verify_cert_manager_installation "kubectl" "cert-manager"
#   verify_cert_manager_installation "$KUBECTL" "kotsadm"
verify_cert_manager_installation() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-cert-manager}"

    echo "Verifying cert-manager installation..."

    # Wait for deployments
    wait_for_cert_manager "$kubectl_cmd" "$namespace"

    # Check service endpoints
    wait_for_cert_manager_endpoints "$kubectl_cmd" "$namespace"

    # Display final status
    echo ""
    echo "cert-manager status:"
    $kubectl_cmd get deployment,service -n "$namespace" -l app.kubernetes.io/name=cert-manager || true
    echo ""

    echo "✅ cert-manager installation verified!"
}

# Verifies NGINX Ingress Controller installation (deployment + endpoints)
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "ingress-nginx")
# Returns:
#   0 on success
# Example:
#   verify_nginx_ingress_installation "kubectl" "ingress-nginx"
#   verify_nginx_ingress_installation "$KUBECTL" "kotsadm"
verify_nginx_ingress_installation() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-ingress-nginx}"

    echo "Verifying NGINX Ingress Controller installation..."

    # Wait for deployment
    wait_for_nginx_ingress "$kubectl_cmd" "$namespace"

    # Check service endpoints
    wait_for_nginx_ingress_endpoints "$kubectl_cmd" "$namespace"

    # Display final status
    echo ""
    echo "NGINX Ingress Controller status:"
    $kubectl_cmd get deployment,service -n "$namespace" -l app.kubernetes.io/name=ingress-nginx || true
    echo ""

    echo "✅ NGINX Ingress Controller installation verified!"
}

#######################################
# Harbor Resource Waiting (Low-Level)
#######################################

# Waits for all Harbor resources to be ready in dependency order
# Note: Consider using verify_harbor_installation() for complete verification
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "harbor-enterprise")
# Returns:
#   0 on success
# Example:
#   wait_for_harbor_resources "kubectl" "harbor-enterprise"
#   wait_for_harbor_resources "$KUBECTL" "kotsadm"
wait_for_harbor_resources() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-harbor-enterprise}"

    echo "Waiting for Harbor resources in dependency order..."

    # Stage 1: StatefulSets (dependencies)
    echo "Stage 1: Waiting for StatefulSets..."
    echo "  Waiting for PostgreSQL StatefulSet to have ready replicas..."
    $kubectl_cmd wait statefulset/harbor-database \
        --for=jsonpath='{.status.readyReplicas}'=1 \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for Redis StatefulSet to have ready replicas..."
    $kubectl_cmd wait statefulset/harbor-redis \
        --for=jsonpath='{.status.readyReplicas}'=1 \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for Trivy StatefulSet to have ready replicas..."
    $kubectl_cmd wait statefulset/harbor-trivy \
        --for=jsonpath='{.status.readyReplicas}'=1 \
        -n "$namespace" \
        --timeout=300s

    # Stage 2: Deployments (depend on StatefulSets)
    echo "Stage 2: Waiting for Harbor Deployments..."
    echo "  Waiting for Harbor Core deployment to be available..."
    $kubectl_cmd wait deployment/harbor-core \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for Harbor Portal deployment to be available..."
    $kubectl_cmd wait deployment/harbor-portal \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for Harbor Registry deployment to be available..."
    $kubectl_cmd wait deployment/harbor-registry \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for Harbor Jobservice deployment to be available..."
    $kubectl_cmd wait deployment/harbor-jobservice \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    # Stage 3: Replicated SDK
    echo "Stage 3: Waiting for Replicated SDK..."
    echo "  Waiting for Replicated SDK deployment to be available..."
    $kubectl_cmd wait deployment/replicated \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "✅ All Harbor resources ready!"
}

# Waits for Harbor service endpoints using EndpointSlice
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "harbor-enterprise")
#   $3: include Replicated SDK endpoints (default: "true")
# Returns:
#   0 on success
# Example:
#   wait_for_harbor_endpoints "kubectl" "harbor-enterprise"
wait_for_harbor_endpoints() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-harbor-enterprise}"
    local include_sdk="${3:-true}"

    echo "Waiting for Harbor service endpoints..."

    local services=(
        "harbor-database"
        "harbor-redis"
        "harbor-core"
        "harbor-portal"
        "harbor-registry"
        "harbor-jobservice"
        "harbor-trivy"
    )

    for service in "${services[@]}"; do
        echo "  Waiting for ${service} service to have endpoints..."
        $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
            endpointslice \
            -l kubernetes.io/service-name="$service" \
            -n "$namespace" \
            --timeout=300s
    done

    if [[ "$include_sdk" == "true" ]]; then
        echo "  Waiting for Replicated SDK service to have endpoints..."
        $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
            endpointslice \
            -l kubernetes.io/service-name=replicated \
            -n "$namespace" \
            --timeout=300s
    fi

    echo "✅ All Harbor service endpoints ready!"
}

#######################################
# Infrastructure Component Waiting (Low-Level)
#######################################

# Waits for cert-manager components to be ready
# Note: Consider using verify_cert_manager_installation() for complete verification
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "cert-manager")
# Returns:
#   0 on success
# Example:
#   wait_for_cert_manager "kubectl" "cert-manager"
#   wait_for_cert_manager "$KUBECTL" "kotsadm"
wait_for_cert_manager() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-cert-manager}"

    echo "Waiting for cert-manager components..."

    echo "  Waiting for cert-manager to be available..."
    $kubectl_cmd wait deployment/cert-manager \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for cert-manager-webhook to be available..."
    $kubectl_cmd wait deployment/cert-manager-webhook \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for cert-manager-cainjector to be available..."
    $kubectl_cmd wait deployment/cert-manager-cainjector \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "✅ cert-manager ready!"
}

# Waits for cert-manager service endpoints using EndpointSlice
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "cert-manager")
# Returns:
#   0 on success
# Example:
#   wait_for_cert_manager_endpoints "kubectl" "cert-manager"
wait_for_cert_manager_endpoints() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-cert-manager}"

    echo "Waiting for cert-manager service endpoints..."

    echo "  Waiting for cert-manager service to have endpoints..."
    $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
        endpointslice \
        -l kubernetes.io/service-name=cert-manager \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for cert-manager-webhook service to have endpoints..."
    $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
        endpointslice \
        -l kubernetes.io/service-name=cert-manager-webhook \
        -n "$namespace" \
        --timeout=300s

    echo "✅ cert-manager service endpoints ready!"
}

# Waits for NGINX Ingress Controller to be ready
# Note: Consider using verify_nginx_ingress_installation() for complete verification
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "ingress-nginx")
# Returns:
#   0 on success
# Example:
#   wait_for_nginx_ingress "kubectl" "ingress-nginx"
#   wait_for_nginx_ingress "$KUBECTL" "kotsadm"
wait_for_nginx_ingress() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-ingress-nginx}"

    echo "Waiting for NGINX Ingress Controller..."

    echo "  Waiting for NGINX Ingress Controller to be available..."
    $kubectl_cmd wait deployment/ingress-nginx-controller \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "✅ NGINX Ingress Controller ready!"
}

# Waits for NGINX Ingress Controller service endpoints using EndpointSlice
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "ingress-nginx")
# Returns:
#   0 on success
# Example:
#   wait_for_nginx_ingress_endpoints "kubectl" "ingress-nginx"
wait_for_nginx_ingress_endpoints() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-ingress-nginx}"

    echo "Waiting for NGINX Ingress Controller service endpoints..."

    echo "  Waiting for NGINX Ingress Controller service to have endpoints..."
    $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
        endpointslice \
        -l kubernetes.io/service-name=ingress-nginx-controller-admission \
        -n "$namespace" \
        --timeout=300s

    echo "✅ NGINX Ingress Controller service endpoints ready!"
}

#######################################
# Harbor UI Testing
#######################################

# Tests Harbor UI accessibility with retry logic
# Arguments:
#   $1: URL to test
#   $2: maximum number of retries (default: 10)
#   $3: retry interval in seconds (default: 15)
#   $4: curl flags (default: "-k -f -s")
# Returns:
#   0 if UI is accessible, 1 otherwise
# Example:
#   test_harbor_ui "https://harbor.example.com" 10 30 "-k -f -s"
#   test_harbor_ui "http://localhost:30001" 5 3 "-f -s"
test_harbor_ui() {
    local url="$1"
    local max_retries="${2:-10}"
    local retry_interval="${3:-15}"
    local curl_flags="${4:--k -f -s}"

    echo "Testing Harbor UI accessibility at: $url"

    for ((i=1; i<=max_retries; i++)); do
        echo "Attempt $i/$max_retries: Testing Harbor UI..."

        # shellcheck disable=SC2086
        if curl $curl_flags "$url" > /dev/null 2>&1; then
            echo "✅ Harbor UI is accessible!"
            return 0
        elif [[ $i -eq $max_retries ]]; then
            echo "❌ Harbor UI not accessible after $max_retries attempts"
            return 1
        else
            echo "Harbor UI not ready yet, waiting ${retry_interval}s..."
            sleep "$retry_interval"
        fi
    done

    return 1
}

# Verifies Harbor UI returns HTTP 200 status
# Arguments:
#   $1: URL to test
#   $2: curl flags (default: "-k -s")
# Returns:
#   0 if HTTP 200, 1 otherwise
# Example:
#   verify_harbor_ui_status "https://harbor.example.com" "-k -s"
verify_harbor_ui_status() {
    local url="$1"
    local curl_flags="${2:--k -s}"
    local http_status

    echo "Verifying Harbor UI HTTP status..."

    # shellcheck disable=SC2086
    http_status=$(curl $curl_flags -o /dev/null -w "%{http_code}" "$url")
    echo "HTTP Status: ${http_status}"

    if [[ "$http_status" == "200" ]]; then
        echo "✅ Harbor UI returned HTTP 200"
        return 0
    else
        echo "❌ Harbor UI returned HTTP ${http_status}"
        return 1
    fi
}

#######################################
# Status Display
#######################################

# Displays final status of Harbor resources
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "harbor-enterprise")
# Example:
#   display_harbor_status "kubectl" "harbor-enterprise"
display_harbor_status() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-harbor-enterprise}"

    echo ""
    echo "Final deployment status:"
    $kubectl_cmd get deployment,statefulset,service,ingress -n "$namespace" | grep -E "harbor|replicated" || true
    echo ""
}

#######################################
# Resource Creation Polling
#######################################

# Waits for resources to be created before kubectl wait can be used
# Polls until a check command succeeds (used for Embedded Cluster async deployments)
# Arguments:
#   $1: Stage name (for logging)
#   $2: Timeout in seconds
#   $3: Check command to evaluate
# Returns:
#   0 if resources detected, 1 if timeout
# Example:
#   wait_for_resource_creation "NGINX resources" 180 "$KUBECTL get deployment ingress-nginx-controller -n kotsadm >/dev/null 2>&1"
wait_for_resource_creation() {
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
