# Let's Encrypt Certificate Implementation for Harbor

## Overview
Replace self-signed certificates with trusted Let's Encrypt certificates for Harbor when deployed via embedded cluster. This will eliminate browser security warnings and provide automatic certificate renewal.

## Prerequisites
Before implementing this proposal, ensure:
- Customer email is available at `.Values.global.replicated.customerEmail` in the Harbor Helm chart
- This requires changes to how global values are passed to the Harbor chart

## Implementation Steps

### 1. Add Cert-Manager to Embedded Cluster
**File:** `manifests/embedded-cluster.yaml`

Add cert-manager as a Helm chart in the extensions section after ingress-nginx:

```yaml
extensions:
  helm:
    repositories:
      - name: ingress-nginx
        url: https://kubernetes.github.io/ingress-nginx
      - name: jetstack
        url: https://charts.jetstack.io
    charts:
      - name: ingress-nginx
        # ... existing config ...
      - name: cert-manager
        chartname: jetstack/cert-manager
        namespace: cert-manager
        version: "v1.13.3"
        values: |
          installCRDs: true
```

### 2. Create ClusterIssuer Template
**File:** `harbor/templates/cert-manager-issuers.yaml` (new file)

Create a new template that conditionally creates a Let's Encrypt issuer:

```yaml
{{- if and (eq .Values.expose.type "ingress") (eq .Values.expose.tls.certSource "secret") .Values.global.replicated.customerEmail }}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: {{ .Values.global.replicated.customerEmail }}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: {{ .Values.expose.ingress.className }}
{{- end }}
```

**Note:** Using staging issuer initially to avoid rate limits during testing. The staging certificate will cause browser warnings but proves the system works.

### 3. Update Harbor Ingress Template
**File:** `harbor/templates/ingress/ingress.yaml`

Add cert-manager annotation after line 45 (within the annotations section):

```yaml
  annotations:
{{ toYaml $ingress.annotations | indent 4 }}
{{- if eq .Values.expose.tls.certSource "secret" }}
    cert-manager.io/cluster-issuer: letsencrypt-staging
{{- end }}
```

### 4. Update Harbor Configuration
**File:** `manifests/harbor.yaml`

Change the embedded cluster configuration to use cert-manager certificates:

```yaml
- when: 'repl{{ eq Distribution "embedded-cluster" }}'
  values:
    expose:
      type: ingress
      tls:
        enabled: true
        certSource: secret  # Changed from "auto"
        secret:
          secretName: harbor-tls-cert  # Cert-manager will create this
      ingress:
        hosts:
          core: repl{{ ConfigOption "harbor_hostname" }}
        className: nginx
    externalURL: https://repl{{ ConfigOption "harbor_hostname" }}
```

## Testing Process

1. **Deploy with staging issuer**
   - Deploy the embedded cluster with these changes
   - Verify cert-manager is running: `kubectl get pods -n cert-manager`
   - Check certificate creation: `kubectl get certificate -A`
   - Accept browser warning (staging certs aren't trusted)
   - Verify Harbor is accessible

2. **Monitor certificate issuance**
   ```bash
   kubectl describe certificate harbor-tls-cert -n default
   kubectl get clusterissuer
   kubectl describe clusterissuer letsencrypt-staging
   ```

3. **Check for issues**
   ```bash
   kubectl logs -n cert-manager deploy/cert-manager
   kubectl get events -A | grep cert
   ```

## Moving to Production

Once testing is successful, make these changes:

1. **Update issuer template** (`harbor/templates/cert-manager-issuers.yaml`):
   - Change `letsencrypt-staging` to `letsencrypt-prod`
   - Change server URL from `acme-staging-v02` to `acme-v02`
   - Consider adding both issuers and using a config option to switch

2. **Update ingress annotation** (`harbor/templates/ingress/ingress.yaml`):
   - Change `letsencrypt-staging` to `letsencrypt-prod`

3. **Delete existing certificate** to force regeneration:
   ```bash
   kubectl delete secret harbor-tls-cert -n default
   kubectl delete certificate harbor-tls-cert -n default
   ```

## Important Considerations

### Rate Limits
- Let's Encrypt production: 50 certificates per domain per week
- Let's Encrypt staging: 30,000 per domain per week
- Always test with staging first

### Requirements
- Domain must be publicly resolvable
- Port 80 must be accessible for HTTP-01 challenge
- Customer email (from Replicated license) must be valid

### Debugging
If certificates aren't being issued:
1. Check cert-manager logs
2. Verify ingress is accessible from internet
3. Check DNS resolution for the domain
4. Verify the HTTP-01 challenge path is accessible

### Future Enhancements
1. **Add configuration option** for certificate type (self-signed vs Let's Encrypt)
2. **Support DNS-01 challenge** for domains not publicly accessible
3. **Add BYO certificate option** for enterprises with existing certificates
4. **Include both staging and prod issuers** with config option to choose

## Architecture Decision Record

### Why Let's Encrypt?
- Free, automated, trusted certificates
- Industry standard for containerized applications
- Eliminates manual certificate management
- Automatic renewal before expiry

### Why HTTP-01 Challenge?
- Simpler than DNS-01 (no DNS provider credentials needed)
- Works with any domain that resolves to the cluster
- Already have ingress-nginx configured

### Why Cert-Manager?
- De facto standard for Kubernetes certificate management
- Robust, production-tested
- Handles renewal automatically
- Integrates seamlessly with ingress controllers

### Why No Configuration Option (Initially)?
- Simplifies implementation
- Most customers want trusted certificates
- Self-signed certificates provide poor user experience
- Can add BYO certificate option later for special cases