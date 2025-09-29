#!/bin/bash
# Generate dynamic image overlay for Helm charts
# This script reads a chart's values.yaml and generates an overlay that redirects
# all image references to use our proxy registry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Registry mappings function
get_proxy_registry() {
    local registry="$1"
    case "$registry" in
        "quay.io")
            echo "images.alexparker.info/proxy/harbor-enterprise/quay"
            ;;
        "docker.io")
            echo "images.alexparker.info/proxy/harbor-enterprise/docker"
            ;;
        "registry.k8s.io")
            echo "images.alexparker.info/proxy/harbor-enterprise/k8s"
            ;;
        *)
            echo "$DEFAULT_PROXY"
            ;;
    esac
}

# Default proxy registry for images without explicit registry
DEFAULT_PROXY="images.alexparker.info/proxy/harbor-enterprise/docker"

usage() {
    echo "Usage: $0 <chart-name> [chart-path]"
    echo "Generate image overlay for the specified chart and write to chart-overlays/<chart>/values-overlay.yaml"
    echo "  chart-name: Name of the chart (e.g., cert-manager, harbor, ingress-nginx)"
    echo "  chart-path: Optional path to chart directory (defaults to charts/<chart-name>)"
    exit 1
}

log() {
    echo "[generate-overlay] $1" >&2
}

# Transform image repository to use proxy registry
transform_image_repo() {
    local original_repo="$1"

    # If already using proxy registry, return as-is
    if [[ "$original_repo" == images.alexparker.info/* ]]; then
        echo "$original_repo"
        return
    fi

    # Extract registry and image path
    local registry=""
    local image_path="$original_repo"

    # Check if repo contains a registry
    if [[ "$original_repo" == */* ]]; then
        # Split on first slash
        registry="${original_repo%%/*}"
        image_path="${original_repo#*/}"

        # Handle Docker Hub shorthand (no registry prefix)
        if [[ ! "$registry" == *.* ]] && [[ ! "$registry" == *:* ]]; then
            # This is actually part of the image name, not a registry
            registry=""
            image_path="$original_repo"
        fi
    fi

    # Map registry to proxy
    local proxy_registry
    if [[ -n "$registry" ]]; then
        proxy_registry=$(get_proxy_registry "$registry")
    else
        proxy_registry="$DEFAULT_PROXY"
    fi

    echo "$proxy_registry/$image_path"
}

# Generate overlay YAML for image transformations
generate_image_overlay() {
    local chart_name="$1"
    local chart_path="${2:-$PROJECT_ROOT/charts/$chart_name}"
    local values_file="$chart_path/values.yaml"
    local chart_yaml_file="$chart_path/Chart.yaml"
    local overlay_output_file="$PROJECT_ROOT/chart-overlays/$chart_name/values-overlay.yaml"

    if [[ ! -f "$values_file" ]]; then
        log "Error: values.yaml not found at $values_file"
        exit 1
    fi

    log "Analyzing $chart_name chart for image references"

    # Get chart version for header
    local chart_version=""
    if [[ -f "$chart_yaml_file" ]]; then
        chart_version=$(yq eval '.version' "$chart_yaml_file" 2>/dev/null || echo "unknown")
    fi

    # Create overlay directory if it doesn't exist
    mkdir -p "$(dirname "$overlay_output_file")"

    # Use yq to find all image repository references
    local image_refs
    image_refs=$(yq eval '.. | select(has("repository")) | path | join(".")' "$values_file" 2>/dev/null || true)

    # Start writing to the output file
    {
        echo "# Generated image overlay for $chart_name chart"
        echo "# Source: $chart_name v$chart_version"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "#"

        if [[ -z "$image_refs" ]]; then
            log "No image repository references found in $chart_name"
            echo "# No image transformations needed"
            echo ""
        else
            echo "# Image transformations applied:"

            # Store transformations for comments
            local transformations=()
            local yaml_output=""

            # Process each image reference
            while read -r path; do
                [[ -z "$path" ]] && continue

                local original_repo
                original_repo=$(yq eval ".$path.repository" "$values_file" 2>/dev/null || echo "")

                if [[ -n "$original_repo" && "$original_repo" != "null" ]]; then
                    local transformed_repo
                    transformed_repo=$(transform_image_repo "$original_repo")

                    if [[ "$original_repo" != "$transformed_repo" ]]; then
                        log "Transform: $original_repo -> $transformed_repo"
                        transformations+=("# - $original_repo → $transformed_repo")

                        # Convert dot notation to YAML structure
                        local yaml_path="$path"
                        local indentation=""
                        local output_lines=()

                        # Split path by dots and build nested structure
                        IFS='.' read -ra PATH_PARTS <<< "$yaml_path"
                        for i in "${!PATH_PARTS[@]}"; do
                            if [[ $i -eq $((${#PATH_PARTS[@]} - 1)) ]]; then
                                # Last part - add the repository value
                                output_lines+=("${indentation}${PATH_PARTS[$i]}:")
                                output_lines+=("${indentation}  repository: $transformed_repo")
                            else
                                # Intermediate part
                                output_lines+=("${indentation}${PATH_PARTS[$i]}:")
                                indentation="  $indentation"
                            fi
                        done

                        # Append to yaml output
                        yaml_output+=$(printf '%s\n' "${output_lines[@]}")
                        yaml_output+=$'\n'
                    fi
                fi
            done <<< "$image_refs"

            # Write transformation comments
            if [[ ${#transformations[@]} -gt 0 ]]; then
                printf '%s\n' "${transformations[@]}"
            else
                echo "# No image transformations needed"
            fi
            echo "#"
            echo ""

            # Write YAML output
            if [[ -n "$yaml_output" ]]; then
                echo "$yaml_output"
            fi
        fi

        # Handle global registry overrides for charts that support it
        case "$chart_name" in
            "ingress-nginx")
                echo "# Global registry override for ingress-nginx"
                echo "global:"
                echo "  image:"
                echo "    registry: images.alexparker.info/proxy/harbor-enterprise/k8s"
                ;;
        esac
    } > "$overlay_output_file"

    log "Image overlay written to $overlay_output_file"
}

main() {
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        usage
    fi

    local chart_name="$1"
    local chart_path="${2:-$PROJECT_ROOT/charts/$chart_name}"

    if [[ ! -d "$chart_path" ]]; then
        log "Error: Chart directory not found: $chart_path"
        exit 1
    fi

    generate_image_overlay "$chart_name" "$chart_path"
}

main "$@"