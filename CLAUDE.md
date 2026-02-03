# Claude Code Instructions

## Release Workflow

When you ask me to "create a release" or "make a release", I should:

1. **Get current version and increment patch**
   - Get current Unstable version: `replicated release ls --channel Unstable | head -5`
   - Parse the version and increment patch (e.g., `1.18.0` → `1.18.1`)

2. **Package Helm charts**
   - Clean existing packages: `rm -f manifests/*.tgz`
   - Update Harbor dependencies: `helm dependency update charts/harbor`
   - Package charts:
     - `helm package charts/harbor -d manifests -u`
     - `helm package charts/ingress-nginx -d manifests -u`
     - `helm package charts/cert-manager -d manifests -u`

3. **Create and promote release**
   - `replicated release create --yaml-dir ./manifests --promote Unstable --version [NEW_VERSION]`
   - **Note**: Do not use `--lint` flag when using alpha/beta EC versions, as they won't be recognized by the linter and will cause "non-existent-ec-version" errors. Skip linting for alpha releases.

4. **Cleanup**
   - `rm -f manifests/*.tgz`
   - `rm -rf charts/harbor/charts/`
   - Show result: `replicated release ls | head -5`

**Note**: Production credentials are already default in your shell (set in .zshrc), no environment switching needed.

## Replicated SDK Configuration

**Important**: `global.replicated.*` values (like `global.replicated.customerEmail`) are automatically injected by KOTS at runtime. These values will NOT be present in the static values.yaml files but are available when the application is deployed through KOTS. Do not treat missing `global.replicated` values as configuration errors.

## Testing Commands

- **Lint**: (determine from codebase - check package.json or README)
- **Typecheck**: (determine from codebase - check package.json or README)