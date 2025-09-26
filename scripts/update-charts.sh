#!/bin/bash

# Update Helm Charts Script
# This script downloads the latest versions of Harbor, ingress-nginx, and cert-manager charts
# and applies customizations from overlay files while preserving custom configurations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEMP_DIR="/tmp/chart-updates"
OVERLAY_DIR="$PROJECT_ROOT/chart-overlays"

# Chart configurations
declare -A CHART_REPOS=(
    ["harbor"]="https://helm.goharbor.io"
    ["ingress-nginx"]="https://kubernetes.github.io/ingress-nginx"
    ["cert-manager"]="https://charts.jetstack.io"
)

declare -A CHART_NAMES=(
    ["harbor"]="harbor"
    ["ingress-nginx"]="ingress-nginx"
    ["cert-manager"]="cert-manager"
)

declare -A MANIFEST_FILES=(
    ["harbor"]="manifests/harbor.yaml"
    ["ingress-nginx"]="manifests/ingress-nginx.yaml"
    ["cert-manager"]="manifests/cert-manager.yaml"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if required tools are installed
check_dependencies() {
    local deps=("helm" "yq" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "$dep is required but not installed. Please install it first."
            exit 1
        fi
    done
}

# Get current chart version from Chart.yaml
get_current_chart_version() {
    local chart_name="$1"
    local chart_dir="$PROJECT_ROOT/charts/$chart_name"

    if [[ ! -f "$chart_dir/Chart.yaml" ]]; then
        error "Chart.yaml not found for $chart_name in $chart_dir"
        exit 1
    fi

    yq eval '.version' "$chart_dir/Chart.yaml"
}

# Get latest chart version from repository
get_latest_chart_version() {
    local chart_name="$1"
    local repo_url="${CHART_REPOS[$chart_name]}"
    local helm_chart_name="${CHART_NAMES[$chart_name]}"

    # Add repository and update
    helm repo add "${chart_name}-charts" "$repo_url" --force-update > /dev/null 2>&1
    helm repo update > /dev/null 2>&1

    # Get latest version
    helm search repo "${chart_name}-charts/$helm_chart_name" --version=">=0.0.0" -o json | jq -r '.[0].version'
}

# Get current SDK version from Harbor Chart.yaml
get_current_sdk_version() {
    local chart_dir="$PROJECT_ROOT/charts/harbor"

    if [[ ! -f "$chart_dir/Chart.yaml" ]]; then
        echo ""
        return
    fi

    yq eval '.dependencies[] | select(.name == "replicated") | .version' "$chart_dir/Chart.yaml" 2>/dev/null || echo ""
}

# Get latest SDK version from GitHub releases
get_latest_sdk_version() {
    local api_url="https://api.github.com/repos/replicatedhq/replicated-sdk/releases/latest"
    local version

    if command -v curl &> /dev/null; then
        version=$(curl -s "$api_url" | jq -r '.tag_name' 2>/dev/null)
    elif command -v wget &> /dev/null; then
        version=$(wget -qO- "$api_url" | jq -r '.tag_name' 2>/dev/null)
    else
        error "Neither curl nor wget is available to fetch SDK version"
        return 1
    fi

    # Remove 'v' prefix if present
    version=${version#v}

    if [[ "$version" == "null" || -z "$version" ]]; then
        error "Failed to fetch latest SDK version"
        return 1
    fi

    echo "$version"
}

# Download and extract the latest chart
download_latest_chart() {
    local chart_name="$1"
    local version="$2"
    local repo_url="${CHART_REPOS[$chart_name]}"
    local helm_chart_name="${CHART_NAMES[$chart_name]}"
    local chart_temp_dir="$TEMP_DIR/$chart_name"

    log "Downloading $chart_name chart version $version..."

    # Clean up any existing temp directory
    rm -rf "$chart_temp_dir"
    mkdir -p "$chart_temp_dir"

    # Add repository if not already added
    helm repo add "${chart_name}-charts" "$repo_url" --force-update > /dev/null 2>&1
    helm repo update > /dev/null 2>&1

    # Download and extract the chart
    helm pull "${chart_name}-charts/$helm_chart_name" --version="$version" --untar --untardir="$chart_temp_dir"

    if [[ ! -d "$chart_temp_dir/$helm_chart_name" ]]; then
        error "Failed to download or extract $chart_name chart"
        exit 1
    fi

    success "$chart_name chart downloaded to $chart_temp_dir/$helm_chart_name"
}


# Update the chart in the repository
update_chart() {
    local chart_name="$1"
    local chart_temp_dir="$TEMP_DIR/$chart_name/${CHART_NAMES[$chart_name]}"
    local chart_dest_dir="$PROJECT_ROOT/charts/$chart_name"

    log "Updating $chart_name chart files..."

    # Backup current chart
    if [[ -d "$chart_dest_dir" ]]; then
        cp -r "$chart_dest_dir" "$chart_dest_dir.backup"
    fi

    # Remove current chart contents and copy new files
    rm -rf "${chart_dest_dir:?}"/*
    cp -r "$chart_temp_dir/"* "$chart_dest_dir/"

    success "$chart_name chart files updated"
}

# Update Harbor chart overlay with actual SDK version
update_harbor_chart_overlay() {
    local sdk_version="$1"
    local chart_overlay_file="$OVERLAY_DIR/harbor/chart-overlay.yaml"

    if [[ -f "$chart_overlay_file" ]]; then
        log "Updating Harbor chart overlay with SDK version $sdk_version..."
        sed -i.bak "s/REPLICATED_SDK_VERSION/$sdk_version/g" "$chart_overlay_file"
        rm -f "$chart_overlay_file.bak"
        success "Harbor chart overlay updated with SDK version $sdk_version"
    else
        warn "Harbor chart overlay file not found at $chart_overlay_file"
    fi
}

# Update manifest version references
update_manifest_version() {
    local chart_name="$1"
    local new_version="$2"
    local manifest_file="$PROJECT_ROOT/${MANIFEST_FILES[$chart_name]}"

    if [[ -f "$manifest_file" ]]; then
        log "Updating $chart_name manifest chart version to $new_version..."

        # Update the chartVersion in the manifest file
        yq eval ".spec.chart.chartVersion = \"$new_version\"" -i "$manifest_file"

        success "$chart_name manifest version updated to $new_version"
    else
        warn "$chart_name manifest file not found at $manifest_file"
    fi
}

# Process a single chart update
update_single_chart() {
    local chart_name="$1"
    local sdk_version="$2"

    local current_version
    current_version=$(get_current_chart_version "$chart_name")
    log "Current $chart_name version: $current_version"

    local latest_version
    latest_version=$(get_latest_chart_version "$chart_name")
    log "Latest $chart_name version: $latest_version"

    if [[ "$current_version" == "$latest_version" ]]; then
        log "$chart_name is already up to date"
        return 1  # No update needed
    fi

    log "$chart_name update available: $current_version -> $latest_version"

    # Download the latest chart
    download_latest_chart "$chart_name" "$latest_version"

    # Generate image overlay from the downloaded chart
    local chart_temp_dir="$TEMP_DIR/$chart_name/${CHART_NAMES[$chart_name]}"
    log "Generating image overlay for $chart_name..."
    "$SCRIPT_DIR/generate-overlay.sh" "$chart_name" "$chart_temp_dir"

    # Update chart overlay with SDK version for Harbor
    if [[ "$chart_name" == "harbor" ]]; then
        update_harbor_chart_overlay "$sdk_version"
    fi

    # Update the chart with pristine content (no overlays applied)
    update_chart "$chart_name"

    # Update manifest references
    update_manifest_version "$chart_name" "$latest_version"

    success "$chart_name updated from $current_version to $latest_version"
    return 0  # Update completed
}

# Show summary of changes
show_changes() {
    local updated_charts=("$@")

    echo
    echo "================================================================"
    echo "Helm Charts Update Summary"
    echo "================================================================"

    if [[ ${#updated_charts[@]} -eq 0 ]]; then
        echo "No charts were updated - all are already at latest versions"
    else
        echo "Updated charts:"
        for chart in "${updated_charts[@]}"; do
            echo "  - $chart"
        done
    fi

    echo

    # Show file changes
    log "Modified files:"
    if command -v git &> /dev/null && git rev-parse --git-dir > /dev/null 2>&1; then
        git -C "$PROJECT_ROOT" status --porcelain charts/ manifests/ chart-overlays/ || true
    else
        echo "Git not available - showing directory contents:"
        ls -la "$PROJECT_ROOT/charts/"
    fi

    echo
    echo "================================================================"
    echo "Next steps:"
    echo "1. Review the changes carefully"
    echo "2. Test the updated charts in a development environment"
    echo "3. Commit and push the changes"
    echo "================================================================"
}

# Clean up temporary files
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi

    # Clean up backup directories
    find "$PROJECT_ROOT/charts" -name "*.backup" -type d -exec rm -rf {} + 2>/dev/null || true
}

# Main execution
main() {
    log "Starting Helm charts update process..."

    # Check dependencies
    check_dependencies

    # Get latest SDK version for Harbor
    local latest_sdk_version
    latest_sdk_version=$(get_latest_sdk_version)
    if [[ $? -eq 0 ]]; then
        log "Latest SDK version: $latest_sdk_version"
    else
        error "Failed to fetch latest SDK version"
        exit 1
    fi

    # Get current SDK version for comparison
    local current_sdk_version
    current_sdk_version=$(get_current_sdk_version)
    log "Current SDK version: ${current_sdk_version:-"not present"}"

    # Set up cleanup trap
    trap cleanup EXIT

    # Clean temp directory
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    # Process each chart
    local updated_charts=()
    local charts=("harbor" "ingress-nginx" "cert-manager")

    for chart_name in "${charts[@]}"; do
        log "Processing $chart_name chart..."
        if update_single_chart "$chart_name" "$latest_sdk_version"; then
            updated_charts+=("$chart_name")
        fi
    done

    # Check if SDK needs separate update (for Harbor)
    local sdk_needs_update=false
    if [[ "$current_sdk_version" != "$latest_sdk_version" ]]; then
        sdk_needs_update=true
        log "SDK update needed: ${current_sdk_version:-"not present"} -> $latest_sdk_version"

        # If Harbor wasn't updated but SDK needs update, update Harbor anyway
        local harbor_in_updated=false
        for chart in "${updated_charts[@]}"; do
            if [[ "$chart" == "harbor" ]]; then
                harbor_in_updated=true
                break
            fi
        done

        if [[ "$harbor_in_updated" == false ]]; then
            log "Updating Harbor for SDK version change..."
            # Update Harbor chart overlay with new SDK version
            update_harbor_chart_overlay "$latest_sdk_version"
            updated_charts+=("harbor (SDK update)")
        fi
    fi

    # Show summary
    show_changes "${updated_charts[@]}"

    if [[ ${#updated_charts[@]} -gt 0 ]]; then
        success "Chart update process completed successfully!"
        echo "Updated: ${updated_charts[*]}"
    else
        success "All charts are up to date!"
    fi
}

# Handle script arguments
if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [--help]"
            echo
            echo "This script updates Harbor, ingress-nginx, and cert-manager Helm charts"
            echo "to their latest versions while preserving custom configurations via overlays."
            echo
            echo "Options:"
            echo "  --help, -h    Show this help message"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
fi

# Run main function
main "$@"