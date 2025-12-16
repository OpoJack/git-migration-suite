#!/bin/bash
# =============================================================================
# Git Migration Suite - Create Bundles
# =============================================================================
# Purpose:
#   Creates git bundles from source repositories for transfer to an isolated
#   environment. Bundles contain recent commits (based on BUNDLE_LOOKBACK),
#   relevant tags, and Git LFS objects.
#
# Usage:
#   ./create_bundles.sh                    # Process all repos in REPOS_LIST_FILE
#   ./create_bundles.sh -r repo_name       # Process a single repository
#   ./create_bundles.sh -b "main develop"  # Override default branches
#   ./create_bundles.sh -r repo -b main    # Single repo, specific branch
#   ./create_bundles.sh --no-lfs           # Skip LFS objects
#   ./create_bundles.sh --lfs-current      # Only fetch LFS for current checkout
#
# Required .env variables:
#   SOURCE_SEARCH_DIRS - Comma-separated directories to search for repositories
#   REPOS_LIST_FILE    - File listing repositories to process
#   BUNDLE_OUTPUT_DIR  - Where to save generated bundles
#   DEFAULT_BRANCHES   - Branches to bundle (can be overridden with -b)
#   BUNDLE_LOOKBACK    - How far back to include commits (e.g., "1 month ago")
#
# Output:
#   Creates timestamped .bundle files in BUNDLE_OUTPUT_DIR/<repo>/
#   Creates lfs/ directory with LFS objects if repo uses LFS
# =============================================================================

set -e

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Load and validate configuration
load_config

# Validate required variables for this script
validate_required_vars SOURCE_SEARCH_DIRS REPOS_LIST_FILE BUNDLE_OUTPUT_DIR DEFAULT_BRANCHES BUNDLE_LOOKBACK

# Resolve paths
REPOS_LIST_FILE=$(resolve_path "$REPOS_LIST_FILE")
BUNDLE_OUTPUT_DIR=$(resolve_path "$BUNDLE_OUTPUT_DIR")

# Parse SOURCE_SEARCH_DIRS into an array
IFS=',' read -ra SOURCE_DIRS_ARRAY <<< "$SOURCE_SEARCH_DIRS"

# Convert and validate each source directory
VALID_SOURCE_DIRS=()
for dir in "${SOURCE_DIRS_ARRAY[@]}"; do
    # Trim whitespace
    dir=$(echo "$dir" | xargs)
    # Convert Windows paths if needed
    dir=$(convert_path "$dir")
    
    if [ -d "$dir" ]; then
        VALID_SOURCE_DIRS+=("$dir")
    else
        echo "Warning: Source directory does not exist, skipping: $dir"
    fi
done

if [ ${#VALID_SOURCE_DIRS[@]} -eq 0 ]; then
    echo "Error: No valid source directories found in SOURCE_SEARCH_DIRS"
    exit 1
fi

# Validate that repos list file exists
if [ ! -f "$REPOS_LIST_FILE" ]; then
    echo "Error: REPOS_LIST_FILE does not exist: $REPOS_LIST_FILE"
    exit 1
fi

# Default values
REPO_NAME=""
BRANCHES="$DEFAULT_BRANCHES"
INCLUDE_LFS=true
LFS_FETCH_ALL=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r)
            REPO_NAME="$2"
            shift 2
            ;;
        -b)
            BRANCHES="$2"
            shift 2
            ;;
        --no-lfs)
            INCLUDE_LFS=false
            shift
            ;;
        --lfs-current)
            LFS_FETCH_ALL=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-r repo_name] [-b \"branch1 branch2\"] [--no-lfs] [--lfs-current]"
            echo "  -r            Process a single repository"
            echo "  -b            Override default branches (comma or space separated)"
            echo "  --no-lfs      Skip LFS objects (default: include LFS)"
            echo "  --lfs-current Only fetch LFS for current checkout (default: fetch all)"
            echo "  -h, --help    Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [-r repo_name] [-b \"branch1 branch2\"] [--no-lfs] [--lfs-current]" >&2
            exit 1
            ;;
    esac
done

# Convert comma-separated branches to space-separated
BRANCHES=$(echo "$BRANCHES" | tr ',' ' ')

# Function to find a repository in the search directories
# Returns the full path to the repo, or empty string if not found
find_repo() {
    local repo=$1
    
    for dir in "${VALID_SOURCE_DIRS[@]}"; do
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

# Function to check if a repo uses LFS
repo_uses_lfs() {
    # Check if .gitattributes contains LFS filters
    if [ -f ".gitattributes" ] && grep -q "filter=lfs" ".gitattributes" 2>/dev/null; then
        return 0
    fi
    # Also check if there's an lfs directory with objects
    if [ -d ".git/lfs/objects" ] && [ -n "$(ls -A .git/lfs/objects 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

# Function to export LFS objects
export_lfs_objects() {
    local repo=$1
    local bundle_dir=$2
    local lfs_dir="$bundle_dir/lfs"
    
    echo "Exporting LFS objects..."
    
    # Fetch LFS objects
    if [ "$LFS_FETCH_ALL" = true ]; then
        echo "  Fetching all LFS objects (this may take a while)..."
        if ! git lfs fetch --all 2>&1; then
            echo "  Warning: git lfs fetch --all failed, trying without --all"
            git lfs fetch 2>&1 || true
        fi
    else
        echo "  Fetching LFS objects for current checkout..."
        git lfs fetch 2>&1 || true
    fi
    
    # Check if there are any LFS objects to copy
    if [ ! -d ".git/lfs/objects" ] || [ -z "$(ls -A .git/lfs/objects 2>/dev/null)" ]; then
        echo "  No LFS objects found to export"
        return 0
    fi
    
    # Create LFS output directory
    mkdir -p "$lfs_dir"
    
    # Copy LFS objects preserving directory structure
    echo "  Copying LFS objects..."
    cp -r .git/lfs/objects/* "$lfs_dir/"
    
    # Count and report
    local lfs_count
    lfs_count=$(find "$lfs_dir" -type f | wc -l)
    local lfs_size
    lfs_size=$(du -sh "$lfs_dir" 2>/dev/null | cut -f1)
    echo "  Exported $lfs_count LFS object(s) ($lfs_size)"
    
    return 0
}

# Function to process a single repository
process_repo() {
    local repo=$1
    local bundle_dir="$BUNDLE_OUTPUT_DIR/$repo"
    
    print_subheader "Processing: $repo"
    
    # Find the repository in search directories
    local repo_path
    repo_path=$(find_repo "$repo")
    
    if [ -z "$repo_path" ]; then
        echo "Error: Repository '$repo' not found in any search directory:"
        for dir in "${VALID_SOURCE_DIRS[@]}"; do
            echo "  - $dir"
        done
        return 1
    fi
    
    echo "Found at: $repo_path"

    # Remove old bundles and LFS for this repo
    if [ -d "$bundle_dir" ]; then
        echo "Removing old bundles in $bundle_dir..."
        rm -rf "$bundle_dir"
    fi

    # Create output directory
    mkdir -p "$bundle_dir"

    # Use a subshell to handle directory change safely
    (
        cd "$repo_path" || exit 1

        # Fetch latest from all remotes
        echo "Fetching latest changes..."
        if ! git fetch --all --tags --force 2>&1; then
            echo "Error: git fetch failed for $repo"
            exit 1
        fi

        # Build list of refs to bundle
        local refs_to_bundle=""
        
        for branch in $BRANCHES; do
            # Prioritize remote tracking branches (guaranteed up-to-date after fetch)
            if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
                refs_to_bundle="$refs_to_bundle origin/$branch"
                echo "  Found remote branch: origin/$branch"
            elif git rev-parse --verify "$branch" >/dev/null 2>&1; then
                refs_to_bundle="$refs_to_bundle $branch"
                echo "  Found local branch: $branch (no remote tracking)"
            else
                echo "  Warning: Branch '$branch' not found, skipping"
            fi
        done

        # Check if we found any valid branches
        if [ -z "$refs_to_bundle" ]; then
            echo "Warning: No valid branches found for $repo. Skipping."
            exit 0
        fi

        # Calculate the lookback date for tag filtering
        local since_date
        since_date=$(date -d "$BUNDLE_LOOKBACK" +"%Y-%m-%d" 2>/dev/null || \
                     date -v-1m +"%Y-%m-%d" 2>/dev/null || \
                     date +"%Y-%m-%d")
        
        # Find tags within our date range that are reachable from our branches
        local tags_to_include=""
        echo "Checking tags (since $since_date)..."
        
        for tag in $(git tag 2>/dev/null); do
            local tag_commit
            tag_commit=$(git rev-list -n 1 "$tag" 2>/dev/null)
            if [ -n "$tag_commit" ]; then
                local commit_date
                commit_date=$(git log -1 --format=%ci "$tag_commit" 2>/dev/null)
                if [ -n "$commit_date" ]; then
                    if [[ "$commit_date" > "$since_date" ]] || [[ "$commit_date" == "$since_date"* ]]; then
                        # Check if tag is reachable from any of our branches
                        for ref in $refs_to_bundle; do
                            if git merge-base --is-ancestor "$tag_commit" "$ref" 2>/dev/null; then
                                tags_to_include="$tags_to_include $tag"
                                echo "  Including tag: $tag"
                                break
                            fi
                        done
                    fi
                fi
            fi
        done

        # Build revision ranges for incremental bundles
        local bundle_refs=""
        
        for ref in $refs_to_bundle; do
            # Get the commit from the lookback period on this branch
            local base
            base=$(git rev-list -1 --before="$BUNDLE_LOOKBACK" "$ref" 2>/dev/null)
            if [ -n "$base" ]; then
                # Include commits after base up to branch tip
                bundle_refs="$bundle_refs $base..$ref"
            else
                # Branch is younger than lookback period, include all
                bundle_refs="$bundle_refs $ref"
            fi
        done

        # Generate timestamp and bundle filename
        local timestamp
        timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
        local bundle_file="$bundle_dir/${repo}_${timestamp}.bundle"
        
        # Create the bundle
        echo "Creating bundle: ${repo}_${timestamp}.bundle"
        echo "  Refs: $bundle_refs"
        [ -n "$tags_to_include" ] && echo "  Tags:$tags_to_include"
        
        # shellcheck disable=SC2086
        if git bundle create "$bundle_file" $bundle_refs $tags_to_include 2>&1; then
            local size
            size=$(du -h "$bundle_file" | cut -f1)
            echo "Successfully created bundle ($size): $bundle_file"
        else
            echo "No commits found in lookback period for $repo. Skipping bundle creation."
            exit 2
        fi
        
        # Handle LFS objects
        if [ "$INCLUDE_LFS" = true ]; then
            if repo_uses_lfs; then
                export_lfs_objects "$repo" "$bundle_dir"
            else
                echo "No LFS configuration detected for $repo"
            fi
        else
            echo "LFS export skipped (--no-lfs flag)"
        fi
    )
    
    local subshell_exit=$?
    
    # Clean up empty directories
    if [ $subshell_exit -ne 0 ]; then
        if [ -d "$bundle_dir" ] && [ -z "$(ls -A "$bundle_dir" 2>/dev/null)" ]; then
            rmdir "$bundle_dir" 2>/dev/null
        fi
        # Exit code 2 means no commits found - not a failure
        [ $subshell_exit -eq 2 ] && return 0
        return $subshell_exit
    fi
    
    return 0
}

# =============================================================================
# Main Execution
# =============================================================================

print_header "Git Migration Suite - Create Bundles"
echo "Source directories:"
for dir in "${VALID_SOURCE_DIRS[@]}"; do
    echo "  - $dir"
done
echo "Output directory: $BUNDLE_OUTPUT_DIR"
echo "Branches: $BRANCHES"
echo "Lookback period: $BUNDLE_LOOKBACK"
echo "Include LFS: $INCLUDE_LFS"
[ "$INCLUDE_LFS" = true ] && echo "LFS fetch mode: $([ "$LFS_FETCH_ALL" = true ] && echo "all history" || echo "current checkout only")"

if [ -n "$REPO_NAME" ]; then
    # Process single repository
    process_repo "$REPO_NAME"
    exit $?
else
    # Process all repositories from list
    echo "Repository list: $REPOS_LIST_FILE"
    
    success_count=0
    skip_count=0
    fail_count=0
    
    while IFS= read -r repo || [ -n "$repo" ]; do
        # Clean up line (remove carriage returns from Windows files)
        repo=$(echo "$repo" | tr -d '\r' | xargs)
        
        # Skip comments and empty lines
        [[ "$repo" =~ ^#.*$ ]] && continue
        [[ -z "$repo" ]] && continue
        
        if process_repo "$repo"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
            echo "Error processing $repo. Stopping."
            exit 1
        fi
    done < "$REPOS_LIST_FILE"
    
    print_header "Summary"
    echo "Repositories processed: $success_count"
    [ $skip_count -gt 0 ] && echo "Repositories skipped: $skip_count"
    [ $fail_count -gt 0 ] && echo "Repositories failed: $fail_count"
fi