#!/bin/bash
# =============================================================================
# Git Migration Suite - Common Library
# =============================================================================
# This file contains shared functions used by all migration scripts.
# It should be sourced by other scripts, not executed directly.
# =============================================================================

# Determine project root (parent of scripts directory)
if [ -z "$PROJECT_ROOT" ]; then
    PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Load .env configuration
load_config() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/.env"
    else
        echo "Error: .env file not found at $PROJECT_ROOT/.env"
        echo "Please copy example.env to .env and configure it."
        exit 1
    fi
}

# Validate that required variables are set
# Usage: validate_required_vars VAR1 VAR2 VAR3
validate_required_vars() {
    local missing=()
    for var in "$@"; do
        if [ -z "${!var}" ]; then
            missing+=("$var")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo "Error: The following required variables are not set in .env:"
        for var in "${missing[@]}"; do
            echo "  - $var"
        done
        exit 1
    fi
}

# Convert Windows paths to Git Bash/MSYS format if needed
# Usage: convert_path "/some/path" -> outputs converted path
convert_path() {
    local path="$1"
    if [[ "$path" =~ ^[A-Za-z]:\\ ]]; then
        # Convert C:\path\to\dir to /c/path/to/dir
        echo "$path" | sed 's|^\([A-Za-z]\):|/\L\1|' | sed 's|\\|/|g'
    else
        echo "$path"
    fi
}

# Resolve a path relative to PROJECT_ROOT if it's not absolute
# Usage: resolve_path "relative/path" -> outputs absolute path
resolve_path() {
    local path="$1"
    if [[ "$path" != /* ]]; then
        echo "$PROJECT_ROOT/$path"
    else
        echo "$path"
    fi
}

# Print a section header for better output readability
print_header() {
    local title="$1"
    echo ""
    echo "============================================================================="
    echo "$title"
    echo "============================================================================="
}

# Print a sub-section header
print_subheader() {
    local title="$1"
    echo ""
    echo "--- $title ---"
}