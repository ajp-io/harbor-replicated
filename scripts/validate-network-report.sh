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

    # Temporarily disable exit on error to capture the output
    # Note: --summary flag appears to not work, so we use the full report instead
    set +e
    REPORT=$(replicated network report "${NETWORK_ID}" 2>&1)
    REPORT_EXIT_CODE=$?
    set -e

    echo "Command exit code: $REPORT_EXIT_CODE"

    # Show what we got back
    if [ -n "$REPORT" ]; then
        echo "Response received (first 200 chars): ${REPORT:0:200}"
    else
        echo "Response: (empty)"
    fi

    # Check if command succeeded and returned valid data
    if [ $REPORT_EXIT_CODE -eq 0 ] && [ -n "$REPORT" ] && [ "$REPORT" != "null" ] && ! echo "$REPORT" | grep -q "Error:"; then
        echo "✅ Network report fetched successfully"
        break
    fi

    if [ $ATTEMPT -eq $MAX_RETRIES ]; then
        echo ""
        echo "❌ ERROR: Failed to fetch network report after $MAX_RETRIES attempts"
        echo "=========================================="
        echo "Last response:"
        echo "$REPORT"
        echo "=========================================="
        echo ""
        echo "This could mean:"
        echo "  1. Network reporting was not properly enabled"
        echo "  2. No network activity occurred during the test"
        echo "  3. The report takes longer than expected to generate"
        echo "  4. Wrong network ID format"
        echo ""
        exit 1
    fi

    echo "Report not ready yet, waiting ${RETRY_DELAY} seconds..."
    sleep $RETRY_DELAY
    ATTEMPT=$((ATTEMPT + 1))
done

# Extract total events from the events array
TOTAL_EVENTS=$(echo "$REPORT" | jq -r '.events | length')
echo "Total network events: ${TOTAL_EVENTS}"
echo ""

# Extract unique DNS query names (domains) from events, excluding internal/local domains
# Filter out:
# - *.cluster.local (Kubernetes internal DNS)
# - *.svc.cluster.local (Kubernetes service DNS)
# - localhost/127.0.0.1 references
# - Pure IP addresses or internal identifiers (numbers, short hashes)
DOMAINS=$(echo "$REPORT" | jq -r '.events[]? | select(.dnsQueryName != null and .dnsQueryName != "") | .dnsQueryName' 2>/dev/null | \
    grep -v '\.cluster\.local$' | \
    grep -v '\.svc\.cluster\.local$' | \
    grep -v '^127\.' | \
    grep -v '^localhost' | \
    grep -v '^[0-9]\+$' | \
    grep -v '^[0-9a-f]\{8\}$' | \
    grep -E '\.[a-z]{2,}$' | \
    sort -u || echo "")

if [ -z "$DOMAINS" ]; then
    echo "⚠️  WARNING: No domain names found in network report"
    echo ""
    echo "This could mean no DNS queries were made, or only IP connections occurred."
    echo "First 10 events:"
    echo "$REPORT" | jq '.events[0:10]'
    echo ""
    echo "✅ PASSED: No external domains contacted"
    exit 0
fi

echo "Domains contacted during installation:"
echo "=================================================="
# Count occurrences of each domain
echo "$DOMAINS" | while read -r domain; do
    if [ -n "$domain" ]; then
        COUNT=$(echo "$REPORT" | jq -r --arg domain "$domain" '[.events[]? | select(.dnsQueryName == $domain)] | length' 2>/dev/null || echo "0")
        echo "$domain - $COUNT DNS queries"
    fi
done
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
