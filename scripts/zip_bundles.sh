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

# Generate timestamp
TIMESTAMP=$(date +"%Y-%m-%d_%I-%M_%p")
ARCHIVE_NAME="migration-suite_${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="$BUNDLE_OUTPUT_DIR/../$ARCHIVE_NAME"

echo "Creating archive from $BUNDLE_OUTPUT_DIR..."

if [ ! -d "$BUNDLE_OUTPUT_DIR" ]; then
    echo "Error: Bundle directory $BUNDLE_OUTPUT_DIR does not exist."
    exit 1
fi

# Create tar.gz archive of the bundle output directory
# We want the archive to contain the repo folders (e.g. repo1/repo1.bundle)
cd "$BUNDLE_OUTPUT_DIR" || exit 1

# Check if there are files to archive
if [ -z "$(ls -A .)" ]; then
   echo "Error: Bundle directory is empty. Nothing to archive."
   exit 1
fi

tar -czf "$ARCHIVE_PATH" .

echo "Successfully created archive: $ARCHIVE_PATH"
