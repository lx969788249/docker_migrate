#!/usr/bin/env bash
set -euo pipefail
umask 077

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BUNDLE_DIR"

# @include lib/colors.sh

# @include lib/common.sh

# @include lib/log.sh

# @include lib/screen.sh

# @include lib/errors.sh

# @include lib/progress.sh

# @include lib/paths.sh

# @include lib/bundle.sh

# @include lib/containers.sh

# 细节写入日志（--verbose 时也显示）；回滚等需要用户看到的过程用 warn。
say() { detail "$*"; }
warn() {
  log_line "$*"
  screen_clear_line
  printf '    %s\n' "$*" >&2
}

# 恢复脚本的阶段编号：由主脚本调用时接在下载、校验之后（共 8 步），
# 在迁移包目录手动执行时从 1 开始（共 5 步）。
restore_stage() {
  stage_begin "$((${DM_STAGE_OFFSET:-0} + $1))" "${DM_STAGE_TOTAL:-5}" "$2"
}

log_init restore-manual
export DM_SUMMARY_ARMED=1

restore_load_images() {
  local archive="$1" count_file="${2:-}"
  progress_meter "$count_file" <"$archive" | dm_quiet docker load
}
