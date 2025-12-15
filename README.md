# Git Migration Suite

A collection of bash scripts for migrating git repositories between isolated environments using git bundles.

## Overview

This suite enables the synchronization of git repositories from a corporate environment to an isolated/air-gapped environment. It works by:

1. **Creating bundles** - Extracting recent commits and tags from source repositories into portable `.bundle` files
2. **Packaging** - Combining all bundles into a single, transferable archive (optionally base64-encoded)
3. **Applying bundles** - Importing the bundled changes into destination repositories and pushing to their remote

```
┌─────────────────────┐                      ┌─────────────────────┐
│  Source Environment │                      │  Dest Environment   │
│  (Corporate)        │                      │  (Isolated)         │
│                     │                      │                     │
│  ┌───────────────┐  │     Transfer         │  ┌───────────────┐  │
│  │ Source Repos  │  │  ─────────────────►  │  │  Dest Repos   │  │
│  │ (GitHub/etc)  │  │   .tar.gz.txt        │  │  (GitLab)     │  │
│  └───────────────┘  │                      │  └───────────────┘  │
│         │           │                      │         ▲           │
│         ▼           │                      │         │           │
│  create_bundles.sh  │                      │  apply_bundles.sh   │
│  zip_bundles.sh     │                      │                     │
└─────────────────────┘                      └─────────────────────┘
```

## Quick Start

### Initial Setup

1. **Clone or copy this suite** to both environments

2. **Configure the environment**:
   ```bash
   cp example.env .env
   ```
3. **Edit `.env`** with your paths:

   ```bash
   # Source environment (where you create bundles)
   # Comma-separated list of directories to search for repos
   SOURCE_SEARCH_DIRS="/path/to/your/repos"
   DEFAULT_BRANCHES="main,develop"

   # Destination environment (where you apply bundles)
   # Comma-separated list of directories to search for repos
   DEST_SEARCH_DIRS="/repos/main-group/project,/repos/main-group/other-project"

   # GitLab configuration (destination environment)
   GITLAB_HOST="gitlab.example.com"
   GITLAB_GROUP="my-group"
   GITLAB_USERNAME="your-username"
   GITLAB_TOKEN="glpat-your-token-here"
   ```

4. **Create `repos.txt`** listing your repositories:
   ```
   my-application
   shared-library
   another-repo
   ```

### In the Source Environment

```bash
# Create bundles for all repositories
./scripts/create_bundles.sh

# Package bundles for transfer
./scripts/zip_bundles.sh
```

This creates `migration-suite_<timestamp>.tar.gz.txt` ready for transfer.

### In the Destination Environment

```bash
# Copy the .tar.gz.txt file to the destination environment
# Then apply the bundles
./scripts/apply_bundles.sh
```

## Scripts

### create_bundles.sh

Creates git bundles from source repositories.

**Usage:**

```bash
./scripts/create_bundles.sh                      # All repos in repos.txt
./scripts/create_bundles.sh -r my-repo           # Single repository
./scripts/create_bundles.sh -b "main develop"    # Custom branches
./scripts/create_bundles.sh --no-lfs             # Skip LFS objects
./scripts/create_bundles.sh --lfs-current        # Only LFS for current checkout
```

**What it does:**

- Fetches latest changes from all remotes
- Creates incremental bundles (only commits from the lookback period)
- Includes relevant tags that point to commits in the date range
- Exports Git LFS objects (default: all history)
- Prioritizes remote-tracking branches (`origin/main`) over local branches

**Output:**

```
bundles/
├── my-application/
│   ├── my-application_2024-01-15_10-30-00.bundle
│   └── lfs/           # LFS objects (if repo uses LFS)
│       └── ...
```

### zip_bundles.sh

Packages all bundles into a single archive.

**Usage:**

```bash
./scripts/zip_bundles.sh        # Create base64-encoded archive
./scripts/zip_bundles.sh -k     # Keep .tar.gz file too
./scripts/zip_bundles.sh -s     # Skip base64, output only .tar.gz
```

**Output:**

- `migration-suite_<timestamp>.tar.gz.txt` - Base64-encoded archive (default)
- `migration-suite_<timestamp>.tar.gz` - Plain archive (with `-s` or `-k`)

The base64 encoding allows the archive to be transferred through text-only channels if needed.

### apply_bundles.sh

Applies bundles to destination repositories and pushes to GitLab.

**Usage:**

```bash
./scripts/apply_bundles.sh            # Apply bundles with LFS
./scripts/apply_bundles.sh --no-lfs   # Skip LFS import/push
```

No arguments needed - all configuration comes from `.env`.

**What it does:**

1. Finds the latest archive in `ARCHIVE_INPUT_DIR` (or project root)
2. Extracts the archive (handles both `.tar.gz` and `.tar.gz.txt`)
3. For each repository:
   - Verifies bundle integrity
   - Fetches changes into the local repository
   - Imports LFS objects if present
   - Configures the `gitlab` remote with credentials from `.env`
   - Pushes branches, tags, and LFS objects to GitLab
   - Cleans up temporary refs

**Prerequisites:**

- Destination repositories must already be cloned locally (use `init_repos.sh` for first-time setup)
- GitLab personal access token with `write_repository` scope
- `.env` configured with GitLab credentials
- Git LFS installed if repositories use LFS

### init_repos.sh

Initializes local repositories from bundles for first-time setup.

**Usage:**

```bash
./scripts/init_repos.sh              # Initialize with LFS
./scripts/init_repos.sh --no-lfs     # Skip LFS import
```

No arguments needed - all configuration comes from `.env`.

**What it does:**

1. Finds the latest archive in `ARCHIVE_INPUT_DIR` (or project root)
2. Extracts the archive
3. For each bundle:
   - Clones the bundle to `INIT_DEST_DIR/<repo>`
   - Configures `gitlab` and `origin` remotes with credentials
   - Imports LFS objects if present
   - Skips repos that already exist locally

**After running:**

1. Add the repository names to `repos.txt`
2. Add `INIT_DEST_DIR` to `DEST_SEARCH_DIRS` in `.env`
3. Run `apply_bundles.sh` to push to GitLab

**Prerequisites:**

- GitLab repositories must already exist (can be empty)
- GitLab personal access token with `write_repository` scope
- Git LFS installed if repositories use LFS

### docker_export.sh

Exports Docker images from Harbor registry for transfer.

**Usage:**

```bash
./scripts/docker_export.sh
```

No arguments needed - reads from `docker-images.conf` and `.env`.

**What it does:**

1. Reads image list from `docker-images.conf`
2. For each image:
   - Pulls from Harbor registry
   - Saves to tar file
   - Base64 encodes to `.txt` file
   - Cleans up intermediate tar

**Config file (`docker-images.conf`):**

```
# Format: project/image:tag (registry from .env is prepended)
myproject/webapp:v1.2.3
myproject/webapp:latest
# myproject/old-app:v1.0.0  (commented = skipped)
```

**Prerequisites:**

- Docker installed and running
- Logged in to Harbor (`docker login harbor.company.com`)

### docker_import.sh

Imports Docker images and pushes to GitLab Container Registry.

**Usage:**

```bash
./scripts/docker_import.sh
```

No arguments needed - reads `.tar.gz.txt` files from `DOCKER_INPUT_DIR`.

**What it does:**

1. Logs in to GitLab registry using credentials from `.env`
2. For each `.tar.gz.txt` file in `DOCKER_INPUT_DIR`:
   - Base64 decodes the file
   - Decompresses with gunzip
   - Loads image into Docker
   - Tags for GitLab registry
   - Pushes to GitLab

**Prerequisites:**

- Docker installed and running
- GitLab token with `read_registry` and `write_registry` scope

## Configuration

### .env File

**Source Environment Variables:**

| Variable             | Description                                     | Example                   |
| -------------------- | ----------------------------------------------- | ------------------------- |
| `SOURCE_SEARCH_DIRS` | Comma-separated directories to search for repos | `/c/repos,/d/other-repos` |
| `REPOS_LIST_FILE`    | File listing repos to process                   | `repos.txt`               |
| `DEFAULT_BRANCHES`   | Branches to bundle by default                   | `main,develop`            |
| `BUNDLE_OUTPUT_DIR`  | Where to save bundles                           | `bundles`                 |
| `BUNDLE_LOOKBACK`    | How far back to include commits                 | `1 month ago`             |

**Docker Image Variables (Source):**

| Variable            | Description                   | Example              |
| ------------------- | ----------------------------- | -------------------- |
| `HARBOR_REGISTRY`   | Source Harbor registry URL    | `harbor.company.com` |
| `DOCKER_OUTPUT_DIR` | Where to save exported images | `images`             |

**Docker Image Variables (Destination):**

| Variable               | Description                      | Example              |
| ---------------------- | -------------------------------- | -------------------- |
| `GITLAB_REGISTRY`      | GitLab container registry URL    | `gitlab.company.com` |
| `GITLAB_REGISTRY_PATH` | Path to umbrella repo for images | `group/project/repo` |
| `DOCKER_INPUT_DIR`     | Where to find images to import   | `images`             |

**Destination Environment Variables:**

| Variable             | Description                                          | Example                                   |
| -------------------- | ---------------------------------------------------- | ----------------------------------------- |
| `DEST_SEARCH_DIRS`   | Comma-separated directories to search for repos      | `/repos/group/project,/repos/group/other` |
| `INIT_DEST_DIR`      | Directory where new repos are cloned (init_repos.sh) | `/repos/new-imports`                      |
| `GITLAB_HOST`        | GitLab server hostname                               | `gitlab.example.com`                      |
| `GITLAB_GROUP`       | GitLab group/namespace                               | `my-group`                                |
| `GITLAB_USERNAME`    | GitLab username                                      | `john.doe`                                |
| `GITLAB_TOKEN`       | GitLab personal access token                         | `glpat-xxxxxxxxxxxx`                      |
| `GITLAB_AUTH_METHOD` | `https` (default) or `ssh`                           | `https`                                   |
| `ARCHIVE_INPUT_DIR`  | Where to look for archives (optional)                | `/path/to/incoming`                       |

### repos.txt

One repository name per line. Comments start with `#`:

```
# Production applications
my-application
api-service

# Shared libraries
shared-library
common-utils
```

## Directory Structure

```
git-migration-suite/
├── .env                    # Your configuration (create from example.env)
├── example.env             # Template configuration
├── repos.txt               # List of git repositories to process
├── docker-images.conf      # List of Docker images to export
├── README.md               # This file
├── scripts/
│   ├── common.sh           # Shared functions
│   ├── create_bundles.sh   # Bundle creation script
│   ├── zip_bundles.sh      # Archive packaging script
│   ├── init_repos.sh       # First-time repository setup
│   ├── apply_bundles.sh    # Bundle application script
│   ├── docker_export.sh    # Docker image export script
│   └── docker_import.sh    # Docker image import script
├── bundles/                # Generated git bundles (created automatically)
│   ├── repo1/
│   │   ├── repo1_2024-01-15_10-30-00.bundle
│   │   └── lfs/            # LFS objects (if repo uses LFS)
│   │       └── ...
│   └── repo2/
│       └── repo2_2024-01-15_10-30-00.bundle
└── images/                 # Exported Docker images (created automatically)
    ├── myproject_webapp_v1.2.3.tar.txt
    └── myproject_webapp_latest.tar.txt
```

## Workflow Examples

### Regular Sync (Weekly/Monthly)

```bash
# Source environment
cd /path/to/git-migration-suite
./scripts/create_bundles.sh
./scripts/zip_bundles.sh

# Transfer migration-suite_*.tar.gz.txt to destination

# Destination environment
cd /path/to/git-migration-suite
# Place the .tar.gz.txt file in the project root (or ARCHIVE_INPUT_DIR)
./scripts/apply_bundles.sh
```

### First-Time Setup in Destination Environment

Use `init_repos.sh` to create local repositories from bundles:

```bash
cd /path/to/git-migration-suite

# Place the .tar.gz.txt file in the project root
# Then initialize repositories from the bundles
./scripts/init_repos.sh

# The script will output next steps, but generally:
# 1. Add repo names to repos.txt
# 2. Add INIT_DEST_DIR to DEST_SEARCH_DIRS in .env
# 3. Push to GitLab
./scripts/apply_bundles.sh
```

Alternatively, if GitLab already has the repositories and you want to clone from there:

```bash
cd /path/to/dest_repos

# Clone each repository from GitLab
git clone https://gitlab.example.com/my-group/repo-name.git
# Repeat for each repository...
```

### Single Repository Sync

```bash
# Create bundle for just one repo
./scripts/create_bundles.sh -r my-critical-repo

# Package it
./scripts/zip_bundles.sh

# Apply on destination
./scripts/apply_bundles.sh -r my-critical-repo
```

### Custom Branch Set

```bash
# Bundle specific branches
./scripts/create_bundles.sh -b "main release/v2.0 hotfix/urgent"
```

### Full History (First-Time Migration)

For initial migration, you may want all history. Set a very long lookback:

```bash
# In .env, temporarily set:
BUNDLE_LOOKBACK="10 years ago"

# Or override for this run by editing .env temporarily
```

## Troubleshooting

### "Bundle verification failed"

This usually means the destination repository is missing commits that the bundle depends on. Solutions:

1. **Create a full bundle** (longer lookback period)
2. **Ensure destination has base commits** - Clone fresh if needed
3. **Check for force-pushes** in source that rewrote history

### "No commits found in lookback period"

The branch hasn't been updated recently. This is informational, not an error.

### "Repository directory does not exist"

- Check `SOURCE_BASE_DIR` or `DEST_BASE_DIR` in `.env`
- Ensure the repository is cloned in both environments
- Check for typos in `repos.txt`

### Windows/Git Bash Path Issues

The scripts automatically convert Windows paths (`C:\path`) to Git Bash format (`/c/path`). If you still have issues:

- Use forward slashes in `.env`
- Use Git Bash-style paths: `/c/Users/name/repos`

### Base64 Decode Fails

If `apply_bundles.sh` fails to decode:

- Ensure the file wasn't corrupted during transfer
- Check for line ending issues (should be Unix-style)
- Try transferring the `.tar.gz` directly with `-s` flag

## Platform Compatibility

| Platform           | create_bundles | zip_bundles | apply_bundles |
| ------------------ | -------------- | ----------- | ------------- |
| Linux              | ✅             | ✅          | ✅            |
| macOS              | ✅             | ✅          | ✅            |
| Git Bash (Windows) | ✅             | ✅          | ✅            |
| WSL                | ✅             | ✅          | ✅            |

## Notes

- **Bundles are incremental** - Only recent commits (per `BUNDLE_LOOKBACK`) are included to keep bundle sizes small
- **Tags are filtered** - Only tags pointing to commits within the lookback period are included
- **Remote branches preferred** - The scripts use `origin/branch` when available to ensure you're bundling the latest fetched state
- **Safe operations** - The scripts don't modify source repositories; they only read from them
- **Destination must exist** - Repositories must be cloned in the destination environment before applying bundles

## Git LFS Support

The migration suite fully supports Git LFS (Large File Storage):

**Export (create_bundles.sh):**

- Automatically detects if a repository uses LFS
- Fetches all LFS objects by default (`git lfs fetch --all`)
- Exports LFS objects to `bundles/<repo>/lfs/`
- Use `--no-lfs` to skip LFS export
- Use `--lfs-current` to only fetch LFS for current checkout (faster, but incomplete history)

**Import (apply_bundles.sh / init_repos.sh):**

- Automatically imports LFS objects if present in the bundle
- Copies objects to `.git/lfs/objects/`
- Pushes LFS objects to GitLab with `git lfs push --all`
- Use `--no-lfs` to skip LFS import/push

**Requirements:**

- Git LFS must be installed on both source and destination machines
- GitLab must have LFS enabled for the project

**Note:** LFS objects are stored per-repository in the bundle. If multiple repos share the same LFS files, they will be duplicated in the archive.

## License

Internal use only.
