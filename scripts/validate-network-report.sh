#!/bin/bash
set -euo pipefail

# Validates network report contains only allowed domains
# Usage: validate-network-report.sh NETWORK_ID

if [ $# -ne 1 ]; then
    echo "Usage: $0 NETWORK_ID"
    exit 1
fi

NETWORK_ID="$1"
ALLOWED_DOMAINS=("images.alexparker.info" "updates.alexparker.info")

echo "=================================================="
echo "Network Report Validation"
echo "=================================================="
echo "Network ID: ${NETWORK_ID}"
echo "Allowed domains: ${ALLOWED_DOMAINS[*]}"
echo ""

# Fetch network report summary
echo "Fetching network report summary..."

# Retry logic: Network reports may take a few seconds to become available
MAX_RETRIES=5
RETRY_DELAY=5
ATTEMPT=1

while [ $ATTEMPT -le $MAX_RETRIES ]; do
    echo "Attempt $ATTEMPT of $MAX_RETRIES..."

    REPORT=$(replicated network report "${NETWORK_ID}" --summary 2>&1)

    # Check if command succeeded and returned valid data
    if [ $? -eq 0 ] && [ -n "$REPORT" ] && [ "$REPORT" != "null" ] && ! echo "$REPORT" | grep -q "Error:"; then
        echo "✅ Network report fetched successfully"
        break
    fi

    if [ $ATTEMPT -eq $MAX_RETRIES ]; then
        echo "❌ ERROR: Failed to fetch network report after $MAX_RETRIES attempts"
        echo "Last error: $REPORT"
        echo ""
        echo "This could mean:"
        echo "  1. Network reporting was not properly enabled"
        echo "  2. No network activity occurred during the test"
        echo "  3. The report takes longer than expected to generate"
        echo ""
        exit 1
    fi

    echo "Report not ready yet, waiting ${RETRY_DELAY} seconds..."
    sleep $RETRY_DELAY
    ATTEMPT=$((ATTEMPT + 1))
done

# Extract total events
TOTAL_EVENTS=$(echo "$REPORT" | jq -r '.totalEvents // 0')
echo "Total network events: ${TOTAL_EVENTS}"
echo ""

# Extract unique domains
DOMAINS=$(echo "$REPORT" | jq -r '.domainNames[]? | .domain' 2>/dev/null | sort -u || echo "")

if [ -z "$DOMAINS" ]; then
    echo "⚠️  WARNING: No domain names found in network report"
    echo ""
    echo "Full report:"
    echo "$REPORT" | jq '.'
    echo ""
    echo "✅ PASSED: No external domains contacted (empty report)"
    exit 0
fi

echo "Domains contacted during installation:"
echo "=================================================="
echo "$REPORT" | jq -r '.domainNames[] | "\(.domain) - \(.count) requests"'
echo ""

# Validate each domain
VALIDATION_FAILED=0
VIOLATIONS=()

while IFS= read -r domain; do
    ALLOWED=0
    for allowed_domain in "${ALLOWED_DOMAINS[@]}"; do
        if [[ "$domain" == "$allowed_domain" ]]; then
            ALLOWED=1
            break
        fi
    done

    if [[ $ALLOWED -eq 0 ]]; then
        COUNT=$(echo "$REPORT" | jq -r --arg domain "$domain" '.domainNames[] | select(.domain == $domain) | .count')
        echo "❌ VIOLATION: $domain ($COUNT requests)"
        VIOLATIONS+=("$domain")
        VALIDATION_FAILED=1
    else
        COUNT=$(echo "$REPORT" | jq -r --arg domain "$domain" '.domainNames[] | select(.domain == $domain) | .count')
        echo "✅ ALLOWED: $domain ($COUNT requests)"
    fi
done <<< "$DOMAINS"

echo ""
echo "=================================================="

if [[ $VALIDATION_FAILED -eq 1 ]]; then
    echo "❌ VALIDATION FAILED"
    echo "=================================================="
    echo ""
    echo "The following unexpected domains were contacted:"
    for violation in "${VIOLATIONS[@]}"; do
        echo "  - $violation"
    done
    echo ""
    echo "Only these domains are allowed:"
    for allowed in "${ALLOWED_DOMAINS[@]}"; do
        echo "  - $allowed"
    done
    echo ""
    echo "Full network report (JSON):"
    echo "=================================================="
    echo "$REPORT" | jq '.'
    echo ""
    exit 1
fi

echo "✅ VALIDATION PASSED"
echo "=================================================="
echo "All network traffic went to expected endpoints"
echo ""
exit 0
