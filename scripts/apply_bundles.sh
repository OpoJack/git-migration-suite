#!/bin/bash

# Load config
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
else
    echo "Error: .env file not found. Please copy example.env to .env and configure it."
    exit 1
fi

# Resolve relative paths
[[ "$BUNDLE_OUTPUT_DIR" != /* ]] && BUNDLE_OUTPUT_DIR="$PROJECT_ROOT/$BUNDLE_OUTPUT_DIR"

ARCHIVE_FILE=""
REPO_NAME=""

# Parse arguments
while getopts "f:r:" opt; do
  case $opt in
    f) ARCHIVE_FILE="$OPTARG" ;;
    r) REPO_NAME="$OPTARG" ;;
    *) echo "Usage: $0 [-f archive_file] [-r repo_name]" >&2; exit 1 ;;
  esac
done

# If no archive file provided, try to find the latest one
if [ -z "$ARCHIVE_FILE" ]; then
    # Assuming archive files are in the parent of BUNDLE_OUTPUT_DIR (project root/bundles/..)
    # Actually config says BUNDLE_OUTPUT_DIR is .../bundles. 
    # zip_bundles.sh puts it in .../bundles/../$ARCHIVE_NAME which is project root.
    # Let's look in the project root or where config.env is relative to.
    PROJECT_ROOT="$(dirname "$SOURCE_BASE_DIR")" 
    # Wait, SOURCE_BASE_DIR is defined in config.
    # Let's just look in the directory above BUNDLE_OUTPUT_DIR as per zip script
    SEARCH_DIR="$(dirname "$BUNDLE_OUTPUT_DIR")"
    ARCHIVE_FILE=$(ls -t "$SEARCH_DIR"/migration-suite-*.tar.gz 2>/dev/null | head -n 1)
    
    if [ -z "$ARCHIVE_FILE" ]; then
        echo "Error: No archive file provided and none found in $SEARCH_DIR."
        exit 1
    fi
    echo "Auto-detected latest archive file: $ARCHIVE_FILE"
fi

TEMP_EXTRACT_DIR=$(mktemp -d)
echo "Extracting $ARCHIVE_FILE to $TEMP_EXTRACT_DIR..."
tar -xzf "$ARCHIVE_FILE" -C "$TEMP_EXTRACT_DIR"

# Function to apply bundle to a repo
apply_bundle() {
    local repo=$1
    # Find the bundle file - it now has a timestamp in the name
    local bundle_path=$(ls "$TEMP_EXTRACT_DIR/$repo/${repo}_"*.bundle 2>/dev/null | head -n 1)
    local dest_repo_path="$DEST_BASE_DIR/$repo"

    echo "Applying bundle for $repo..."

    if [ -z "$bundle_path" ] || [ ! -f "$bundle_path" ]; then
        echo "Warning: Bundle file for $repo not found in $TEMP_EXTRACT_DIR/$repo/. Skipping."
        return
    fi

    if [ ! -d "$dest_repo_path" ]; then
        echo "Error: Destination repository $dest_repo_path does not exist. Skipping."
        return
    fi

    cd "$dest_repo_path" || return

    # Verify bundle
    if ! git bundle verify "$bundle_path"; then
        echo "Error: Bundle verification failed for $repo. Skipping."
        return
    fi

    # Get list of refs in the bundle
    # We want to fetch all heads from the bundle
    # git bundle list-heads "$bundle_path" gives us the refs
    
    echo "Fetching from bundle..."
    # Fetch into a temporary namespace to avoid conflicts with checked out branches
    if git fetch "$bundle_path" "+refs/heads/*:refs/remotes/bundle-source/*" "+refs/tags/*:refs/tags/*"; then
        echo "Successfully fetched changes from bundle."
        
        # Now push to origin
        echo "Pushing changes to origin (GitLab)..."
        # Push from the bundle-source remotes to origin heads
        # We iterate over the fetched refs
        
        # Push tags first
        git push origin --tags
        
        # Push branches
        # We can use a glob refspec if the remote supports it, or iterate.
        # git push origin "refs/remotes/bundle-source/*:refs/heads/*" might work if we want to push everything.
        # But let's be safe and push what we have.
        
        if git push origin "refs/remotes/bundle-source/*:refs/heads/*"; then
             echo "Successfully pushed to origin."
        else
             echo "Warning: Failed to push some refs to origin."
        fi
    else
        echo "Error: Failed to fetch from bundle."
    fi
}

# Main execution
if [ -n "$REPO_NAME" ]; then
    apply_bundle "$REPO_NAME"
else
    # Iterate through directories in the extracted zip
    for repo_dir in "$TEMP_EXTRACT_DIR"/*; do
        if [ -d "$repo_dir" ]; then
            repo=$(basename "$repo_dir")
            apply_bundle "$repo"
        fi
    done
fi

# Cleanup
rm -rf "$TEMP_EXTRACT_DIR"
echo "Done."
