#!/bin/bash
# =============================================================================
# Git Migration Suite - Docker Image Import
# =============================================================================
# Purpose:
#   Imports Docker images from base64-encoded files and pushes them to a
#   GitLab Container Registry.
#
# Usage:
#   ./docker_upload.sh
#
# Required .env variables:
#   GITLAB_REGISTRY      - GitLab registry URL (e.g., gitlab.company.com)
#   GITLAB_REGISTRY_PATH - Path to umbrella repo (e.g., group/project/repo)
#   GITLAB_USERNAME      - GitLab username for authentication
#   GITLAB_TOKEN         - GitLab personal access token
#   DOCKER_INPUT_DIR     - Directory containing .tar.gz.txt files
#
# Prerequisites:
#   - Docker must be installed and running
#   - GitLab personal access token with read_registry and write_registry scope
#
# Input:
#   Reads .tar.gz.txt files from DOCKER_INPUT_DIR
#   Expected filename format: <image>_<tag>.tar.gz.txt
#
# Output:
#   Pushes images to: GITLAB_REGISTRY/GITLAB_REGISTRY_PATH/<image>:<tag>
# =============================================================================

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Load and validate configuration
load_config

# Validate required variables
validate_required_vars GITLAB_REGISTRY GITLAB_REGISTRY_PATH GITLAB_USERNAME GITLAB_TOKEN DOCKER_INPUT_DIR

# Resolve paths
DOCKER_INPUT_DIR=$(resolve_path "$DOCKER_INPUT_DIR")

# Validate input directory exists
if [ ! -d "$DOCKER_INPUT_DIR" ]; then
    echo "Error: DOCKER_INPUT_DIR does not exist: $DOCKER_INPUT_DIR"
    exit 1
fi

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed or not in PATH"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo "Error: Docker daemon is not running"
    exit 1
fi

# =============================================================================
# Helper Functions
# =============================================================================

# Extract image name and tag from filename
# e.g., "user-api_0.5.0.tar.gz.txt" -> image="user-api" tag="0.5.0"
parse_filename() {
    local filename=$1
    
    # Remove .tar.gz.txt extension
    local base="${filename%.tar.gz.txt}"
    
    # Split on last underscore: everything before is image name, after is tag
    local image="${base%_*}"
    local tag="${base##*_}"
    
    echo "$image $tag"
}

# Import a single image
import_image() {
    local txt_file=$1
    local filename
    filename=$(basename "$txt_file")
    
    # Parse image name and tag from filename
    local parsed
    parsed=$(parse_filename "$filename")
    local image_name
    local tag
    image_name=$(echo "$parsed" | cut -d' ' -f1)
    tag=$(echo "$parsed" | cut -d' ' -f2)
    
    local target_image="${GITLAB_REGISTRY}/${GITLAB_REGISTRY_PATH}/${image_name}:${tag}"
    
    print_subheader "Importing: $image_name:$tag"
    echo "Source file: $filename"
    echo "Target: $target_image"
    
    # Create temp directory for this import
    local temp_dir
    temp_dir=$(mktemp -d)
    local gz_file="$temp_dir/${image_name}_${tag}.tar.gz"
    local tar_file="$temp_dir/${image_name}_${tag}.tar"
    
    # Step 1: Base64 decode
    echo "Step 1: Decoding base64..."
    if ! base64 -d "$txt_file" > "$gz_file" 2>&1; then
        echo "Error: Failed to decode base64"
        rm -rf "$temp_dir"
        return 1
    fi
    echo "  Decoded to: $gz_file"
    
    # Step 2: Gunzip
    echo "Step 2: Decompressing..."
    if ! gunzip -f "$gz_file" 2>&1; then
        echo "Error: Failed to decompress"
        rm -rf "$temp_dir"
        return 1
    fi
    echo "  Decompressed to: $tar_file"
    
    # Step 3: Load image into Docker
    echo "Step 3: Loading image into Docker..."
    local load_output
    load_output=$(docker load -i "$tar_file" 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to load image"
        echo "$load_output"
        rm -rf "$temp_dir"
        return 1
    fi
    echo "  $load_output"
    
    # Extract the loaded image name from docker load output
    # Output format: "Loaded image: harbor.company.com/library/user-api:0.5.0"
    local loaded_image
    loaded_image=$(echo "$load_output" | grep -oP 'Loaded image: \K.*' | head -n1)
    
    if [ -z "$loaded_image" ]; then
        # Try alternative format: "Loaded image ID: sha256:..."
        # In this case we need to find the image by inspecting
        echo "  Warning: Could not parse loaded image name, searching..."
        loaded_image=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "$image_name" | grep "$tag" | head -n1)
    fi
    
    if [ -z "$loaded_image" ]; then
        echo "Error: Could not determine loaded image name"
        rm -rf "$temp_dir"
        return 1
    fi
    echo "  Loaded image: $loaded_image"
    
    # Step 4: Tag for GitLab registry
    echo "Step 4: Tagging for GitLab registry..."
    if ! docker tag "$loaded_image" "$target_image" 2>&1; then
        echo "Error: Failed to tag image"
        rm -rf "$temp_dir"
        return 1
    fi
    echo "  Tagged as: $target_image"
    
    # Step 5: Push to GitLab registry
    echo "Step 5: Pushing to GitLab registry..."
    if ! docker push "$target_image" 2>&1; then
        echo "Error: Failed to push image"
        rm -rf "$temp_dir"
        return 1
    fi
    echo "  Push complete"
    
    # Step 6: Clean up
    rm -rf "$temp_dir"
    # Optionally remove the loaded and tagged images to save space
    # docker rmi "$loaded_image" "$target_image" 2>/dev/null
    
    echo "Successfully imported: $image_name:$tag"
    return 0
}

# =============================================================================
# Main Execution
# =============================================================================

print_header "Git Migration Suite - Docker Image Import"
echo "Input directory: $DOCKER_INPUT_DIR"
echo "GitLab registry: $GITLAB_REGISTRY"
echo "Registry path: $GITLAB_REGISTRY_PATH"

# Login to GitLab registry
print_subheader "Authenticating with GitLab Registry"
echo "Logging in to $GITLAB_REGISTRY..."
if ! echo "$GITLAB_TOKEN" | docker login "$GITLAB_REGISTRY" -u "$GITLAB_USERNAME" --password-stdin 2>&1; then
    echo "Error: Failed to login to GitLab registry"
    echo "Check GITLAB_USERNAME and GITLAB_TOKEN in .env"
    exit 1
fi
echo "Login successful"

# Find all .tar.gz.txt files
mapfile -t image_files < <(find "$DOCKER_INPUT_DIR" -maxdepth 1 -name "*.tar.gz.txt" -type f | sort)

if [ ${#image_files[@]} -eq 0 ]; then
    echo ""
    echo "No .tar.gz.txt files found in $DOCKER_INPUT_DIR"
    echo "Run docker_export.sh first to export images."
    exit 0
fi

echo ""
echo "Found ${#image_files[@]} image(s) to import:"
for file in "${image_files[@]}"; do
    echo "  - $(basename "$file")"
done

# Process each image
success_count=0
fail_count=0
imported_images=()

for file in "${image_files[@]}"; do
    if import_image "$file"; then
        success_count=$((success_count + 1))
        local parsed
        parsed=$(parse_filename "$(basename "$file")")
        local image_name tag
        image_name=$(echo "$parsed" | cut -d' ' -f1)
        tag=$(echo "$parsed" | cut -d' ' -f2)
        imported_images+=("${image_name}:${tag}")
    else
        fail_count=$((fail_count + 1))
    fi
done

# =============================================================================
# Summary
# =============================================================================

print_header "Summary"
echo "Images imported successfully: $success_count"
[ $fail_count -gt 0 ] && echo "Images failed: $fail_count"

if [ ${#imported_images[@]} -gt 0 ]; then
    echo ""
    echo "Imported images available at:"
    for img in "${imported_images[@]}"; do
        echo "  ${GITLAB_REGISTRY}/${GITLAB_REGISTRY_PATH}/${img}"
    done
fi

if [ $fail_count -gt 0 ]; then
    echo ""
    echo "Some images failed to import. Check the output above for details."
    exit 1
fi

echo ""
echo "Import complete!"