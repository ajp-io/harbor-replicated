#!/bin/bash
# Smoke test for test-helpers.sh library
# Validates that all expected functions are defined

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo "=== Test Helpers Library Smoke Test ==="

# Test that all high-level functions are defined
declare -f verify_harbor_installation > /dev/null || { echo "❌ verify_harbor_installation not found"; exit 1; }
declare -f verify_cert_manager_installation > /dev/null || { echo "❌ verify_cert_manager_installation not found"; exit 1; }
declare -f verify_nginx_ingress_installation > /dev/null || { echo "❌ verify_nginx_ingress_installation not found"; exit 1; }

# Test low-level Harbor functions
declare -f wait_for_harbor_resources > /dev/null || { echo "❌ wait_for_harbor_resources not found"; exit 1; }
declare -f wait_for_harbor_endpoints > /dev/null || { echo "❌ wait_for_harbor_endpoints not found"; exit 1; }

# Test infrastructure functions
declare -f wait_for_cert_manager > /dev/null || { echo "❌ wait_for_cert_manager not found"; exit 1; }
declare -f wait_for_cert_manager_endpoints > /dev/null || { echo "❌ wait_for_cert_manager_endpoints not found"; exit 1; }
declare -f wait_for_nginx_ingress > /dev/null || { echo "❌ wait_for_nginx_ingress not found"; exit 1; }
declare -f wait_for_nginx_ingress_endpoints > /dev/null || { echo "❌ wait_for_nginx_ingress_endpoints not found"; exit 1; }

# Test UI testing functions
declare -f test_harbor_ui > /dev/null || { echo "❌ test_harbor_ui not found"; exit 1; }
declare -f verify_harbor_ui_status > /dev/null || { echo "❌ verify_harbor_ui_status not found"; exit 1; }

# Test utility functions
declare -f validate_env_vars > /dev/null || { echo "❌ validate_env_vars not found"; exit 1; }
declare -f test_header > /dev/null || { echo "❌ test_header not found"; exit 1; }
declare -f test_footer > /dev/null || { echo "❌ test_footer not found"; exit 1; }
declare -f display_harbor_status > /dev/null || { echo "❌ display_harbor_status not found"; exit 1; }
declare -f wait_for_resource_creation > /dev/null || { echo "❌ wait_for_resource_creation not found"; exit 1; }

echo "✅ All expected functions are defined"

# Test validate_env_vars with mock data
export SMOKE_TEST_VAR1="value1"
export SMOKE_TEST_VAR2="value2"

if validate_env_vars "SMOKE_TEST_VAR1" "SMOKE_TEST_VAR2"; then
    echo "✅ validate_env_vars works with set variables"
else
    echo "❌ validate_env_vars failed with set variables"
    exit 1
fi

if validate_env_vars "NONEXISTENT_VAR" 2>/dev/null; then
    echo "❌ validate_env_vars should fail with missing variable"
    exit 1
else
    echo "✅ validate_env_vars correctly detects missing variables"
fi

# Test test_header and test_footer
test_header "Smoke Test" > /dev/null
echo "✅ test_header works"

test_footer "Smoke Test" > /dev/null
echo "✅ test_footer works"

echo ""
echo "=== All smoke tests passed! ==="
