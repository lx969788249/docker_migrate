#!/usr/bin/env bash
# docker_migrate_perfect.sh — Docker 容器一键迁移（源服务器使用）
#
# 依赖：bash >= 4.0（需要关联数组 declare -A 和 mapfile）
# macOS 用户请用 Homebrew bash: brew install bash && /usr/local/bin/bash docker_migrate_perfect.sh
#
# 功能概要：
# 1. 自动检测并安装依赖（docker / jq / python3 / tar / gzip / curl / openssl）
# 2. 按“独立容器 / docker compose 容器组”展示并选择要迁移的容器
# 3. 打包：镜像、命名卷、绑定目录、（可用的）Compose 配置
# 4. 生成 manifest.json 和 restore.sh
# 5. 加密迁移包后启动带安全随机路径的 HTTP 服务；退出时关闭 HTTP、重启停机容器、清理临时文件
#
# 本版修复：
# - 恢复时同名容器已存在但端口绑定不同，会删除并重建容器，避免“恢复成功但端口丢失”。
# - 单容器 docker compose 项目按独立容器恢复，确保可以从 inspect 还原 -p 端口参数。
# - 端口绑定还原支持空 HostPort 跳过、IPv6 HostIp 加方括号。
# - 恢复已暂停容器时会先 unpause，再 start / remove。
#
# 环境变量：
# PORT=8080             默认 HTTP 端口（会询问你要不要改；被占用则向后尝试）
# ADVERTISE_HOST=IP     下载链接里使用的域名/IP（默认自动探测）
# RESTORE_KEEP=1        恢复后保留下载包与解压目录
# RESTORE_CLEAN_ALL=1   恢复失败也强制清理文件
# RESTORE_BASE=/path    新服务器恢复目录
# RESTORE_ROLLBACK_BASE=/path 失败回滚后需保留的 Compose 配置目录（默认 ~/.docker_migrate_rollback）
# DOCKER_MIGRATE_SNAPSHOT=auto|always|never 容器可写层快照策略（默认仅在有改动时快照）
#
# 参数：
# --no-stop             不停机备份（可能不一致，数据库慎用）
# --include=name1,name2 按容器名称精确匹配，只迁移指定容器（不使用分组菜单）

# bash 版本检测：需要 4.0+（关联数组 / mapfile）
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || ((BASH_VERSINFO[0] < 4)); then
  echo "[ERR] 本脚本需要 bash >= 4.0，当前版本：${BASH_VERSION:-unknown}" >&2
  echo "[ERR] macOS 用户请用 Homebrew bash: brew install bash && /usr/local/bin/bash docker_migrate_perfect.sh" >&2
  exit 1
fi

set -euo pipefail
umask 077

SCRIPT_VERSION="2.3.0"
BUNDLE_ENCRYPTION_SCHEME="aes-256-ctr-hmac-sha256-v1"
declare -a IDS=()
declare -a RUNS=()
declare -a STOPPED_ON_BACKUP=()
declare -a BACKUP_FAILURES=()
declare -a TEMP_IMAGES=()

# @include lib/ui.sh

# @include lib/system.sh

# @include lib/progress.sh

# @include lib/paths.sh

# @include lib/crypto.sh

# @include lib/bundle.sh

# @include backup/http.sh

# @include backup/capture.sh

# @include templates.sh

# @include restore/client.sh

# @include entry.sh

# @include backup/flow/10-setup.sh

# @include backup/flow/20-select.sh

# @include backup/flow/30-metadata.sh

# @include backup/flow/40-snapshot.sh

# @include backup/flow/50-package.sh

# @include backup/flow/60-serve.sh
