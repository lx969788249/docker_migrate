# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`docker_migrate_perfect.sh` is a single-file bash script for one-click Docker container migration between servers. It supports backup (source server) and restore (target server) modes, handling images, named volumes, bind mounts, networks, and docker compose projects.

## Usage & Testing

```bash
# Syntax check (always run after edits)
bash -n docker_migrate_perfect.sh

# Source server — backup mode (interactive)
bash docker_migrate_perfect.sh

# Source server — backup specific containers non-interactively
bash docker_migrate_perfect.sh --include=nginx,redis

# Target server — restore mode
bash docker_migrate_perfect.sh  # select option 2

# Environment overrides
PORT=9090 bash docker_migrate_perfect.sh
ADVERTISE_HOST=10.0.0.5 bash docker_migrate_perfect.sh
```

## Architecture

The script has two code paths selected at startup via interactive prompt:

**Mode 1 — Backup (source server):**
1. Detect & install dependencies via package manager (`pm_detect` → `pm_install`)
2. Present interactive menu grouping containers into "standalone" vs "docker compose project"
3. Single-container compose projects (1 container in the project) are treated as standalone — they use `docker inspect` metadata for port restoration via `docker run`, avoiding port loss that occurs with compose-only restore
4. Stop containers (optional, for consistency; skipped with `--no-stop`)
5. Backup volumes (via `alpine:3.20` tar) and bind mounts to `bundle/{volumes,binds}/`
6. Save images with `docker image save` → `images.tar`
7. Copy compose config files from original working directories
8. Generate `manifest.json` (metadata index) and `restore.sh` (self-contained restore script)
9. Package everything into a single `.tar.gz`
10. Serve via embedded Python3 HTTP server with a random secret path; output the download URL
11. On exit: kill HTTP server, restart stopped containers, clean up temp files

**Mode 2 — Restore (target server):**
1. Download the `.tar.gz` from the given URL, extract
2. Overwrite the bundled `restore.sh` with the current script's built-in version (ensures latest fixes)
3. Execute `restore.sh`: load images → restore volumes → restore binds → restore compose projects → restore standalone containers → connect extra networks

### Key Functions

| Function | Purpose |
|----------|---------|
| `pm_detect` / `pm_install` / `need_bin` | Cross-distro package manager abstraction (apt/dnf/yum/zypper/apk) |
| `ensure_docker_running` | Start Docker daemon if not running |
| `write_run_script` | Generate per-container `runs/<name>.sh` using `docker inspect` metadata |
| `write_bundle_restore_script` | Generate the main `restore.sh` executed on the target |
| `progress_docker_save` | Save images with progress spinner (pv-backed or custom spin loop) |
| `pick_advertise_url` | Auto-detect public/local IP for the download link |
| `pick_free_port` | Find an available port, incrementing from the given default |
| `json_array_from_lines` | Convert newline-separated input to a JSON array via jq |

### Generated Bundle Structure

```
bundle/<random-id>/
├── manifest.json          # Index of images, networks, projects, volumes, binds, run scripts
├── restore.sh             # Self-contained restore script (overwritten at restore time)
├── images.tar             # docker image save output
├── runs/<name>.sh         # Per-container docker run scripts (standalone containers only)
├── volumes/vol_<name>.tgz # Named volume backups
├── binds/bind_<path>.tgz  # Bind mount backups
├── compose/<project>/     # Copied compose files and .env
└── meta/*.inspect.json    # docker inspect output for each container
```

## Key Design Decisions

- **Port binding restoration**: The most subtle part. Docker ports can only be set at container creation time. If a container already exists on the target with different port bindings, `restore.sh` must delete and recreate it, not just start it. Port bindings are extracted from `HostConfig.PortBindings` with special handling for empty HostPort (skip) and IPv6 HostIp (add brackets).
- **Single-container compose → standalone**: Compose projects with only 1 container are migrated as standalone `docker run` containers to preserve port bindings from `docker inspect`.
- **Containers are NOT auto-started after backup**: They're stopped only if the user opts in; `graceful_exit` restarts them.
- **`set -euo pipefail`**: Strict bash mode throughout. All edits must maintain this.
- **Root/sudo**: `asudo()` wraps commands with sudo only when not already root.
- **Generated scripts are self-contained**: `restore.sh` and per-container `runs/*.sh` contain all logic needed to restore without the main script.
- **Compose networks**: External networks are created if missing; conflicting networks (wrong project label) are removed before `docker compose up`.

## Conventions

- Color functions: `BLUE` (info), `YEL` (warn), `RED` (error), `OK` (success), `CYA` (banner/cyan)
- Chinese user-facing messages, English comments for code logic
- Use `<<'EOF'` (quoted heredoc) when embedding scripts to prevent variable expansion
- `jq` is used for all JSON manipulation; it's a required dependency
- The script is designed to be run via `curl | bash`, so avoid external file dependencies
