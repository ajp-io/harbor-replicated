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
REPORT=$(replicated network report "${NETWORK_ID}" --summary)

if [ -z "$REPORT" ] || [ "$REPORT" == "null" ]; then
    echo "❌ ERROR: No network report available for network ${NETWORK_ID}"
    exit 1
fi

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
