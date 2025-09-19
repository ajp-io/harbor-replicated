# Let's Encrypt Implementation Debug Report

## Status: ✅ Implementation Working, ❌ DNS Routing Issue

Date: 2025-09-19
PR: #5 (implement-lets-encrypt branch)
Test VM: `7fcf2628` (`ajp-io@65.108.123.179:37837`)

## Summary

The Let's Encrypt implementation is **architecturally correct and fully functional**. All cert-manager components, ClusterIssuer, and ACME solver are working properly. The certificate issuance is failing due to an **external DNS routing issue** where Let's Encrypt cannot reach the ACME challenge endpoint.

## What's Working ✅

### 1. Cert-Manager Components
```bash
# All deployments running
kotsadm     deployment.apps/cert-manager                  1/1
kotsadm     deployment.apps/cert-manager-cainjector       1/1
kotsadm     deployment.apps/cert-manager-webhook          1/1

# CRDs installed correctly
kubectl api-resources | grep cert-manager
# Returns: challenges, orders, certificaterequests, certificates, clusterissuers, issuers
```

### 2. ClusterIssuer Ready
```bash
kubectl get clusterissuer letsencrypt-staging
# NAME                  READY   AGE
# letsencrypt-staging   True    44m
```

### 3. ACME Solver Working Internally
```bash
# ACME solver pod running
kotsadm   pod/cm-acme-http-solver-ppmgg   1/1   Running

# Challenge response working on internal IP
curl -H "Host: trusting-mendeleev.ingress.replicatedcluster.com" \
  "http://10.244.194.230/.well-known/acme-challenge/fImSLs0UYecwncFSbg6hAshi8HGXHLFCWGAjNwEXhHU"
# Returns: 200 OK with correct challenge response
```

### 4. Ingress Configuration
```bash
# Both ingresses created with same hostname and IP
kubectl get ingress -n kotsadm
# harbor-ingress: trusting-mendeleev.ingress.replicatedcluster.com -> 10.244.194.230
# cm-acme-http-solver: trusting-mendeleev.ingress.replicatedcluster.com -> 10.244.194.230
```

## Root Cause of Failure ❌

### DNS Routing Through Cloudflare
The external hostname resolves to Cloudflare, not the VM's public IP:

```bash
# External request fails
curl "http://trusting-mendeleev.ingress.replicatedcluster.com/.well-known/acme-challenge/..."
# Returns: HTTP/1.1 503 Service Unavailable
# Headers show: Server: cloudflare, CF-RAY: 981be96bef20481e-ARN
```

### Challenge Status
```bash
kubectl describe challenge harbor-tls-cert-1-2354617513-3757097763 -n kotsadm
# Status: pending
# Reason: Waiting for HTTP-01 challenge propagation: wrong status code '503', expected '200'
```

Let's Encrypt cannot reach the ACME challenge endpoint because:
1. DNS points to Cloudflare (172.67.155.203)
2. Cloudflare cannot reach internal VM IP (10.244.194.230)
3. Returns 503 Service Unavailable

## Current Certificate Status

```bash
# Certificate not issued
kubectl get certificate harbor-tls-cert -n kotsadm
# NAME              READY   SECRET            AGE
# harbor-tls-cert   False   harbor-tls-cert   44m

# Order stuck pending
kubectl get orders -n kotsadm
# NAME                                 STATE     AGE
# harbor-tls-cert-1-2354617513         pending   45m

# Challenge failing
kubectl get challenges -n kotsadm
# NAME                                             STATE     DOMAIN                                             AGE
# harbor-tls-cert-1-2354617513-3757097763         pending   trusting-mendeleev.ingress.replicatedcluster.com   44m
```

## Solutions 🔧

### Option 1: Fix DNS Routing (Recommended)
Configure the hostname to point directly to the VM's public IP instead of through Cloudflare:
- Find VM's public IP: Check Replicated VM dashboard or `replicated vm port expose` output
- Update DNS record for `trusting-mendeleev.ingress.replicatedcluster.com`
- Point A record directly to VM public IP (not Cloudflare)

### Option 2: Configure Cloudflare Properly
If Cloudflare must be used:
- Configure Cloudflare to proxy to the VM's public IP
- Ensure Cloudflare can route /.well-known/acme-challenge/* requests
- May require Cloudflare configuration for the public IP

### Option 3: Switch to DNS-01 Challenge
Modify ClusterIssuer to use DNS-01 instead of HTTP-01:
- Requires DNS API access (Route53, Cloudflare API, etc.)
- Doesn't require HTTP endpoint accessibility
- More complex setup but works with CDNs

## Verification Commands

### Check Let's Encrypt Setup Status
```bash
# All cert-manager resources
kubectl get clusterissuers,certificates,certificaterequests,orders,challenges -A

# Certificate details
kubectl describe certificate harbor-tls-cert -n kotsadm

# Challenge status
kubectl describe challenge -n kotsadm | grep -A 10 "Status:"
```

### Test ACME Challenge Accessibility
```bash
# Internal (should work - returns 200)
curl -H "Host: HOSTNAME" "http://INTERNAL_IP/.well-known/acme-challenge/TOKEN"

# External (currently fails - returns 503)
curl "http://HOSTNAME/.well-known/acme-challenge/TOKEN"
```

### Check Browser Certificate
Once certificate is issued:
```bash
# Command line certificate check
openssl s_client -connect HOSTNAME:443 -servername HOSTNAME | openssl x509 -text | grep Issuer
# Should show: Issuer: CN = Fake LE Intermediate X1 (for staging)

# Browser: Check certificate details in browser security tab
# Should show "Let's Encrypt Authority" instead of self-signed
```

## Files Modified for Let's Encrypt

### Core Implementation
- `manifests/cert-manager.yaml` - Cert-manager HelmChart
- `manifests/ingress-nginx.yaml` - Nginx ingress controller
- `charts/harbor/templates/cert-manager-issuers.yaml` - ClusterIssuer template
- `manifests/harbor.yaml` - Updated certSource to use cert-manager
- `manifests/kots-app.yaml` - Status informers for cert-manager components

### Testing Infrastructure
- `.github/workflows/pr-test.yml` - Package all three charts, expose admin console port
- `scripts/test-embedded-install.sh` - Added sleep for async Harbor deployment

## Next Steps

1. **Immediate**: Fix DNS routing to point directly to VM public IP
2. **Test**: Verify ACME challenge returns 200 from external access
3. **Monitor**: Watch certificate status transition to Ready=True
4. **Validate**: Check browser shows Let's Encrypt certificate instead of self-signed

## Test Environment Access

- **VM ID**: `7fcf2628`
- **SSH**: `ssh ajp-io@65.108.123.179 -p 37837`
- **kubectl**: `sudo KUBECONFIG=/var/lib/embedded-cluster/k0s/pki/admin.conf /var/lib/embedded-cluster/bin/kubectl`
- **Harbor URL**: https://trusting-mendeleev.ingress.replicatedcluster.com
- **Admin Console**: http://trusting-mendeleev.ingress.replicatedcluster.com:30000