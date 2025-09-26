# Claude Code Instructions

## Critical: Replicated Environment Setup

**ALWAYS** follow this process when accessing Replicated resources (clusters, VMs, releases):

1. **First**, run `repl-env-prod` to set production credentials
2. **Then**, ensure ALL subsequent `replicated` commands run in the SAME shell session
3. The default shell uses staging credentials from zshrc - production access requires explicit environment switching

### Example:
```bash
# WRONG - each command runs in separate shell, loses environment
repl-env-prod
replicated cluster ls

# CORRECT - commands chained in same shell
repl-env-prod && replicated cluster ls

# OR use multiple commands in single bash call
repl-env-prod
replicated cluster kubeconfig CLUSTER_ID
kubectl get pods
```

### Why This Matters:
- GitHub Actions workflows create resources in **production**
- Default shell has **staging** credentials
- Accessing production clusters/VMs requires production environment variables
- Environment variables don't persist across separate tool calls

## Replicated SDK Configuration

**Important**: `global.replicated.*` values (like `global.replicated.customerEmail`) are automatically injected by KOTS at runtime. These values will NOT be present in the static values.yaml files but are available when the application is deployed through KOTS. Do not treat missing `global.replicated` values as configuration errors.

## Testing Commands

- **Lint**: (determine from codebase - check package.json or README)
- **Typecheck**: (determine from codebase - check package.json or README)