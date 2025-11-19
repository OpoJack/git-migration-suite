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
[[ "$REPOS_LIST_FILE" != /* ]] && REPOS_LIST_FILE="$PROJECT_ROOT/$REPOS_LIST_FILE"
[[ "$BUNDLE_OUTPUT_DIR" != /* ]] && BUNDLE_OUTPUT_DIR="$PROJECT_ROOT/$BUNDLE_OUTPUT_DIR"

# Default values
REPO_NAME=""
BRANCHES="$DEFAULT_BRANCHES"

# Parse arguments
while getopts "r:b:" opt; do
  case $opt in
    r) REPO_NAME="$OPTARG" ;;
    b) BRANCHES="$OPTARG" ;;
    *) echo "Usage: $0 [-r repo_name] [-b \"branch1 branch2\"]" >&2; exit 1 ;;
  esac
done

# Convert comma-separated branches to space-separated if needed, or just use as is if passed with spaces
# The user request said "explicitly provide the branches", example "develop, release/abc"
# Let's normalize commas to spaces
BRANCHES=$(echo "$BRANCHES" | tr ',' ' ')

# Function to process a single repo
process_repo() {
    local repo=$1
    local repo_path="$SOURCE_BASE_DIR/$repo"
    local bundle_dir="$BUNDLE_OUTPUT_DIR/$repo"
    
    echo "Processing $repo..."

    if [ ! -d "$repo_path" ]; then
        echo "Error: Repository directory $repo_path does not exist. Skipping."
        return
    fi

    # Create output directory
    mkdir -p "$bundle_dir"

    cd "$repo_path" || return

    # Fetch latest
    echo "Fetching latest changes..."
    git fetch --all --tags

    # Build bundle command
    # We want to bundle branches that exist.
    local refs_to_bundle=""
    
    for branch in $BRANCHES; do
        # Check if branch exists (local or remote tracking)
        # We usually want to bundle the state of the remote refs if we are mirroring, 
        # but the user said "provide branches". Let's assume we want to bundle the tip of these branches.
        # Since we fetched, we might have origin/branch.
        # The user said "target branches develop, release/abc".
        
        if git rev-parse --verify "$branch" >/dev/null 2>&1; then
            refs_to_bundle="$refs_to_bundle $branch"
        elif git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
             refs_to_bundle="$refs_to_bundle origin/$branch"
        else
            echo "Warning: Branch $branch not found in $repo. Skipping branch."
        fi
    done

    # Check if we found any valid branches
    if [ -z "$refs_to_bundle" ]; then
        echo "Warning: No valid branches found to bundle for $repo. Skipping."
        # Clean up the empty directory if it was created
        if [ -d "$bundle_dir" ] && [ -z "$(ls -A "$bundle_dir")" ]; then
            rmdir "$bundle_dir"
        fi
        return
    fi
    
    # Include tags only if we have valid branches
    refs_to_bundle="$refs_to_bundle --tags"

    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local bundle_file="$bundle_dir/${repo}_${timestamp}.bundle"
    
    # Create bundle
    # Using --since="1 month ago" for incremental bundle
    echo "Creating bundle for $repo with refs: $refs_to_bundle"
    if git bundle create "$bundle_file" --since="1 month ago" $refs_to_bundle 2>/dev/null; then
        echo "Successfully created bundle: $bundle_file"
    else
        echo "No commits found in the last month for $repo. Skipping bundle creation."
        # Clean up the empty directory if it was created
        if [ -d "$bundle_dir" ] && [ -z "$(ls -A "$bundle_dir")" ]; then
            rmdir "$bundle_dir"
        fi
        return
    fi
}

# Main execution
if [ -n "$REPO_NAME" ]; then
    process_repo "$REPO_NAME"
else
    # Read from repos.txt
    while IFS= read -r repo || [ -n "$repo" ]; do
        # Skip comments and empty lines
        [[ $repo =~ ^#.*$ ]] && continue
        [[ -z $repo ]] && continue
        process_repo "$repo"
    done < "$REPOS_LIST_FILE"
fi
