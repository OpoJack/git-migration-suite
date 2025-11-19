# Git Migration Suite

This project provides a set of scripts to automate the transfer of git repository updates between environments (e.g., from an internet-connected GitLab to a disconnected/air-gapped instance) using git bundles.

## Prerequisites

- **Environment**: Linux/Unix-like environment with Bash.
- **Dependencies**: `git`, `zip`, and `unzip` must be installed.
- **Authentication**: SSH keys or credentials must be configured for non-interactive `git` operations (fetch/push).
- **Directory Structure**:
    - Source repositories must exist in `SOURCE_BASE_DIR` (defined in config).
    - Destination repositories must exist in `DEST_BASE_DIR` (defined in config).
    - Repository directory names must match the entries in `repos.txt`.
- **Remotes**: Destination repositories must have an `origin` remote pointing to the target GitLab instance.

## 🚀 Getting Started

### 1. Configuration
1. Copy `example.env` to `.env`:
   ```bash
   cp example.env .env
   ```
2. Edit `.env` to configure your environment:
   - **SOURCE_BASE_DIR**: Local path to source repositories.
   - **DEST_BASE_DIR**: Local path to destination repositories.
   - **REPOS_LIST_FILE**: Path to the list of repositories (relative to project root, default: `repos.txt`).
   - **DEFAULT_BRANCHES**: Comma-separated list of branches to bundle (e.g., `main,develop`).

### 2. Repository List
Populate `repos.txt` with the names of the repositories to process, one per line.
```text
my-awesome-service
another-microservice
```

## 🛠️ Usage

### Step 1: Create Bundles
On the source environment, run the bundle script to generate incremental bundles for your repositories.
```bash
./scripts/bundle_repos.sh
```
*Options:*
- `-r <repo>`: Process a specific repository.
- `-b "<branch1> <branch2>"`: Override default branches.

### Step 2: Archive
Create a timestamped zip archive of the generated bundles for easy transfer.
```bash
./scripts/zip_bundles.sh
```

### Step 3: Apply Changes
Transfer the zip archive to the destination environment and run the apply script.
```bash
./scripts/apply_bundles.sh
```
*Options:*
- `-f <zip_file>`: Specify a specific zip file (defaults to the latest found).
- `-r <repo>`: Apply changes for a specific repository.

---

## 🔍 Technical Breakdown

### `scripts/bundle_repos.sh`
- Iterates through repositories defined in `repos.txt`.
- Performs a `git fetch --all --tags` on the source to ensure up-to-date refs.
- Checks for the existence of target branches (`main`, `develop`, etc.) to avoid errors.
- Runs `git bundle create` with `--since="1 month ago"` to capture recent history.
- Explicitly includes tags in the bundle.

### `scripts/zip_bundles.sh`
- Compresses the `bundles/` directory into a single zip file named `migration-suite-<timestamp>.zip`.
- Ensures the directory structure is preserved for the apply script.

### `scripts/apply_bundles.sh`
- Extracts the provided zip archive.
- For each repository:
    1. Verifies the bundle integrity using `git bundle verify`.
    2. Fetches bundle refs into a temporary namespace `refs/remotes/bundle-source/*` to avoid conflicts with local checked-out branches.
    3. Pushes tags to `origin`.
    4. Pushes updated branches from `refs/remotes/bundle-source/*` to `refs/heads/*` on `origin`.
