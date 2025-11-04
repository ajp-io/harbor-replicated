# Network Reporting Validation POC

## Overview

This POC uses Replicated's CMX (Compatibility Matrix) network reporting feature to validate that all HTTP requests during Harbor installation go only to expected endpoints. This catches cases where chart updates don't properly update image values to use the proxy registry.

## Why This Matters

When the `update-charts.sh` script runs and creates a PR, tests currently pass even when:
- Images aren't updated to point to `images.alexparker.info`
- Images are pulled from upstream registries directly
- Other network requests go to unexpected endpoints

Network reporting validation ensures we catch these issues in CI before merging.

## Implementation

### Files Modified

#### `.github/workflows/pr-test.yml`
- **Added "Enable network reporting" step** after VM creation
  - Extracts network ID from VM metadata
  - Truncates to 8 characters (short ID format)
  - Runs `replicated network update --collect-report`

- **Added "Validate network traffic" step** after installation test
  - Runs `scripts/validate-network-report.sh` with network ID
  - Validates all DNS queries against allowlist

- **Changed cleanup condition** from `if: always()` to `if: success()`
  - VM stays running on validation failure for debugging
  - Access failed VMs via: `replicated vm ls` → `replicated vm ssh-endpoint <vm-id>`

#### `scripts/validate-network-report.sh` (created)
Network validation script that:
1. Fetches network report from Replicated API (without `--summary` flag)
2. Extracts unique DNS query names from `.events[]` array
3. Filters out internal/infrastructure domains
4. Validates remaining domains against allowlist
5. Reports violations with DNS query counts

**Filtering Logic:**
- `*.cluster.local` - Kubernetes internal DNS
- `*.svc.cluster.local` - Kubernetes service DNS
- `*.replicatedcluster.com` - Replicated ingress infrastructure
- `*.ntp.org`, `ntp.ubuntu.com` - NTP time synchronization
- Localhost/127.0.0.1 references
- Pure IP addresses and short hashes

### Allowed Domains

| Domain | Purpose | Rationale |
|--------|---------|-----------|
| `images.alexparker.info` | Harbor container images | Proxy registry for all Harbor images |
| `updates.alexparker.info` | Replicated SDK updates | Required by Replicated SDK for updates |
| `acme-staging-v02.api.letsencrypt.org` | Let's Encrypt staging ACME | TLS certificate issuance (staging environment for tests) |
| `api.github.com` | Trivy vulnerability database | Trivy downloads vulnerability definitions (anonymous, 60 req/hour) |

### Cert-Manager Configuration

**Key Finding:** The Harbor chart already has correct conditional logic for ClusterIssuers in `charts/harbor/templates/cert-manager-issuers.yaml`:

```yaml
{{- if or (not .Values.expose.ingress.letsencryptEnvironment) (eq .Values.expose.ingress.letsencryptEnvironment "staging") }}
# Creates letsencrypt-staging ClusterIssuer
{{- end }}
{{- if eq .Values.expose.ingress.letsencryptEnvironment "production" }}
# Creates letsencrypt-prod ClusterIssuer
{{- end }}
```

This creates **only one ClusterIssuer** based on the `letsencryptEnvironment` value:
- Empty or "staging" → staging issuer only
- "production" → production issuer only

**No modifications needed** to the cert-manager template - it already works correctly.

The value is set in `manifests/harbor.yaml:39`:
```yaml
letsencryptEnvironment: repl{{ ConfigOption "letsencrypt_environment" }}
```

Default config in `manifests/kots-config.yaml` is `staging` for tests.

## Current Status

### ✅ Working
- Network reporting successfully enabled on test VMs
- Network reports fetched from Replicated API
- DNS queries extracted and filtered correctly
- Validation script executes in CI workflow
- VM cleanup only runs on success (preserved for debugging on failure)

### ❌ Not Working Yet
- **Validation still failing** - last run showed unexpected domains
- Need to investigate what domains are being contacted
- May need to adjust allowlist or fix configuration

### Recent Test Run (19041089328)

Last test was interrupted but showed:
- Test workflow triggered successfully
- Network reporting enabled
- Installation test running
- Validation step pending (interrupted before completion)

## Debugging Failed Validations

When a validation fails:

1. **Check the workflow logs:**
   ```bash
   gh run view <run-id> --job <job-id> --log | grep -A50 "Validate network traffic"
   ```

2. **Find the network ID in logs:**
   Look for output like: `Network ID: 4666f589`

3. **Get full network report:**
   ```bash
   repl-env-prod
   replicated network report <network-id> | jq '.'
   ```

4. **Access the VM if needed:**
   ```bash
   repl-env-prod
   replicated vm ls  # Find the VM ID
   VM_ENDPOINT=$(replicated vm ssh-endpoint <vm-id>)
   ssh $VM_ENDPOINT
   # On VM:
   sudo embedded-cluster kubectl get clusterissuers
   sudo embedded-cluster kubectl logs -n harbor <pod-name>
   ```

5. **Check which ClusterIssuers were created:**
   This helps verify the cert-manager conditional logic is working.

## Known Issues

### Issue 1: `--summary` Flag Doesn't Work
**Problem:** `replicated network report --summary` returns "Not found"
**Solution:** Use full report without `--summary`, parse `.events[]` array
**Status:** ✅ Fixed

### Issue 2: Internal DNS Pollution
**Problem:** Network report includes internal Kubernetes DNS queries
**Solution:** Filter with grep patterns for `.cluster.local`, `.svc.cluster.local`, etc.
**Status:** ✅ Fixed

### Issue 3: jq Errors on Missing Fields
**Problem:** Script tried to access `.domainNames[]` which doesn't exist in event-based report
**Solution:** Use `.events[]` array with null checks and error suppression
**Status:** ✅ Fixed

### Issue 4: NTP and Replicated Infrastructure
**Problem:** Legitimate infrastructure domains were flagged as violations
**Solution:** Added filters for `*.ntp.org`, `ntp.ubuntu.com`, `*.replicatedcluster.com`
**Status:** ✅ Fixed

### Issue 5: Validation Still Failing
**Problem:** Most recent test run failed validation (or was interrupted)
**Solution:** TBD - need to check logs to see what domains are being contacted
**Status:** 🔍 Investigating

## Next Steps

1. **Check latest failure logs**
   - Run: `gh run view 19041089328 --log | grep -A100 "Validate network traffic"`
   - Identify what unexpected domains were contacted

2. **Determine if domains are legitimate**
   - If legitimate (e.g., more infrastructure): add to filter list
   - If unexpected: investigate why they're being contacted

3. **Verify cert-manager behavior**
   - Confirm only staging ClusterIssuer is created in tests
   - Check if production issuer is somehow being created too

4. **Consider adding domain-specific validation**
   - Maybe validate that ONLY staging Let's Encrypt is contacted (not production)
   - Add assertion that api.github.com is only contacted by Trivy pods

5. **Test with intentional failure**
   - Temporarily modify chart to use upstream registry
   - Verify validation catches it and fails

## Important Notes

- **Network ID Format:** Use 8-character short ID, not full hash
- **Environment Setup:** Always run `repl-env-prod` before Replicated commands
- **Report Timing:** Network reports may take a few seconds after installation to become available (script has 5-retry logic with 5-second delays)
- **Chart Modifications:** Minimize changes to upstream Harbor chart to ease future upgrades
- **Production vs Staging:** Only staging Let's Encrypt endpoint should be contacted in tests

## References

- PR: https://github.com/ajp-io/harbor-replicated/pull/39
- Branch: `poc/network-reporting-validation`
- Replicated Network Reporting Docs: (check Replicated vendor docs)
- Trivy GitHub Token: `charts/harbor/templates/trivy/trivy-sts.yaml:144`
- Cert-Manager Issuers: `charts/harbor/templates/cert-manager-issuers.yaml`
- Harbor Values: `charts/harbor/values.yaml:879` (gitHubToken: "")

## Commands Reference

```bash
# Switch to production environment
repl-env-prod

# List VMs
replicated vm ls

# Get network report
replicated network report <network-id>

# Watch workflow
gh run watch <run-id> --exit-status

# Check workflow logs
gh run view <run-id> --log

# Access VM via SSH
VM_ENDPOINT=$(replicated vm ssh-endpoint <vm-id>)
ssh $VM_ENDPOINT

# On VM: Check ClusterIssuers
sudo embedded-cluster kubectl get clusterissuers -o yaml

# On VM: Check pods
sudo embedded-cluster kubectl get pods -n harbor
```
