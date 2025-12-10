#!/bin/bash
# =============================================================================
# Git Migration Suite - Package Bundles
# =============================================================================
# Purpose:
#   Packages all generated bundles into a single archive for transfer to the
#   isolated environment. Creates a base64-encoded tar.gz file that can be
#   safely transferred via text-based methods if needed.
#
# Usage:
#   ./zip_bundles.sh              # Create archive from BUNDLE_OUTPUT_DIR
#   ./zip_bundles.sh -k           # Keep the .tar.gz file (don't delete after base64)
#   ./zip_bundles.sh -s           # Skip base64 encoding, keep only .tar.gz
#
# Required .env variables:
#   BUNDLE_OUTPUT_DIR - Directory containing the bundle files to archive
#
# Output:
#   Creates migration-suite_<timestamp>.tar.gz.txt (base64 encoded) in the
#   parent directory of BUNDLE_OUTPUT_DIR
# =============================================================================

set -e

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Load and validate configuration
load_config

# Validate required variables for this script
validate_required_vars BUNDLE_OUTPUT_DIR

# Resolve paths
BUNDLE_OUTPUT_DIR=$(resolve_path "$BUNDLE_OUTPUT_DIR")

# Parse arguments
KEEP_TAR=false
SKIP_BASE64=false

while getopts "ksh" opt; do
    case $opt in
        k) KEEP_TAR=true ;;
        s) SKIP_BASE64=true ;;
        h)
            echo "Usage: $0 [-k] [-s]"
            echo "  -k  Keep the .tar.gz file after base64 encoding"
            echo "  -s  Skip base64 encoding, output only .tar.gz"
            echo "  -h  Show this help message"
            exit 0
            ;;
        *)
            echo "Usage: $0 [-k] [-s]" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# Main Execution
# =============================================================================

print_header "Git Migration Suite - Package Bundles"

# Validate bundle directory exists
if [ ! -d "$BUNDLE_OUTPUT_DIR" ]; then
    echo "Error: Bundle directory does not exist: $BUNDLE_OUTPUT_DIR"
    exit 1
fi

# Check if there are files to archive
if [ -z "$(ls -A "$BUNDLE_OUTPUT_DIR" 2>/dev/null)" ]; then
    echo "Error: Bundle directory is empty: $BUNDLE_OUTPUT_DIR"
    echo "Run create_bundles.sh first to generate bundles."
    exit 1
fi

# Generate archive names
TIMESTAMP=$(date +"%Y-%m-%d_%I-%M_%p")
ARCHIVE_NAME="migration-suite_${TIMESTAMP}.tar.gz"
OUTPUT_DIR="$(dirname "$BUNDLE_OUTPUT_DIR")"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
BASE64_PATH="${ARCHIVE_PATH}.txt"

echo "Bundle directory: $BUNDLE_OUTPUT_DIR"
echo "Output directory: $OUTPUT_DIR"

# Count bundles
bundle_count=$(find "$BUNDLE_OUTPUT_DIR" -name "*.bundle" -type f 2>/dev/null | wc -l)
echo "Found $bundle_count bundle file(s)"

# Create tar.gz archive
print_subheader "Creating Archive"
echo "Archive: $ARCHIVE_NAME"

cd "$BUNDLE_OUTPUT_DIR" || exit 1
tar -czf "$ARCHIVE_PATH" .

archive_size=$(du -h "$ARCHIVE_PATH" | cut -f1)
echo "Archive created: $ARCHIVE_PATH ($archive_size)"

if [ "$SKIP_BASE64" = true ]; then
    print_header "Complete"
    echo "Archive ready: $ARCHIVE_PATH"
    exit 0
fi

# Base64 encode the archive
print_subheader "Encoding to Base64"
echo "This may take a moment for large archives..."

base64 "$ARCHIVE_PATH" > "$BASE64_PATH"

base64_size=$(du -h "$BASE64_PATH" | cut -f1)
echo "Base64 file created: $BASE64_PATH ($base64_size)"

# Clean up tar.gz unless -k flag was provided
if [ "$KEEP_TAR" = false ]; then
    rm "$ARCHIVE_PATH"
    echo "Removed intermediate archive: $ARCHIVE_PATH"
fi

# =============================================================================
# Summary
# =============================================================================

print_header "Complete"
echo "Bundles packaged: $bundle_count"
if [ "$KEEP_TAR" = true ]; then
    echo "Archive file: $ARCHIVE_PATH"
fi
echo "Base64 file: $BASE64_PATH"
echo ""
echo "Transfer $BASE64_PATH to the destination environment,"
echo "then run apply_bundles.sh to import the changes."