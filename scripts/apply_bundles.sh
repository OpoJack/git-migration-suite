#!/bin/bash
# =============================================================================
# Git Migration Suite - Apply Bundles
# =============================================================================
# Purpose:
#   Applies git bundles to destination repositories in the isolated environment.
#   For each repository:
#     1. Searches for the local repo in DEST_SEARCH_DIRS
#     2. Extracts bundle from the archive
#     3. Verifies bundle integrity
#     4. Fetches changes into the local repository
#     5. Imports LFS objects if present
#     6. Configures GitLab remote with credentials
#     7. Pushes branches, tags, and LFS objects to GitLab
#
# Usage:
#   ./apply_bundles.sh                # Apply bundles with LFS
#   ./apply_bundles.sh --no-lfs       # Skip LFS import/push
#
# Required .env variables:
#   DEST_SEARCH_DIRS   - Comma-separated directories to search for repositories
#   GITLAB_HOST        - GitLab server hostname (e.g., gitlab.example.com)
#   GITLAB_GROUP       - GitLab group/namespace for repositories
#   GITLAB_USERNAME    - GitLab username for authentication
#   GITLAB_TOKEN       - GitLab personal access token
#   GITLAB_AUTH_METHOD - "https" (default) or "ssh"
#
# Optional .env variables:
#   ARCHIVE_INPUT_DIR  - Directory to search for archives (default: project root)
#
# Prerequisites:
#   - Destination repositories must already be cloned locally
#   - GitLab personal access token with write_repository scope
#   - Git LFS installed if repositories use LFS
# =============================================================================

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Load and validate configuration
load_config

# Validate required variables for this script
validate_required_vars DEST_SEARCH_DIRS GITLAB_HOST GITLAB_GROUP GITLAB_USERNAME GITLAB_TOKEN

# Set defaults for optional variables
GITLAB_AUTH_METHOD="${GITLAB_AUTH_METHOD:-https}"
ARCHIVE_INPUT_DIR="${ARCHIVE_INPUT_DIR:-$PROJECT_ROOT}"

# Resolve archive input directory
ARCHIVE_INPUT_DIR=$(resolve_path "$ARCHIVE_INPUT_DIR")

# Default: include LFS
INCLUDE_LFS=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-lfs)
            INCLUDE_LFS=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--no-lfs]"
            echo "  --no-lfs    Skip LFS import and push (default: include LFS)"
            echo "  -h, --help  Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--no-lfs]" >&2
            exit 1
            ;;
    esac
done

# Parse DEST_SEARCH_DIRS into an array
IFS=',' read -ra DEST_DIRS_ARRAY <<< "$DEST_SEARCH_DIRS"

# Convert and validate each destination directory
VALID_DEST_DIRS=()
for dir in "${DEST_DIRS_ARRAY[@]}"; do
    # Trim whitespace
    dir=$(echo "$dir" | xargs)
    # Convert Windows paths if needed
    dir=$(convert_path "$dir")
    
    if [ -d "$dir" ]; then
        VALID_DEST_DIRS+=("$dir")
    else
        echo "Warning: Destination directory does not exist, skipping: $dir"
    fi
done

if [ ${#VALID_DEST_DIRS[@]} -eq 0 ]; then
    echo "Error: No valid destination directories found in DEST_SEARCH_DIRS"
    exit 1
fi

# =============================================================================
# Archive Detection and Extraction
# =============================================================================

print_header "Git Migration Suite - Apply Bundles"

echo "Searching for archives in: $ARCHIVE_INPUT_DIR"

# Look for base64-encoded archives first, then plain tar.gz
ARCHIVE_FILE=$(ls -t "$ARCHIVE_INPUT_DIR"/migration-suite_*.tar.gz.txt 2>/dev/null | head -n 1)

if [ -z "$ARCHIVE_FILE" ]; then
    ARCHIVE_FILE=$(ls -t "$ARCHIVE_INPUT_DIR"/migration-suite_*.tar.gz 2>/dev/null | head -n 1)
fi

if [ -z "$ARCHIVE_FILE" ]; then
    echo "Error: No archive file found in $ARCHIVE_INPUT_DIR"
    echo ""
    echo "Please copy a migration-suite_*.tar.gz.txt file to: $ARCHIVE_INPUT_DIR"
    exit 1
fi

echo "Found archive: $ARCHIVE_FILE"

# Create temporary directory for extraction
TEMP_EXTRACT_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_EXTRACT_DIR"' EXIT

print_subheader "Extracting Archive"

# Handle base64-encoded archives
if [[ "$ARCHIVE_FILE" == *.txt ]]; then
    echo "Decoding base64 archive..."
    DECODED_TAR="${TEMP_EXTRACT_DIR}/archive.tar.gz"
    base64 -d "$ARCHIVE_FILE" > "$DECODED_TAR"
    tar -xzf "$DECODED_TAR" -C "$TEMP_EXTRACT_DIR"
    rm "$DECODED_TAR"
else
    tar -xzf "$ARCHIVE_FILE" -C "$TEMP_EXTRACT_DIR"
fi

echo "Extracted to temporary directory"

# List extracted repositories
echo "Repositories in archive:"
for repo_dir in "$TEMP_EXTRACT_DIR"/*; do
    if [ -d "$repo_dir" ]; then
        local_lfs=""
        if [ -d "$repo_dir/lfs" ]; then
            local_lfs=" (includes LFS)"
        fi
        echo "  - $(basename "$repo_dir")$local_lfs"
    fi
done

# =============================================================================
# Repository Search Function
# =============================================================================

# Function to find a repository in the search directories
# Returns the full path to the repo, or empty string if not found
find_repo() {
    local repo=$1
    
    for dir in "${VALID_DEST_DIRS[@]}"; do
        local candidate="$dir/$repo"
        if [ -d "$candidate/.git" ]; then
            echo "$candidate"
            return 0
        fi
    done
    
    # Not found
    echo ""
    return 1
}

# =============================================================================
# GitLab Remote Configuration
# =============================================================================

# Build the GitLab remote URL based on auth method
build_gitlab_url() {
    local repo=$1
    
    if [ "$GITLAB_AUTH_METHOD" = "ssh" ]; then
        echo "git@${GITLAB_HOST}:${GITLAB_GROUP}/${repo}.git"
    else
        # HTTPS with embedded credentials
        echo "https://${GITLAB_USERNAME}:${GITLAB_TOKEN}@${GITLAB_HOST}/${GITLAB_GROUP}/${repo}.git"
    fi
}

# Configure or update the gitlab remote
configure_gitlab_remote() {
    local repo=$1
    local gitlab_url
    gitlab_url=$(build_gitlab_url "$repo")
    
    # Check if 'gitlab' remote exists
    if git remote get-url gitlab >/dev/null 2>&1; then
        echo "  Updating 'gitlab' remote URL..."
        git remote set-url gitlab "$gitlab_url"
    else
        echo "  Adding 'gitlab' remote..."
        git remote add gitlab "$gitlab_url"
    fi
}

# =============================================================================
# LFS Functions
# =============================================================================

# Import LFS objects from the bundle's lfs directory
import_lfs_objects() {
    local lfs_source_dir=$1
    
    if [ ! -d "$lfs_source_dir" ]; then
        return 0
    fi
    
    echo "  Importing LFS objects..."
    
    # Ensure .git/lfs/objects exists
    mkdir -p .git/lfs/objects
    
    # Copy LFS objects preserving directory structure
    cp -r "$lfs_source_dir"/* .git/lfs/objects/
    
    local lfs_count
    lfs_count=$(find "$lfs_source_dir" -type f | wc -l)
    echo "  Imported $lfs_count LFS object(s)"
    
    return 0
}

# Push LFS objects to the remote
push_lfs_objects() {
    echo "  Pushing LFS objects to GitLab..."
    
    # Configure LFS to use the gitlab remote URL
    local gitlab_url
    gitlab_url=$(build_gitlab_url "$repo")
    
    # Push all LFS objects
    if git lfs push --all gitlab 2>&1; then
        echo "  LFS objects pushed successfully"
    else
        echo "  Warning: Some LFS objects may have failed to push"
    fi
}

# =============================================================================
# Bundle Application Function
# =============================================================================

apply_bundle() {
    local repo=$1
    local bundle_dir="$TEMP_EXTRACT_DIR/$repo"
    local lfs_dir="$bundle_dir/lfs"

    print_subheader "Processing: $repo"

    # Find the bundle file (handles timestamped names)
    local bundle_path
    bundle_path=$(ls "$bundle_dir"/"${repo}_"*.bundle 2>/dev/null | head -n 1)

    if [ -z "$bundle_path" ] || [ ! -f "$bundle_path" ]; then
        echo "Warning: No bundle file found for $repo in $bundle_dir"
        return 1
    fi
    
    echo "Bundle: $(basename "$bundle_path")"
    
    # Check for LFS objects
    local has_lfs=false
    if [ -d "$lfs_dir" ] && [ -n "$(ls -A "$lfs_dir" 2>/dev/null)" ]; then
        has_lfs=true
        echo "LFS objects: yes"
    else
        echo "LFS objects: no"
    fi

    # Find the repository in search directories
    local dest_repo_path
    dest_repo_path=$(find_repo "$repo")
    
    if [ -z "$dest_repo_path" ]; then
        echo "Error: Repository '$repo' not found in any search directory:"
        for dir in "${VALID_DEST_DIRS[@]}"; do
            echo "  - $dir"
        done
        echo ""
        echo "Please clone the repository first, then re-run this script."
        return 1
    fi
    
    echo "Found at: $dest_repo_path"

    # Change to destination repository
    cd "$dest_repo_path" || return 1

    # Step 1: Verify bundle integrity
    echo "Step 1: Verifying bundle..."
    if ! git bundle verify "$bundle_path" 2>&1; then
        echo "Error: Bundle verification failed for $repo"
        echo "This may indicate:"
        echo "  - The bundle is corrupted"
        echo "  - The destination repo is missing prerequisite commits"
        echo "  - You may need to create a full bundle (increase BUNDLE_LOOKBACK)"
        return 1
    fi
    echo "  Bundle verified successfully"

    # Step 2: Fetch from bundle into local repository
    echo "Step 2: Fetching from bundle into local repository..."
    
    # Fetch branches into a temporary namespace and tags directly
    # Handle both refs/heads/* (local branches) and refs/remotes/origin/* (remote tracking)
    if ! git fetch "$bundle_path" \
        '+refs/heads/*:refs/remotes/bundle-import/*' \
        '+refs/remotes/origin/*:refs/remotes/bundle-import/*' \
        '+refs/tags/*:refs/tags/*' 2>&1; then
        echo "Error: Failed to fetch from bundle"
        return 1
    fi
    echo "  Fetch complete"

    # List what we fetched
    echo "  Imported refs:"
    git for-each-ref --format='    %(refname:short)' refs/remotes/bundle-import/ 2>/dev/null
    
    # Step 3: Import LFS objects if present
    if [ "$INCLUDE_LFS" = true ] && [ "$has_lfs" = true ]; then
        echo "Step 3: Importing LFS objects..."
        import_lfs_objects "$lfs_dir"
    else
        echo "Step 3: LFS import skipped"
    fi
    
    # Step 4: Configure GitLab remote
    echo "Step 4: Configuring GitLab remote..."
    configure_gitlab_remote "$repo"

    # Step 5: Push to GitLab
    echo "Step 5: Pushing to GitLab..."
    
    # Push tags
    echo "  Pushing tags..."
    if git push gitlab --tags 2>&1; then
        echo "  Tags pushed successfully"
    else
        echo "  Warning: Some tags may have failed to push (they may already exist)"
    fi
    
    # Push branches from the bundle-import namespace to gitlab
    # This maps refs/remotes/bundle-import/* to refs/heads/* on gitlab
    echo "  Pushing branches..."
    if git push gitlab 'refs/remotes/bundle-import/*:refs/heads/*' 2>&1; then
        echo "  Branches pushed successfully"
    else
        echo "  Warning: Some branches may have failed to push"
        # Don't fail completely - some branches may have pushed successfully
    fi
    
    # Step 6: Push LFS objects if present
    if [ "$INCLUDE_LFS" = true ] && [ "$has_lfs" = true ]; then
        echo "Step 6: Pushing LFS objects..."
        push_lfs_objects
    else
        echo "Step 6: LFS push skipped"
    fi

    # Step 7: Clean up temporary refs
    echo "Step 7: Cleaning up temporary refs..."
    git for-each-ref --format='%(refname)' refs/remotes/bundle-import/ | while read -r ref; do
        git update-ref -d "$ref" 2>/dev/null
    done

    echo "Successfully applied bundle for $repo"
    return 0
}

# =============================================================================
# Main Execution
# =============================================================================

print_subheader "Configuration"
echo "Destination directories:"
for dir in "${VALID_DEST_DIRS[@]}"; do
    echo "  - $dir"
done
echo "GitLab host: $GITLAB_HOST"
echo "GitLab group: $GITLAB_GROUP"
echo "Auth method: $GITLAB_AUTH_METHOD"
echo "Include LFS: $INCLUDE_LFS"

success_count=0
fail_count=0

# Iterate through all directories in the extracted archive
for repo_dir in "$TEMP_EXTRACT_DIR"/*; do
    if [ -d "$repo_dir" ]; then
        repo=$(basename "$repo_dir")
        if apply_bundle "$repo"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    fi
done

# =============================================================================
# Summary
# =============================================================================

print_header "Summary"
echo "Repositories processed successfully: $success_count"
[ $fail_count -gt 0 ] && echo "Repositories failed: $fail_count"

if [ $fail_count -gt 0 ]; then
    echo ""
    echo "Some repositories failed. Check the output above for details."
    exit 1
fi

echo ""
echo "Migration complete!"
echo ""
echo "The archive has been processed. You may want to move or delete it:"
echo "  $ARCHIVE_FILE"