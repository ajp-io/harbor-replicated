# Claude Code Instructions

## Release Workflow

When you ask me to "create a release" or "make a release", use the `harbor-release` function:

```bash
harbor-release           # Creates release with linting (default)
harbor-release --no-lint # Creates release without linting (for alpha/beta EC versions)
```

The `harbor-release` function is defined in `~/.zshrc` and automatically:
- Gets the latest release version and increments the patch version
- Cleans and packages all Helm charts (harbor, ingress-nginx, cert-manager)
- Creates and promotes the release to the **Dev** channel
- Cleans up temporary files
- Shows the latest releases

**Note**: Use `--no-lint` when the release includes alpha/beta Embedded Cluster versions, as they won't be recognized by the linter.

**Note**: Production credentials are already default in your shell (set in .zshrc), no environment switching needed.

## Replicated SDK Configuration

**Important**: `global.replicated.*` values (like `global.replicated.customerEmail`) are automatically injected by KOTS at runtime. These values will NOT be present in the static values.yaml files but are available when the application is deployed through KOTS. Do not treat missing `global.replicated` values as configuration errors.

## Testing Commands

- **Lint**: (determine from codebase - check package.json or README)
- **Typecheck**: (determine from codebase - check package.json or README)