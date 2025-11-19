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
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
ZIP_NAME="migration-suite-${TIMESTAMP}.zip"
ZIP_PATH="$BUNDLE_OUTPUT_DIR/../$ZIP_NAME"

echo "Zipping bundles from $BUNDLE_OUTPUT_DIR..."

if [ ! -d "$BUNDLE_OUTPUT_DIR" ]; then
    echo "Error: Bundle directory $BUNDLE_OUTPUT_DIR does not exist."
    exit 1
fi

# Zip the contents of the bundle output directory
# We want the zip to contain the repo folders (e.g. repo1/repo1.bundle)
cd "$BUNDLE_OUTPUT_DIR" || exit 1

# Check if there are files to zip
if [ -z "$(ls -A .)" ]; then
   echo "Error: Bundle directory is empty. Nothing to zip."
   exit 1
fi

zip -r "$ZIP_PATH" .

echo "Successfully created zip archive: $ZIP_PATH"
