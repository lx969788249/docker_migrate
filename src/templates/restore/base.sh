#!/usr/bin/env bash
set -euo pipefail
umask 077

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BUNDLE_DIR"

say() { echo -e "\033[1;34m$*\033[0m"; }
warn() { echo -e "\033[1;33m$*\033[0m"; }

# @include lib/colors.sh

# @include lib/common.sh

# @include lib/progress.sh

# @include lib/paths.sh

# @include lib/bundle.sh

# @include lib/containers.sh

restore_load_images() {
  local archive="$1" total
  if command -v pv >/dev/null 2>&1; then
    total="$(progress_file_size "$archive")"
    pv -f -s "$total" "$archive" | docker load
  else
    docker load -i "$archive"
  fi
}
