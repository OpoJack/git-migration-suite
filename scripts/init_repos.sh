#!/bin/bash
# =============================================================================
# Git Migration Suite - Initialize Repositories
# =============================================================================
# Purpose:
#   Creates local repository clones from bundles for first-time setup in the
#   destination environment. Use this when you don't have local copies of the
#   repositories yet. Also imports LFS objects if present.
#
# Usage:
#   ./init_repos.sh              # Initialize repos with LFS
#   ./init_repos.sh --no-lfs     # Skip LFS import
#
# Required .env variables:
#   INIT_DEST_DIR      - Directory where repositories will be cloned
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
#   - GitLab repositories must already exist (can be empty)
#   - GitLab personal access token with write_repository scope
#   - Git LFS installed if repositories use LFS
#
# Next Steps:
#   After running this script:
#   1. Add the repository names to repos.txt
#   2. Add INIT_DEST_DIR to DEST_SEARCH_DIRS in .env
#   3. Run apply_bundles.sh to push to GitLab
# =============================================================================

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Load and validate configuration
load_config

# Validate required variables for this script
validate_required_vars INIT_DEST_DIR GITLAB_HOST GITLAB_GROUP GITLAB_USERNAME GITLAB_TOKEN

# Set defaults for optional variables
GITLAB_AUTH_METHOD="${GITLAB_AUTH_METHOD:-https}"
ARCHIVE_INPUT_DIR="${ARCHIVE_INPUT_DIR:-$PROJECT_ROOT}"

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
            echo "  --no-lfs    Skip LFS import (default: include LFS)"
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

# Resolve paths
INIT_DEST_DIR=$(convert_path "$INIT_DEST_DIR")
ARCHIVE_INPUT_DIR=$(resolve_path "$ARCHIVE_INPUT_DIR")

# Create destination directory if it doesn't exist
if [ ! -d "$INIT_DEST_DIR" ]; then
    echo "Creating destination directory: $INIT_DEST_DIR"
    mkdir -p "$INIT_DEST_DIR"
fi

# =============================================================================
# Archive Detection and Extraction
# =============================================================================

print_header "Git Migration Suite - Initialize Repositories"

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

# =============================================================================
# Repository Initialization Function
# =============================================================================

init_repo() {
    local repo=$1
    local bundle_dir="$TEMP_EXTRACT_DIR/$repo"
    local lfs_dir="$bundle_dir/lfs"
    local dest_repo_path="$INIT_DEST_DIR/$repo"

    print_subheader "Initializing: $repo"

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

    # Check if destination already exists
    if [ -d "$dest_repo_path" ]; then
        if [ -d "$dest_repo_path/.git" ]; then
            echo "Warning: Repository already exists at $dest_repo_path"
            echo "Skipping. Use apply_bundles.sh to update existing repositories."
            return 0
        else
            echo "Error: Directory exists but is not a git repository: $dest_repo_path"
            return 1
        fi
    fi

    # Step 1: Clone from bundle
    echo "Step 1: Cloning from bundle..."
    if ! git clone "$bundle_path" "$dest_repo_path" 2>&1; then
        echo "Error: Failed to clone from bundle"
        return 1
    fi
    echo "  Cloned successfully"

    # Change to the new repository
    cd "$dest_repo_path" || return 1

    # Step 2: Rename the bundle remote to 'bundle' (git clone names it 'origin')
    echo "Step 2: Configuring remotes..."
    if git remote get-url origin >/dev/null 2>&1; then
        git remote rename origin bundle 2>/dev/null || true
        echo "  Renamed default remote to 'bundle'"
    fi

    # Step 3: Add GitLab as the 'gitlab' remote
    local gitlab_url
    gitlab_url=$(build_gitlab_url "$repo")
    git remote add gitlab "$gitlab_url"
    echo "  Added 'gitlab' remote"

    # Step 4: Also set GitLab as 'origin' for convenience
    git remote add origin "$gitlab_url" 2>/dev/null || git remote set-url origin "$gitlab_url"
    echo "  Set 'origin' to GitLab"

    # Step 5: Import LFS objects if present
    if [ "$INCLUDE_LFS" = true ] && [ "$has_lfs" = true ]; then
        echo "Step 5: Importing LFS objects..."
        import_lfs_objects "$lfs_dir"
    else
        echo "Step 5: LFS import skipped"
    fi

    # Step 6: Set up tracking for the default branch
    local default_branch
    default_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
    echo "  Default branch: $default_branch"

    echo "Successfully initialized $repo at $dest_repo_path"
    return 0
}

# =============================================================================
# Main Execution
# =============================================================================

print_subheader "Configuration"
echo "Destination directory: $INIT_DEST_DIR"
echo "GitLab host: $GITLAB_HOST"
echo "GitLab group: $GITLAB_GROUP"
echo "Auth method: $GITLAB_AUTH_METHOD"
echo "Include LFS: $INCLUDE_LFS"

success_count=0
skip_count=0
fail_count=0
initialized_repos=()

# Iterate through all directories in the extracted archive
for repo_dir in "$TEMP_EXTRACT_DIR"/*; do
    if [ -d "$repo_dir" ]; then
        repo=$(basename "$repo_dir")
        if init_repo "$repo"; then
            # Check if it was skipped (already exists) vs newly created
            if [ -d "$INIT_DEST_DIR/$repo/.git" ]; then
                initialized_repos+=("$repo")
            fi
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    fi
done

# =============================================================================
# Summary and Next Steps
# =============================================================================

print_header "Summary"
echo "Repositories initialized: $success_count"
[ $fail_count -gt 0 ] && echo "Repositories failed: $fail_count"

if [ ${#initialized_repos[@]} -gt 0 ]; then
    echo ""
    print_header "Next Steps"
    echo ""
    echo "1. Add these repositories to repos.txt:"
    echo "   ----------------------------------------"
    for repo in "${initialized_repos[@]}"; do
        echo "   $repo"
    done
    echo "   ----------------------------------------"
    echo ""
    echo "2. Ensure DEST_SEARCH_DIRS in .env includes:"
    echo "   $INIT_DEST_DIR"
    echo ""
    echo "3. Run apply_bundles.sh to push to GitLab:"
    echo "   ./scripts/apply_bundles.sh"
    echo ""
fi

if [ $fail_count -gt 0 ]; then
    echo ""
    echo "Some repositories failed. Check the output above for details."
    exit 1
fi

echo "Initialization complete!"