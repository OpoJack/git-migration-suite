#!/bin/bash
# =============================================================================
# Git Migration Suite - Docker Image Export
# =============================================================================
# Purpose:
#   Pulls Docker images from a Harbor registry, saves them as tar files, and
#   base64 encodes them for transfer to an isolated environment.
#
# Usage:
#   ./docker_export.sh
#
# Required .env variables:
#   HARBOR_REGISTRY   - Harbor registry URL (e.g., harbor.company.com)
#   DOCKER_OUTPUT_DIR - Directory to save exported images
#
# Config file:
#   docker-images.conf - List of images to export (project/image:tag format)
#
# Prerequisites:
#   - Docker must be installed and running
#   - User must be logged in to Harbor (docker login)
#
# Output:
#   Creates base64-encoded .txt files in DOCKER_OUTPUT_DIR/
#   Filename format: <image>_<tag>.tar.gz.txt
# =============================================================================

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Load and validate configuration
load_config

# Validate required variables
validate_required_vars HARBOR_REGISTRY DOCKER_OUTPUT_DIR

# Resolve paths
DOCKER_OUTPUT_DIR=$(resolve_path "$DOCKER_OUTPUT_DIR")
DOCKER_IMAGES_FILE="$PROJECT_ROOT/docker-images.conf"

# Validate docker-images.conf exists
if [ ! -f "$DOCKER_IMAGES_FILE" ]; then
    echo "Error: docker-images.conf not found at $DOCKER_IMAGES_FILE"
    echo "Please create it with the images you want to export."
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

# Create output directory
mkdir -p "$DOCKER_OUTPUT_DIR"

# =============================================================================
# Helper Functions
# =============================================================================

# Convert image path to safe filename
# e.g., "myproject/webapp:v1.2.3" -> "webapp_v1.2.3"
# Drops the project/namespace prefix, keeps only image name and tag
image_to_filename() {
    local image=$1
    # Extract just the image:tag part (after the last /)
    local image_and_tag="${image##*/}"
    # Replace : with _
    echo "$image_and_tag" | sed 's|:|_|g'
}

# Export a single image
export_image() {
    local image_path=$1
    local full_image="${HARBOR_REGISTRY}/${image_path}"
    local safe_name
    safe_name=$(image_to_filename "$image_path")
    local tar_file="$DOCKER_OUTPUT_DIR/${safe_name}.tar"
    local gz_file="$DOCKER_OUTPUT_DIR/${safe_name}.tar.gz"
    local txt_file="$DOCKER_OUTPUT_DIR/${safe_name}.tar.gz.txt"
    
    print_subheader "Exporting: $image_path"
    echo "Full image: $full_image"
    
    # Step 1: Pull the image
    echo "Step 1: Pulling image..."
    if ! docker pull "$full_image" 2>&1; then
        echo "Error: Failed to pull image $full_image"
        echo "Make sure you are logged in: docker login $HARBOR_REGISTRY"
        return 1
    fi
    echo "  Pull complete"
    
    # Step 2: Save to tar
    echo "Step 2: Saving to tar..."
    if ! docker save "$full_image" -o "$tar_file" 2>&1; then
        echo "Error: Failed to save image to tar"
        return 1
    fi
    local tar_size
    tar_size=$(du -h "$tar_file" | cut -f1)
    echo "  Saved: $tar_file ($tar_size)"
    
    # Step 3: Gzip the tar
    echo "Step 3: Compressing with gzip..."
    if ! gzip -f "$tar_file" 2>&1; then
        echo "Error: Failed to gzip tar file"
        rm -f "$tar_file"
        return 1
    fi
    local gz_size
    gz_size=$(du -h "$gz_file" | cut -f1)
    echo "  Compressed: $gz_file ($gz_size)"
    
    # Step 4: Base64 encode
    echo "Step 4: Encoding to base64..."
    if ! base64 "$gz_file" > "$txt_file" 2>&1; then
        echo "Error: Failed to base64 encode"
        rm -f "$gz_file"
        return 1
    fi
    local txt_size
    txt_size=$(du -h "$txt_file" | cut -f1)
    echo "  Encoded: $txt_file ($txt_size)"
    
    # Step 5: Clean up intermediate files
    rm -f "$gz_file"
    echo "  Cleaned up intermediate files"
    
    echo "Successfully exported: $image_path"
    return 0
}

# =============================================================================
# Main Execution
# =============================================================================

print_header "Git Migration Suite - Docker Image Export"
echo "Harbor registry: $HARBOR_REGISTRY"
echo "Output directory: $DOCKER_OUTPUT_DIR"
echo "Config file: $DOCKER_IMAGES_FILE"

# Count images to process
image_count=0
while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | tr -d '\r' | xargs)
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    image_count=$((image_count + 1))
done < "$DOCKER_IMAGES_FILE"

if [ $image_count -eq 0 ]; then
    echo ""
    echo "No images configured in docker-images.conf"
    echo "Add images to export (one per line, format: project/image:tag)"
    exit 0
fi

echo "Images to export: $image_count"

# Process each image
success_count=0
fail_count=0
exported_files=()

while IFS= read -r line || [ -n "$line" ]; do
    # Clean up line
    line=$(echo "$line" | tr -d '\r' | xargs)
    
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    
    if export_image "$line"; then
        success_count=$((success_count + 1))
        safe_name=$(image_to_filename "$line")
        exported_files+=("${safe_name}.tar.gz.txt")
    else
        fail_count=$((fail_count + 1))
    fi
done < "$DOCKER_IMAGES_FILE"

# =============================================================================
# Summary
# =============================================================================

print_header "Summary"
echo "Images exported successfully: $success_count"
[ $fail_count -gt 0 ] && echo "Images failed: $fail_count"

if [ ${#exported_files[@]} -gt 0 ]; then
    echo ""
    echo "Exported files:"
    for file in "${exported_files[@]}"; do
        local size
        size=$(du -h "$DOCKER_OUTPUT_DIR/$file" 2>/dev/null | cut -f1)
        echo "  $file ($size)"
    done
    echo ""
    echo "Output directory: $DOCKER_OUTPUT_DIR"
    echo ""
    echo "Transfer these .txt files to the destination environment,"
    echo "then use docker_upload.sh to load them into the registry."
fi

if [ $fail_count -gt 0 ]; then
    echo ""
    echo "Some images failed to export. Check the output above for details."
    exit 1
fi

echo ""
echo "Export complete!"