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

## Testing Commands

- **Lint**: (determine from codebase - check package.json or README)
- **Typecheck**: (determine from codebase - check package.json or README)