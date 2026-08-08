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

SCRIPT_VERSION="2.2.0"
BUNDLE_ENCRYPTION_SCHEME="aes-256-ctr-hmac-sha256-v1"
declare -a IDS=()
declare -a RUNS=()
declare -a STOPPED_ON_BACKUP=()
declare -a BACKUP_FAILURES=()
declare -a TEMP_IMAGES=()

#####################################
# 基础函数 & 依赖管理
#####################################
BLUE() { echo -e "\033[1;34m$*\033[0m"; }
YEL() { echo -e "\033[1;33m$*\033[0m"; }
RED() { echo -e "\033[1;31m$*\033[0m"; }
OK() { echo -e "\033[1;32m$*\033[0m"; }
CYA() { echo -e "\033[1;36m$*\033[0m"; }

format_elapsed() {
  local seconds="${1:-0}"
  ((seconds < 0)) && seconds=0
  if ((seconds >= 3600)); then
    printf '%d 小时 %d 分 %d 秒\n' "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
  elif ((seconds >= 60)); then
    printf '%d 分 %d 秒\n' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%d 秒\n' "$seconds"
  fi
}

result_rule() {
  printf '%s\n' '━━━━━━━━━━ Docker 迁移结果 ━━━━━━━━━━'
}

result_end_rule() {
  printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

print_restore_result_summary() {
  local status="$1" stage="$2" container_line="$3" data_line="$4"
  local cleanup_line="$5" diagnostic_dir="$6" rollback_dir="$7" elapsed="$8"

  printf '\n'
  result_rule
  case "$status" in
    SUCCESS)
      printf '结果：✅ 恢复成功\n'
      [[ -z "$container_line" ]] || printf '%s\n' "$container_line"
      [[ -z "$data_line" ]] || printf '%s\n' "$data_line"
      printf '验证：完整性校验、服务启动与健康检查均已通过\n'
      ;;
    FAILED_ROLLED_BACK)
      printf '结果：❌ 恢复失败，已安全回滚\n'
      printf '失败阶段：%s\n' "${stage:-未知阶段}"
      printf '目标端状态：旧服务与原数据已恢复\n'
      ;;
    INTERRUPTED_ROLLED_BACK)
      printf '结果：⚠️ 恢复已中断，已安全回滚\n'
      printf '中断阶段：%s\n' "${stage:-未知阶段}"
      printf '目标端状态：旧服务与原数据已恢复\n'
      ;;
    FAILED_ROLLBACK_INCOMPLETE | INTERRUPTED_ROLLBACK_INCOMPLETE)
      if [[ "$status" == INTERRUPTED_* ]]; then
        printf '结果：⚠️ 恢复已中断，自动回滚未完全成功\n'
        printf '中断阶段：%s\n' "${stage:-未知阶段}"
      else
        printf '结果：⚠️ 恢复失败，自动回滚未完全成功\n'
        printf '失败阶段：%s\n' "${stage:-未知阶段}"
      fi
      printf '重要：请勿直接启动相关容器，请根据保留的回滚资料人工处理\n'
      [[ -z "$rollback_dir" ]] || printf '回滚资料：%s\n' "$rollback_dir"
      ;;
    FAILED_POST_COMMIT)
      printf '结果：⚠️ 服务与数据已恢复，但提交后的清理未完成\n'
      printf '失败阶段：%s\n' "${stage:-提交清理}"
      [[ -z "$rollback_dir" ]] || printf '待清理资料：%s\n' "$rollback_dir"
      ;;
    INTERRUPTED)
      printf '结果：⚠️ 恢复已中断\n'
      printf '中断阶段：%s\n' "${stage:-未知阶段}"
      ;;
    *)
      printf '结果：❌ 恢复失败\n'
      printf '失败阶段：%s\n' "${stage:-未知阶段}"
      ;;
  esac
  [[ -z "$cleanup_line" ]] || printf '清理：%s\n' "$cleanup_line"
  [[ -z "$diagnostic_dir" ]] || printf '诊断目录：%s\n' "$diagnostic_dir"
  [[ -z "$elapsed" ]] || printf '耗时：%s\n' "$elapsed"
  result_end_rule
}

print_source_result_summary() {
  local status="$1" package_line="$2" http_line="$3" source_line="$4"
  local cleanup_line="$5" elapsed="$6"

  printf '\n'
  result_rule
  case "$status" in
    SUCCESS)
      printf '结果：✅ 源端任务已安全结束\n'
      [[ -z "$source_line" ]] || printf '源容器：%s\n' "$source_line"
      [[ -z "$elapsed" ]] || printf '耗时：%s\n' "$elapsed"
      result_end_rule
      return 0
      ;;
    INTERRUPTED) printf '结果：⚠️ 源端任务已中断，清理流程已执行\n' ;;
    *) printf '结果：❌ 源端任务失败，清理流程已执行\n' ;;
  esac
  [[ -z "$package_line" ]] || printf '迁移包：%s\n' "$package_line"
  [[ -z "$http_line" ]] || printf 'HTTP 服务：%s\n' "$http_line"
  [[ -z "$source_line" ]] || printf '源容器：%s\n' "$source_line"
  [[ -z "$cleanup_line" ]] || printf '清理：%s\n' "$cleanup_line"
  [[ -z "$elapsed" ]] || printf '耗时：%s\n' "$elapsed"
  result_end_rule
}

print_transfer_instructions() {
  local url="$1" mode="${2:-interactive}" source_pid="${3:-}"
  printf '\n%s\n' '━━━━━━━━━━ 迁移包已就绪 ━━━━━━━━━━'
  printf '下载链接（请完整复制）：\n%s\n\n' "$url"
  printf '使用方法：在新服务器运行同一脚本 → 选择「2) 下载备份并恢复」→ 粘贴上面的完整链接。\n'
  if [[ "$mode" == "interactive" ]]; then
    printf '目标端恢复成功后，回到此窗口按回车停止传输服务并清理临时文件。\n'
  else
    printf '传输服务将保持运行；目标端恢复完成后执行：kill -TERM %s\n' "$source_pid"
  fi
  printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

http_log_event() {
  local message="$1"
  [[ -n "${HTTP_LOG:-}" ]] || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$message" >>"$HTTP_LOG"
}

print_http_diagnostics() {
  local log_file="${1:-}"
  printf 'HTTP 服务诊断（最后 20 行）：\n' >&2
  if [[ -n "$log_file" && -s "$log_file" ]]; then
    tail -n 20 "$log_file" >&2 || true
  else
    printf 'HTTP 服务未提供额外日志。\n' >&2
  fi
  [[ -z "$log_file" ]] || printf '完整日志：%s\n' "$log_file" >&2
}

print_http_diagnostics_once() {
  local log_file="${1:-}"
  ((${HTTP_DIAGNOSTICS_SHOWN:-0} == 0)) || return 0
  HTTP_DIAGNOSTICS_SHOWN=1
  print_http_diagnostics "$log_file"
}

netcat_http_serve() {
  local port="$1" response_file="$2" transfer_file="$3"
  while true; do
    if {
      cat "$response_file"
      cat "$transfer_file"
    } | nc -l -p "$port" -q 0; then
      continue
    fi
    if {
      cat "$response_file"
      cat "$transfer_file"
    } | nc -l -p "$port"; then
      continue
    fi
    if {
      cat "$response_file"
      cat "$transfer_file"
    } | nc -l "$port"; then
      continue
    fi
    return 1
  done
}

restore_target_container_names() {
  local bundle_dir="$1" run project service found_service inspect_file
  [[ -f "${bundle_dir}/manifest.json" ]] || return 0
  while IFS= read -r run; do
    [[ -n "$run" ]] || continue
    basename "${run%.sh}"
  done < <(jq -r '.runs[]?' "${bundle_dir}/manifest.json" 2>/dev/null || true)
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    found_service=0
    for inspect_file in "${bundle_dir}"/meta/*.inspect.json; do
      [[ -f "$inspect_file" ]] || continue
      service="$(jq -r --arg project "$project" '
        if (.[0].Config.Labels["com.docker.compose.project"] // "") == $project
        then .[0].Config.Labels["com.docker.compose.service"] // empty
        else empty end
      ' "$inspect_file" 2>/dev/null || true)"
      [[ -n "$service" ]] || continue
      found_service=1
      docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --filter "label=com.docker.compose.service=${service}" \
        --format '{{.Names}}' 2>/dev/null || true
    done
    if ((found_service == 0)); then
      docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Names}}' 2>/dev/null || true
    fi
  done < <(jq -r '.projects[]?.name' "${bundle_dir}/manifest.json" 2>/dev/null || true)
}

collect_restore_result_metrics() {
  local bundle_dir="$1" name state
  local total=0 running=0 paused=0 stopped=0 missing=0 volumes=0 binds=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    total=$((total + 1))
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    case "$state" in
      running | restarting) running=$((running + 1)) ;;
      paused) paused=$((paused + 1)) ;;
      created | exited | dead | removing) stopped=$((stopped + 1)) ;;
      *) missing=$((missing + 1)) ;;
    esac
  done < <(restore_target_container_names "$bundle_dir" | awk 'NF && !seen[$0]++')
  if [[ -f "${bundle_dir}/manifest.json" ]]; then
    volumes="$(jq -r '.volumes | length' "${bundle_dir}/manifest.json" 2>/dev/null || echo 0)"
    binds="$(jq -r '.binds | length' "${bundle_dir}/manifest.json" 2>/dev/null || echo 0)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$total" "$running" "$paused" "$stopped" "$missing" "$volumes" "$binds"
}

show_banner() {
  echo -e "\033[1;36m"
  cat <<'BANNER'
  ____             _               __  __ _                 _
 |  _ \  ___   ___| | _____ _ __  |  \/  (_) __ _ _ __ __ _| |_ ___
 | | | |/ _ \ / __| |/ / _ \ '__| | |\/| | |/ _` | '__/ _` | __/ _ \
 | |_| | (_) | (__|   <  __/ |    | |  | | | (_| | | | (_| | ||  __/
 |____/ \___/ \___|_|\_\___|_|    |_|  |_|_|\__, |_|  \__,_|\__\___|
                                            |___/
 ---------------------------------------------------------------
      🐳 一键备份 · 安全传输 · 完整恢复 | Docker 容器迁移工具
 ---------------------------------------------------------------
BANNER
  echo -e "\033[0m"
}

show_help() {
  cat <<'HLP'
用法:
  bash docker_migrate_perfect.sh [--backup] [--no-stop] [--include=name1,name2]
  bash docker_migrate_perfect.sh --restore[=URL]

环境变量:
  PORT=8080                 HTTP 端口（被占用会自动递增）
  ADVERTISE_HOST=IP         下载链接中使用的主机名/IP
  RESTORE_EXISTING=replace  同名容器策略：replace、skip 或 fail
  RESTORE_KEEP=1            恢复后保留文件
  RESTORE_CLEAN_ALL=1       恢复失败也强制删除文件
  RESTORE_BASE=/path        自定义恢复目录

不带参数运行时仍使用原有交互菜单。
HLP
}

asudo() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    "$@"
  fi
}

pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo dnf
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo yum
    return
  fi
  if command -v zypper >/dev/null 2>&1; then
    echo zypper
    return
  fi
  if command -v apk >/dev/null 2>&1; then
    echo apk
    return
  fi
  echo none
}

pm_install() {
  local pm="$1"
  shift
  case "$pm" in
    apt)
      asudo apt-get update -y
      asudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf) asudo dnf install -y "$@" ;;
    yum) asudo yum install -y "$@" ;;
    zypper) asudo zypper --non-interactive install -y "$@" ;;
    apk) asudo apk add --no-cache "$@" ;;
    *)
      RED "[ERR] 不支持的包管理器：$pm，请手动安装：$*"
      exit 1
      ;;
  esac
}

need_bin() {
  local bin="$1" pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[INFO] 安装依赖：$bin（可能耗时；如出现 sudo 密码提示，请按提示输入）"
    pm_install "$PKGMGR" "$pkg"
  fi
}

try_optional_bin() {
  local bin="$1" pkg="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  [[ "${PKGMGR:-none}" != "none" ]] || return 0
  echo "[INFO] 安装可选依赖：$bin（可能耗时；如出现 sudo 密码提示，请按提示输入）"
  pm_install "$PKGMGR" "$pkg" || true
}

ensure_docker_running() {
  if ! command -v docker >/dev/null 2>&1; then
    RED "[ERR] 未检测到 docker，请先安装 Docker 再运行本脚本。"
    exit 1
  fi

  if docker info >/dev/null 2>&1; then
    return 0
  fi

  YEL "[INFO] 尝试启动 Docker 服务..."
  if command -v systemctl >/dev/null 2>&1; then
    YEL "[INFO] 正在通过 systemctl 启动 Docker；如出现 sudo 密码提示，请按提示输入。"
    asudo systemctl enable --now docker || true
  fi
  if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    YEL "[INFO] 正在通过 service 启动 Docker；如出现 sudo 密码提示，请按提示输入。"
    asudo service docker start || true
  fi
  if ! docker info >/dev/null 2>&1; then
    YEL "[WARN] 尝试后台直接启动 dockerd ..."
    if command -v dockerd >/dev/null 2>&1; then
      asudo nohup dockerd >/var/log/dockerd.migrate.log 2>&1 &
      sleep 3
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    RED "[ERR] Docker 仍未正常启动，请手动检查后重试。"
    exit 1
  fi
}

human() {
  local b="${1:-0}"
  local -a units=(B KB MB GB TB PB)
  local i=0
  while ((b >= 1024 && i < ${#units[@]} - 1)); do
    b=$((b / 1024))
    i=$((i + 1))
  done
  echo "${b}${units[$i]}"
}

progress_file_size() {
  local file="$1"
  stat -c %s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0
}

# 只在确实知道总字节数时显示百分比；未知总量时仅报告已处理字节和耗时，
# 避免用“假进度条”误导用户。该函数保持纯输出，便于单元测试。
progress_render() {
  local label="$1" current="${2:-0}" total="${3:-0}" elapsed="${4:-0}"
  local percent filled empty bar
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0
  if ((total > 0)); then
    ((current <= total)) || current=$total
    percent=$((current * 100 / total))
    filled=$((percent * 24 / 100))
    empty=$((24 - filled))
    printf -v bar '%*s' "$filled" ''
    bar=${bar// /#}
    printf -v empty '%*s' "$empty" ''
    empty=${empty// /-}
    printf '[进度] %s [%s%s] %d%% · %s/%s · %s' \
      "$label" "$bar" "$empty" "$percent" "$(human "$current")" \
      "$(human "$total")" "$(format_elapsed "$elapsed")"
  elif ((current > 0)); then
    printf '[进度] %s · %s · %s' \
      "$label" "$(human "$current")" "$(format_elapsed "$elapsed")"
  else
    printf '[进度] %s · %s' "$label" "$(format_elapsed "$elapsed")"
  fi
}

progress_finish() {
  local label="$1" rc="$2" elapsed="$3" current="${4:-0}"
  local suffix=""
  ((rc != 0)) || return 0
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  ((current == 0)) || suffix=" · $(human "$current")"
  printf '[失败] %s · %s%s\n' "$label" "$(format_elapsed "$elapsed")" "$suffix" >&2
}

progress_count() {
  local label="$1" current="$2" total="$3" item="${4:-}"
  local suffix=""
  [[ -z "$item" ]] || suffix="（${item}）"
  if [[ -t 2 ]]; then
    printf '\r%-120s\r[进度] %s：%d/%d%s' "" "$label" "$current" "$total" "$suffix" >&2
    ((current < total)) || printf '\n' >&2
  elif ((current == 1 || current == total || current % 10 == 0)); then
    printf '[进度] %s：%d/%d%s\n' "$label" "$current" "$total" "$suffix" >&2
  fi
}

progress_watch() {
  local label="$1" file="$2" total="$3" started="$4" owner_pid="$5"
  local mode="${DOCKER_MIGRATE_PROGRESS_MODE:-auto}" interval current elapsed timer_pid=""
  [[ "$mode" != "plain" && "$mode" != "off" ]] || return 0
  if [[ -n "${DOCKER_MIGRATE_PROGRESS_INTERVAL:-}" ]]; then
    interval="$DOCKER_MIGRATE_PROGRESS_INTERVAL"
  elif [[ -t 2 ]]; then
    interval=1
  else
    interval=10
  fi
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=10
  # watcher 被主流程终止时，也必须立即终止其 sleep 子进程。否则 sleep 会继续
  # 持有命令替换/进程替换的管道，使已经完成的步骤一直等到 interval 到期。
  trap '
    if [[ -n "${timer_pid:-}" ]]; then
      kill "$timer_pid" 2>/dev/null || true
      wait "$timer_pid" 2>/dev/null || true
    fi
    exit 0
  ' TERM INT HUP
  while kill -0 "$owner_pid" 2>/dev/null; do
    # timer 不需要任何标准流；显式断开可避免它延长调用方管道的生命周期。
    # stdin 重定向用于关闭继承的管道，不是供 sleep 读取。
    # shellcheck disable=SC2217
    sleep "$interval" </dev/null >/dev/null 2>&1 &
    timer_pid=$!
    wait "$timer_pid" 2>/dev/null || true
    timer_pid=""
    kill -0 "$owner_pid" 2>/dev/null || break
    current=0
    [[ -z "$file" ]] || current="$(progress_file_size "$file")"
    elapsed=$((SECONDS - started))
    if [[ -t 2 ]]; then
      printf '\r%-120s\r' "" >&2
      progress_render "$label" "$current" "$total" "$elapsed" >&2
    else
      progress_render "$label" "$current" "$total" "$elapsed" >&2
      printf '\n' >&2
    fi
  done
  trap - TERM INT HUP
}

run_with_progress() {
  local label="$1" file="$2" total="$3"
  shift 3
  local started=$SECONDS watcher_pid rc current=0 restore_errexit=0
  case $- in *e*) restore_errexit=1 ;; esac
  progress_watch "$label" "$file" "$total" "$started" "$$" &
  watcher_pid=$!
  set +e
  "$@"
  rc=$?
  ((restore_errexit == 0)) || set -e
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  [[ ! -t 2 ]] || printf '\r%-120s\r' "" >&2
  [[ -z "$file" ]] || current="$(progress_file_size "$file")"
  progress_finish "$label" "$rc" "$((SECONDS - started))" "$current"
  return "$rc"
}

run_with_activity() {
  local label="$1"
  shift
  run_with_progress "$label" "" 0 "$@"
}

run_with_file_progress() {
  local label="$1" file="$2" total="${3:-0}"
  shift 3
  run_with_progress "$label" "$file" "$total" "$@"
}

progress_capture_stdout() {
  local outfile="$1"
  shift
  "$@" >"$outfile"
}

progress_docker_save() {
  local outfile="$1"
  shift
  local rc=0 started=$SECONDS current=0 restore_errexit=0
  if command -v pv >/dev/null 2>&1; then
    case $- in *e*) restore_errexit=1 ;; esac
    set +e
    # -f 保证日志被重定向时也持续输出；pipefail 保留 docker save 的失败状态。
    "$@" | pv -f -b >"$outfile"
    rc=$?
    ((restore_errexit == 0)) || set -e
    current="$(progress_file_size "$outfile")"
    progress_finish "保存镜像 images.tar" "$rc" "$((SECONDS - started))" "$current"
  else
    if run_with_file_progress "保存镜像 images.tar" "$outfile" 0 \
      progress_capture_stdout "$outfile" "$@"; then
      rc=0
    else
      rc=$?
    fi
  fi
  return "$rc"
}

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  [[ "$ip" =~ ^127\. ]] && return 0
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  return 1
}

get_public_ip_external() {
  local ip
  for svc in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
    ip="$(curl -fsS --max-time 2 "$svc" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

pick_advertise_url() {
  local port="$1"
  local host=""
  if [[ -n "${ADVERTISE_HOST:-}" ]]; then
    host="$ADVERTISE_HOST"
  else
    local via_route=""
    via_route="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if [[ -n "$via_route" ]] && ! is_private_ipv4 "$via_route"; then
      host="$via_route"
    fi
    [[ -z "$host" ]] && host="$(get_public_ip_external || true)"
    [[ -z "$host" ]] && host="$(ip -4 -o addr show 2>/dev/null | awk '!/ lo| docker| veth| br-| kube/ {print $4}' | cut -d/ -f1 | head -n1 || true)"
    : "${host:=127.0.0.1}"
  fi
  echo "http://${host}:${port}"
}

pick_free_port() {
  local p="${1:-8080}"
  local i
  for i in $(seq 0 50); do
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
        echo "$p"
        return 0
      fi
    elif command -v netstat >/dev/null 2>&1; then
      if ! netstat -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
        echo "$p"
        return 0
      fi
    else
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  echo "${1:-8080}"
}

json_array_from_lines() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
    return 0
  fi
  # 过滤空行，避免空数组被序列化成 [""]。
  printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -cs .
}

compose_env_file_refs() {
  # Best-effort fallback parser for common Compose env_file scalar/list/long syntax.
  # 正常情况下恢复使用 `docker compose config` 生成的已解析配置。
  awk '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      return v
    }
    /^[[:space:]]*env_file[[:space:]]*:/ {
      in_env = 1
      value = $0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      value = trim(value)
      if (value != "") {
        print value
        in_env = 0
      }
      next
    }
    in_env && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      if (value ~ /^path[[:space:]]*:/) {
        sub(/^path[[:space:]]*:[[:space:]]*/, "", value)
      }
      value = trim(value)
      if (value != "" && value !~ /^(required|format)[[:space:]]*:/) print value
      next
    }
    in_env && /^[[:space:]]*path[[:space:]]*:/ {
      value = $0
      sub(/^[[:space:]]*path[[:space:]]*:[[:space:]]*/, "", value)
      value = trim(value)
      if (value != "") print value
      next
    }
    in_env && /^[^[:space:]#]/ { in_env = 0 }
  ' "$1"
}

mount_paths_overlap() {
  local left="$1" right="$2"
  [[ "$left" == "/" ]] || left="${left%/}"
  [[ "$right" == "/" ]] || right="${right%/}"
  [[ "$left" != "/" && "$right" != "/" ]] || return 0
  [[ "$left" == "$right" || "$left" == "${right}/"* || "$right" == "${left}/"* ]]
}

collect_shared_running_containers() {
  local selected_id selected_full_id id name inspect mount type source selected_path reason
  declare -A selected_ids=() selected_volumes=()
  local -a selected_binds=()

  for selected_id in "$@"; do
    selected_ids["$selected_id"]=1
    if declare -p SELECTED_INSPECT_JSON >/dev/null 2>&1 &&
      [[ -n "${SELECTED_INSPECT_JSON[$selected_id]+cached}" ]]; then
      inspect="${SELECTED_INSPECT_JSON[$selected_id]}"
    else
      inspect="$(docker inspect "$selected_id")" || return 1
    fi
    selected_full_id="$(jq -r '.[0].Id' <<<"$inspect")"
    selected_ids["$selected_full_id"]=1
    selected_ids["${selected_full_id:0:12}"]=1
    while IFS= read -r source; do
      [[ -n "$source" ]] && selected_volumes["$source"]=1
    done < <(jq -r '.[0].Mounts[]? | select(.Type == "volume") | .Name' <<<"$inspect")
    while IFS= read -r source; do
      [[ -n "$source" ]] && selected_binds+=("$source")
    done < <(jq -r '.[0].Mounts[]? | select(.Type == "bind") | .Source' <<<"$inspect")
  done

  while IFS=$'\t' read -r id name; do
    [[ -n "$id" && -z "${selected_ids[$id]:-}" ]] || continue
    case ",${DOCKER_MIGRATE_IGNORE_CONTAINERS:-}," in
      *,"$name",*) continue ;;
    esac
    inspect="$(docker inspect "$id")" || return 1
    reason=""
    while IFS= read -r mount; do
      type="$(jq -r '.Type' <<<"$mount")"
      case "$type" in
        volume)
          source="$(jq -r '.Name' <<<"$mount")"
          if [[ -n "${selected_volumes[$source]:-}" ]]; then
            reason="volume:${source}"
            break
          fi
          ;;
        bind)
          source="$(jq -r '.Source' <<<"$mount")"
          for selected_path in "${selected_binds[@]}"; do
            if mount_paths_overlap "$source" "$selected_path"; then
              reason="bind:${source}"
              break 2
            fi
          done
          ;;
      esac
    done < <(jq -c '.[0].Mounts[]?' <<<"$inspect")
    [[ -z "$reason" ]] || printf '%s\t%s\t%s\n' "$id" "$name" "$reason"
  done < <(docker ps --format '{{.ID}}\t{{.Names}}')
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    return 127
  fi
}

bundle_download_url() {
  printf '%s\n' "${1%%#*}"
}

bundle_fragment_value() {
  local url="$1" key="$2" fragment pair
  local -a fragment_parts=()
  [[ "$url" == *#* ]] || {
    printf '\n'
    return 0
  }
  fragment="${url#*#}"
  IFS='&' read -r -a fragment_parts <<<"$fragment"
  for pair in "${fragment_parts[@]}"; do
    if [[ "${pair%%=*}" == "$key" && "$pair" == *=* ]]; then
      printf '%s\n' "${pair#*=}"
      return 0
    fi
  done
  printf '\n'
}

bundle_expected_sha256() {
  bundle_fragment_value "$1" sha256
}

bundle_encryption_scheme() {
  bundle_fragment_value "$1" enc
}

bundle_encryption_secret() {
  bundle_fragment_value "$1" secret
}

bundle_encryption_iv() {
  bundle_fragment_value "$1" iv
}

bundle_encryption_mac() {
  bundle_fragment_value "$1" mac
}

valid_sha256() {
  [[ "$1" =~ ^[[:xdigit:]]{64}$ ]]
}

valid_hex_length() {
  local value="$1" expected_length="$2"
  [[ "$expected_length" =~ ^[0-9]+$ ]] || return 2
  ((${#value} == expected_length)) && [[ "$value" =~ ^[[:xdigit:]]+$ ]]
}

bundle_secret_encryption_key() {
  local secret="$1"
  valid_hex_length "$secret" 128 || return 1
  printf '%s\n' "${secret:0:64}"
}

bundle_secret_mac_key() {
  local secret="$1"
  valid_hex_length "$secret" 128 || return 1
  printf '%s\n' "${secret:64:64}"
}

bundle_hmac_sha256_file() {
  local file="$1" mac_key="$2" iv="$3" digest
  [[ -f "$file" ]] || return 1
  valid_hex_length "$mac_key" 64 || return 2
  valid_hex_length "$iv" 32 || return 2
  command -v openssl >/dev/null 2>&1 || return 127
  # openssl enc 不提供 AEAD；使用独立密钥认证“版本 + IV + 密文”，并在解密前验证。
  digest="$({
    printf 'docker-migrate:%s\0%s\0' "$BUNDLE_ENCRYPTION_SCHEME" "${iv,,}"
    cat -- "$file"
  } | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${mac_key}" 2>/dev/null | awk '{print $NF}')" || return 1
  valid_sha256 "$digest" || return 1
  printf '%s\n' "${digest,,}"
}

verify_bundle_hmac() {
  local file="$1" mac_key="$2" iv="$3" expected="$4" actual
  valid_sha256 "$expected" || return 2
  actual="$(bundle_hmac_sha256_file "$file" "$mac_key" "$iv")" || return 1
  [[ "${actual,,}" == "${expected,,}" ]]
}

bundle_file_digests() {
  local file="$1" mac_key="$2" iv="$3"
  local result sha mac extra
  [[ -f "$file" ]] || return 1
  valid_hex_length "$mac_key" 64 || return 2
  valid_hex_length "$iv" 32 || return 2

  # Python 可在一次顺序读取中同时计算来源 SHA 与 encrypt-then-MAC 摘要。
  # 它是可选加速路径；极简系统仍回退到现有 OpenSSL/SHA 工具，不影响可用性。
  if command -v python3 >/dev/null 2>&1; then
    result="$(python3 -c '
import hashlib
import hmac
import sys

path, key_hex, iv, scheme = sys.argv[1:]
sha = hashlib.sha256()
mac = hmac.new(bytes.fromhex(key_hex), digestmod=hashlib.sha256)
mac.update(b"docker-migrate:" + scheme.encode() + b"\0" + iv.lower().encode() + b"\0")
with open(path, "rb", buffering=0) as source:
    while True:
        chunk = source.read(1024 * 1024)
        if not chunk:
            break
        sha.update(chunk)
        mac.update(chunk)
print(sha.hexdigest() + "\t" + mac.hexdigest())
' "$file" "$mac_key" "$iv" "$BUNDLE_ENCRYPTION_SCHEME")" || return 1
  else
    sha="$(sha256_file "$file")" || return 1
    mac="$(bundle_hmac_sha256_file "$file" "$mac_key" "$iv")" || return 1
    result="${sha}"$'\t'"${mac}"
  fi

  IFS=$'\t' read -r sha mac extra <<<"$result"
  [[ -z "$extra" ]] || return 1
  valid_sha256 "$sha" && valid_sha256 "$mac" || return 1
  printf '%s\t%s\n' "${sha,,}" "${mac,,}"
}

verify_bundle_digests() {
  local file="$1" mac_key="$2" iv="$3" expected_sha="$4" expected_mac="$5"
  local actual_sha actual_mac extra
  valid_sha256 "$expected_sha" && valid_sha256 "$expected_mac" || return 2
  IFS=$'\t' read -r actual_sha actual_mac extra < <(
    bundle_file_digests "$file" "$mac_key" "$iv"
  ) || return 1
  [[ -z "$extra" ]] || return 1
  [[ "${actual_sha,,}" == "${expected_sha,,}" &&
    "${actual_mac,,}" == "${expected_mac,,}" ]]
}

gzip_compress_stream() {
  local level="${DOCKER_MIGRATE_GZIP_LEVEL:-6}"
  [[ "$level" =~ ^[1-9]$ ]] || level=6
  if command -v pigz >/dev/null 2>&1; then
    pigz "-${level}" -c
  else
    gzip "-${level}" -c
  fi
}

archive_volume_to_gzip() {
  local volume="$1" output="$2" rc=0
  rm -f -- "$output"
  if docker run --rm -v "${volume}:/from:ro" alpine:3.20 \
    tar -C /from -cf - . | gzip_compress_stream >"$output"; then
    return 0
  else
    rc=$?
  fi
  rm -f -- "$output"
  return "$rc"
}

archive_bind_to_gzip() {
  local source="$1" output="$2" rc=0
  rm -f -- "$output"
  if tar -C / -cf - "${source#/}" | gzip_compress_stream >"$output"; then
    return 0
  else
    rc=$?
  fi
  rm -f -- "$output"
  return "$rc"
}

docker_stop_batch_verified() {
  local label="$1"
  shift
  local name running stop_rc=0 verify_rc=0
  (($# > 0)) || return 0

  run_with_activity "$label" docker stop "$@" >/dev/null || stop_rc=$?
  # Docker CLI 的聚合退出码无法指出具体失败项；以 daemon 的最终状态为准，
  # 同时逐个确认，避免部分停止后误以为已经取得一致性快照。
  for name in "$@"; do
    if ! running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)"; then
      RED "[ERR] 停机后无法确认容器状态：$name"
      verify_rc=1
    elif [[ "$running" != "false" ]]; then
      RED "[ERR] 容器仍在运行：$name"
      verify_rc=1
    fi
  done
  ((verify_rc == 0)) || return 1
  if ((stop_rc != 0)); then
    YEL "[WARN] docker stop 返回异常，但已逐个确认所有目标容器停止。"
  fi
  return 0
}

bundle_pack_encrypt_directory() {
  local bundle_root="$1" member="$2" output="$3"
  local encryption_key="$4" mac_key="$5" iv="$6"
  local result sha mac extra rc=0
  [[ -d "${bundle_root}/${member}" ]] || return 1
  valid_hex_length "$encryption_key" 64 || return 2
  valid_hex_length "$mac_key" 64 || return 2
  valid_hex_length "$iv" 32 || return 2
  command -v openssl >/dev/null 2>&1 || return 127
  rm -f -- "$output"

  if command -v python3 >/dev/null 2>&1; then
    # 压缩、加密、落盘和两个摘要在同一条流水线完成：不再生成明文 tar.gz，
    # 密文也无需为了 HMAC/SHA 再从磁盘完整读取一次。
    if result="$(
      tar -C "$bundle_root" -cf - "$member" |
        gzip_compress_stream |
        openssl enc -aes-256-ctr -nosalt -K "$encryption_key" -iv "$iv" |
        python3 -c '
import hashlib
import hmac
import sys

output, key_hex, iv, scheme = sys.argv[1:]
sha = hashlib.sha256()
mac = hmac.new(bytes.fromhex(key_hex), digestmod=hashlib.sha256)
mac.update(b"docker-migrate:" + scheme.encode() + b"\0" + iv.lower().encode() + b"\0")
with open(output, "wb", buffering=0) as target:
    while True:
        chunk = sys.stdin.buffer.read(1024 * 1024)
        if not chunk:
            break
        target.write(chunk)
        sha.update(chunk)
        mac.update(chunk)
print(sha.hexdigest() + "\t" + mac.hexdigest())
' "$output" "$mac_key" "$iv" "$BUNDLE_ENCRYPTION_SCHEME"
    )"; then
      :
    else
      rc=$?
      rm -f -- "$output"
      return "$rc"
    fi
  else
    # 无 Python 时仍保留流式压缩加密和格式兼容，只在生成后回退为摘要扫描。
    if tar -C "$bundle_root" -cf - "$member" |
      gzip_compress_stream |
      openssl enc -aes-256-ctr -nosalt -K "$encryption_key" -iv "$iv" \
        -out "$output"; then
      result="$(bundle_file_digests "$output" "$mac_key" "$iv")" || {
        rc=$?
        rm -f -- "$output"
        return "$rc"
      }
    else
      rc=$?
      rm -f -- "$output"
      return "$rc"
    fi
  fi

  IFS=$'\t' read -r sha mac extra <<<"$result"
  if [[ -n "$extra" ]] || ! valid_sha256 "$sha" || ! valid_sha256 "$mac"; then
    rm -f -- "$output"
    return 1
  fi
  printf '%s\t%s\n' "${sha,,}" "${mac,,}"
}

bundle_encrypt_file() {
  local input="$1" output="$2" encryption_key="$3" iv="$4"
  local partial="${output}.partial.$$"
  [[ -f "$input" && "$input" != "$output" ]] || return 1
  valid_hex_length "$encryption_key" 64 || return 2
  valid_hex_length "$iv" 32 || return 2
  command -v openssl >/dev/null 2>&1 || return 127
  rm -f "$partial"
  if openssl enc -aes-256-ctr -nosalt -K "$encryption_key" -iv "$iv" \
    -in "$input" -out "$partial"; then
    mv "$partial" "$output"
  else
    rm -f "$partial"
    return 1
  fi
}

bundle_decrypt_file() {
  local input="$1" output="$2" encryption_key="$3" iv="$4"
  local partial="${output}.partial.$$"
  [[ -f "$input" && "$input" != "$output" ]] || return 1
  valid_hex_length "$encryption_key" 64 || return 2
  valid_hex_length "$iv" 32 || return 2
  command -v openssl >/dev/null 2>&1 || return 127
  rm -f "$partial"
  if openssl enc -d -aes-256-ctr -nosalt -K "$encryption_key" -iv "$iv" \
    -in "$input" -out "$partial"; then
    mv "$partial" "$output"
  else
    rm -f "$partial"
    return 1
  fi
}

verify_archive_sha256() {
  local file="$1" expected="$2" actual
  valid_sha256 "$expected" || return 2
  actual="$(sha256_file "$file")" || return 1
  [[ "${actual,,}" == "${expected,,}" ]]
}

snapshot_image_ref() {
  local rid="$1" container_id="$2"
  printf 'docker-migrate-snapshot:%s-%s\n' "${rid,,}" "${container_id:0:12}"
}

snapshot_container_image() {
  local container_id="$1" metadata_file="$2" snapshot_image="$3"
  local original_image running tmp
  local -a commit_args=(docker commit)

  original_image="$(jq -r '.[0].Config.Image' "$metadata_file")"
  # 这里必须读取临近 commit 的实时状态；--no-stop 模式下容器可能在元数据采集后启动。
  running="$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || echo false)"
  # 用户选择不停机时不偷偷暂停业务；这种模式本身已明确提示快照可能不一致。
  [[ "$running" != "true" ]] || commit_args+=(--pause=false)
  if ! "${commit_args[@]}" "$container_id" "$snapshot_image" >/dev/null; then
    return 1
  fi
  TEMP_IMAGES+=("$snapshot_image")

  tmp="${metadata_file}.snapshot.tmp"
  if ! jq --arg original "$original_image" --arg snapshot "$snapshot_image" '
      .[0].Config.Image = $snapshot |
      .[0].DockerMigrate = ((.[0].DockerMigrate // {}) + {
        original_image: $original,
        snapshot_image: $snapshot,
        writable_layer_captured: true
      })
    ' "$metadata_file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$metadata_file"
}

write_compose_snapshot_override() {
  local file="$1" service="$2" image="$3" tmp
  if [[ ! -f "$file" ]]; then
    printf '{"services":{}}\n' >"$file"
  fi
  tmp="${file}.tmp"
  jq --arg service "$service" --arg image "$image" \
    '.services[$service].image = $image' "$file" >"$tmp"
  mv "$tmp" "$file"
}

cleanup_snapshot_images() {
  local image rc=0
  local -a remaining=()
  for image in "${TEMP_IMAGES[@]}"; do
    if docker image rm "$image" >/dev/null 2>&1; then
      continue
    fi
    # rm 失败后，只有在 Docker daemon 可用且明确查不到镜像时才视为已清理；
    # daemon/权限异常必须保留记录，供退出清理重试并反映在最终结果中。
    if docker info >/dev/null 2>&1 &&
      ! docker image inspect "$image" >/dev/null 2>&1; then
      continue
    fi
    remaining+=("$image")
    rc=1
  done
  TEMP_IMAGES=("${remaining[@]}")
  return "$rc"
}

generate_bundle_checksums() {
  local bundle_dir="$1"
  local manifest="${bundle_dir}/checksums.sha256"
  local file rel digest
  : >"$manifest"
  while IFS= read -r -d '' file; do
    rel="${file#"${bundle_dir}/"}"
    case "$rel" in checksums.sha256 | restore.sh | .docker_migrate_rollback/*) continue ;; esac
    digest="$(sha256_file "$file")" || {
      RED "[ERR] 系统缺少 SHA-256 工具（sha256sum/shasum/openssl）。"
      return 1
    }
    printf '%s\t%s\n' "$digest" "$rel" >>"$manifest"
  done < <(find "$bundle_dir" -type f -print0)
}

verify_bundle_checksums() {
  local bundle_dir="$1"
  local manifest="${bundle_dir}/checksums.sha256"
  local expected rel file actual count=0
  local -A verified_paths=()
  [[ -f "$manifest" ]] || {
    RED "[ERR] 迁移包缺少 checksums.sha256。"
    return 1
  }
  while IFS=$'\t' read -r expected rel; do
    [[ -n "$expected" && -n "$rel" ]] || continue
    case "$rel" in
      /* | .. | ../* | */../* | */..)
        RED "[ERR] 校验清单含危险路径：$rel"
        return 1
        ;;
    esac
    file="${bundle_dir}/${rel}"
    [[ -f "$file" ]] || {
      RED "[ERR] 迁移包缺少文件：$rel"
      return 1
    }
    actual="$(sha256_file "$file")" || return 1
    [[ "$actual" == "$expected" ]] || {
      RED "[ERR] 文件完整性校验失败：$rel"
      return 1
    }
    verified_paths["$rel"]=1
    count=$((count + 1))
  done <"$manifest"
  ((count > 0)) || {
    RED "[ERR] 校验清单为空。"
    return 1
  }
  while IFS= read -r -d '' file; do
    rel="${file#"${bundle_dir}/"}"
    case "$rel" in checksums.sha256 | restore.sh | .docker_migrate_rollback/*) continue ;; esac
    if [[ -z "${verified_paths["$rel"]+present}" ]]; then
      RED "[ERR] 迁移包含未纳入校验清单的文件：$rel"
      return 1
    fi
  done < <(find "$bundle_dir" -type f -print0)
}

bundle_manifest_is_safe() {
  local bundle_dir="$1" manifest run name metadata_name
  manifest="${bundle_dir}/manifest.json"
  [[ -f "$manifest" ]] || return 1
  jq -e '
    type == "object" and
    (.images | type == "array") and
    (.networks | type == "array") and
    (.projects | type == "array") and
    (.volumes | type == "array") and
    (.binds | type == "array") and
    (.runs | type == "array") and
    all(.runs[]; type == "string" and test("^runs/[A-Za-z0-9][A-Za-z0-9_.-]*\\.sh$")) and
    all(.projects[];
      (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) and
      (.working_dir // "" | type == "string" and
        (. == "" or (startswith("/") and (test("(^|/)\\.\\.(/|$)") | not) and
          all(explode[]; . >= 32 and . != 127))))
    ) and
    all(.volumes[]; (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$"))) and
    all(.binds[];
      (.host | type == "string" and startswith("/") and . != "/" and
        (test("(^|/)\\.\\.(/|$)") | not) and
        all(explode[]; . >= 32 and . != 127)) and
      (.file | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*\\.tgz$"))
    )
  ' "$manifest" >/dev/null || return 1

  while IFS= read -r run; do
    [[ -f "${bundle_dir}/${run}" ]] || return 1
    name="${run#runs/}"
    name="${name%.sh}"
    [[ -f "${bundle_dir}/meta/${name}.inspect.json" ]] || return 1
    metadata_name="$(jq -r '.[0].Name | ltrimstr("/")' \
      "${bundle_dir}/meta/${name}.inspect.json" 2>/dev/null || true)"
    [[ "$metadata_name" == "$name" ]] || return 1
  done < <(jq -r '.runs[]' "$manifest")
}

archive_layout_is_safe() {
  local archive="$1"
  local entry
  # 在同一次成员列表扫描中同时确认归档可读并校验路径；pipefail 会保留 tar
  # 解压列表失败的状态，避免为了取得退出码再完整解压一遍 gzip 流。
  tar -tzf "$archive" 2>/dev/null |
    while IFS= read -r entry; do
      case "$entry" in
        /* | .. | ../* | */../* | */..) exit 1 ;;
      esac
    done || return 1
  # 顶层迁移包不需要符号链接或硬链接；拒绝它们可避免解压路径绕过。
  ! tar -tvzf "$archive" | awk 'substr($1,1,1) ~ /^[lh]$/ { bad=1 } END { exit bad ? 0 : 1 }'
}

#####################################
# 生成单容器恢复脚本
#####################################
write_run_script() {
  local name="$1"
  local out="$2"
  cat >"$out" <<'RUN_SH'
#!/usr/bin/env bash
set -euo pipefail
umask 077

BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
META="${BUNDLE_DIR}/meta/__NAME__.inspect.json"

dm_format_elapsed() {
  local seconds="${1:-0}"
  if ((seconds >= 60)); then
    printf '%d 分 %d 秒' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%d 秒' "$seconds"
  fi
}

dm_progress_watch() {
  local label="$1" started="$2" owner_pid="$3"
  local mode="${DOCKER_MIGRATE_PROGRESS_MODE:-auto}" interval elapsed timer_pid=""
  [[ "$mode" != "plain" && "$mode" != "off" ]] || return 0
  if [[ -n "${DOCKER_MIGRATE_PROGRESS_INTERVAL:-}" ]]; then
    interval="$DOCKER_MIGRATE_PROGRESS_INTERVAL"
  elif [[ -t 2 ]]; then
    interval=1
  else
    interval=10
  fi
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=10
  trap '
    if [[ -n "${timer_pid:-}" ]]; then
      kill "$timer_pid" 2>/dev/null || true
      wait "$timer_pid" 2>/dev/null || true
    fi
    exit 0
  ' TERM INT HUP
  while kill -0 "$owner_pid" 2>/dev/null; do
    # 关闭 timer 继承的 stdin 管道。
    # shellcheck disable=SC2217
    sleep "$interval" </dev/null >/dev/null 2>&1 &
    timer_pid=$!
    wait "$timer_pid" 2>/dev/null || true
    timer_pid=""
    kill -0 "$owner_pid" 2>/dev/null || break
    elapsed=$((SECONDS - started))
    if [[ -t 2 ]]; then
      printf '\r%-120s\r[进度] %s · %s' \
        "" "$label" "$(dm_format_elapsed "$elapsed")" >&2
    else
      printf '[进度] %s · %s\n' \
        "$label" "$(dm_format_elapsed "$elapsed")" >&2
    fi
  done
  trap - TERM INT HUP
}

dm_run_with_activity() {
  local label="$1"
  shift
  local started=$SECONDS watcher_pid rc restore_errexit=0
  case $- in *e*) restore_errexit=1 ;; esac
  dm_progress_watch "$label" "$started" "$$" &
  watcher_pid=$!
  set +e
  "$@"
  rc=$?
  ((restore_errexit == 0)) || set -e
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  [[ ! -t 2 ]] || printf '\r%-120s\r' "" >&2
  if ((rc != 0)); then
    printf '[失败] %s · %s\n' "$label" "$(dm_format_elapsed "$((SECONDS - started))")" >&2
  fi
  return "$rc"
}

dm_capture_command() {
  local output_file="$1"
  shift
  "$@" >"$output_file" 2>&1
}

if [[ ! -f "$META" ]]; then
  echo "[WARN] missing metadata: $META" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[WARN] jq is required to restore container: __NAME__" >&2
  exit 1
fi

resolve_container_mode() {
  local mode="$1"
  local ref f cid2 cname
  [[ "$mode" == container:* ]] || {
    printf '%s\n' "$mode"
    return 0
  }
  ref="${mode#container:}"
  [[ "$ref" =~ ^[0-9a-f]{12,}$ ]] || {
    printf '%s\n' "$mode"
    return 0
  }
  for f in "${BUNDLE_DIR}"/meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    cid2="$(jq -r '.[0].Id' "$f")"
    if [[ "$cid2" == "$ref" || "${cid2:0:12}" == "$ref" ]]; then
      cname="$(jq -r '.[0].Name | ltrimstr("/")' "$f")"
      printf 'container:%s\n' "$cname"
      return 0
    fi
  done
  printf '%s\n' "$mode"
}

decode_base64() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    base64 -D
  else
    base64 -d
  fi
}

name="$(jq -r '.[0].Name | ltrimstr("/")' "$META")"
image="$(jq -r '.[0].Config.Image' "$META")"
if [[ -z "$name" || -z "$image" || "$image" == "null" ]]; then
  echo "[WARN] invalid container metadata for __NAME__" >&2
  exit 1
fi

replacement_backup_name=""
replacement_original_state=""
replacement_networks_file=""
replacement_active=0
transaction_mode=0
if [[ -n "${RESTORE_TRANSACTION_DIR:-}" && -d "${RESTORE_TRANSACTION_DIR}" ]]; then
  transaction_mode=1
fi

rename_container_with_retry() {
  local old_name="$1" new_name="$2"
  for _ in {1..20}; do
    if docker rename "$old_name" "$new_name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

restore_container_networks() {
  local container="$1" metadata_file="$2" entry network ip ip6 alias
  local -a connect_args=()
  [[ -f "$metadata_file" ]] || return 1
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    network="$(jq -r '.key' <<<"$entry")"
    case "$network" in "" | host | none) continue ;; esac
    if docker inspect "$container" | jq -e --arg network "$network" \
      '.[0].NetworkSettings.Networks[$network] != null' >/dev/null 2>&1; then
      continue
    fi
    connect_args=()
    if [[ "$network" == "bridge" ]]; then
      docker network connect "$network" "$container" >/dev/null 2>&1 || return 1
      continue
    fi
    ip="$(jq -r '.value.IPAMConfig.IPv4Address // .value.IPAddress // empty' <<<"$entry")"
    ip6="$(jq -r '.value.IPAMConfig.IPv6Address // .value.GlobalIPv6Address // .value.IPv6Address // empty' <<<"$entry")"
    [[ -z "$ip" ]] || connect_args+=(--ip "$ip")
    [[ -z "$ip6" ]] || connect_args+=(--ip6 "$ip6")
    while IFS= read -r alias; do
      [[ -z "$alias" ]] || connect_args+=(--alias "$alias")
    done < <(jq -r '.value.Aliases[]? // empty' <<<"$entry")
    docker network connect "${connect_args[@]}" "$network" "$container" >/dev/null 2>&1 || return 1
  done < <(jq -c 'to_entries[]?' "$metadata_file")
}

disconnect_container_networks() {
  local container="$1" metadata_file="$2" network
  while IFS= read -r network; do
    case "$network" in "" | host | none) continue ;; esac
    docker network disconnect -f "$network" "$container" >/dev/null 2>&1 || return 1
  done < <(jq -r 'keys[]?' "$metadata_file")
}

restore_previous_container() {
  ((replacement_active == 1)) || return 0
  echo "[WARN] new container failed; preserving previous container for rollback: $name" >&2
  docker rm -f "$name" >/dev/null 2>&1 || true
  if ((transaction_mode == 1)); then
    # 数据必须先由主恢复脚本回滚；旧容器在那之后才会改回原名并恢复状态。
    replacement_active=0
    return 0
  fi
  if ! rename_container_with_retry "$replacement_backup_name" "$name"; then
    echo "[WARN] automatic rollback failed; previous container remains as: $replacement_backup_name" >&2
    return 1
  fi
  if ! restore_container_networks "$name" "$replacement_networks_file"; then
    echo "[WARN] previous container name was restored, but its networks could not be fully reconnected: $name" >&2
    return 1
  fi
  case "$replacement_original_state" in
    running | restarting)
      docker start "$name" >/dev/null 2>&1 || return 1
      ;;
    paused)
      docker start "$name" >/dev/null 2>&1 || return 1
      docker pause "$name" >/dev/null 2>&1 || return 1
      ;;
  esac
  replacement_active=0
  echo "[INFO] previous container restored: $name" >&2
}

replacement_exit_handler() {
  local rc=$?
  trap - EXIT
  if ((rc != 0 && replacement_active == 1)); then
    restore_previous_container || rc=1
  fi
  if ((transaction_mode == 0)) && [[ -n "$replacement_networks_file" ]]; then
    rm -f "$replacement_networks_file" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap replacement_exit_handler EXIT

if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "[INFO] image is not loaded; pull before changing any existing container: $image"
  dm_run_with_activity "拉取容器镜像：$image" docker pull "$image" || {
    echo "[WARN] image is unavailable; existing container was left unchanged: $image" >&2
    exit 1
  }
fi

if docker container inspect "$name" >/dev/null 2>&1; then
  existing_state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
  if ((transaction_mode == 1)) && [[ -f "${RESTORE_TRANSACTION_DIR}/standalone.tsv" ]]; then
    transaction_state="$(awk -F '\t' -v name="$name" '$1 == name && $2 == "1" { print $3; exit }' \
      "${RESTORE_TRANSACTION_DIR}/standalone.tsv")"
    [[ -z "$transaction_state" ]] || existing_state="$transaction_state"
  fi
  case "${RESTORE_EXISTING:-replace}" in
    replace)
      echo "[WARN] container exists; replace it to restore the complete configuration: $name"
      replacement_original_state="$existing_state"
      replacement_backup_name="${name}.docker-migrate-backup-$$"
      if docker container inspect "$replacement_backup_name" >/dev/null 2>&1; then
        echo "[WARN] rollback container name already exists: $replacement_backup_name" >&2
        exit 1
      fi
      if ((transaction_mode == 1)); then
        mkdir -p "${RESTORE_TRANSACTION_DIR}/standalone_networks"
        replacement_networks_file="${RESTORE_TRANSACTION_DIR}/standalone_networks/${name}.json"
      else
        replacement_networks_file="$(mktemp "${TMPDIR:-/tmp}/docker-migrate-networks.XXXXXX")" || exit 1
      fi
      if ! docker inspect "$name" | jq '.[0].NetworkSettings.Networks // {}' \
        >"$replacement_networks_file"; then
        echo "[WARN] failed to preserve existing container networks: $name" >&2
        exit 1
      fi
      if ((transaction_mode == 1)); then
        # Write-ahead：旧容器 rename 前先登记回滚名称；登记失败时尚未改动目标。
        printf '%s\t%s\t%s\n' "$name" "$replacement_backup_name" "$replacement_original_state" \
          >>"${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv" || exit 1
      fi
      [[ "$existing_state" == "paused" ]] && docker unpause "$name" >/dev/null 2>&1 || true
      case "$existing_state" in
        running | restarting | paused)
          dm_run_with_activity "停止目标端旧容器：$name" docker stop "$name" >/dev/null || {
            echo "[WARN] failed to stop existing container; it was left unchanged: $name" >&2
            exit 1
          }
          ;;
      esac
      docker rename "$name" "$replacement_backup_name" >/dev/null 2>&1 || {
        echo "[WARN] failed to preserve existing container; it was left unchanged: $name" >&2
        exit 1
      }
      replacement_active=1
      if ! disconnect_container_networks "$replacement_backup_name" "$replacement_networks_file"; then
        echo "[WARN] failed to release previous container network endpoints: $name" >&2
        exit 1
      fi
      ;;
    skip)
      echo "[WARN] container exists; skipped by RESTORE_EXISTING=skip: $name"
      exit 0
      ;;
    fail)
      echo "[WARN] container exists; refusing to replace it (RESTORE_EXISTING=fail): $name" >&2
      exit 1
      ;;
    *)
      echo "[WARN] invalid RESTORE_EXISTING value: ${RESTORE_EXISTING}; use replace, skip, or fail" >&2
      exit 1
      ;;
  esac
fi

original_running="$(jq -r '.[0].State.Running // false' "$META")"
original_paused="$(jq -r '.[0].State.Paused // false' "$META")"
if [[ "$original_running" == "true" ]]; then
  args=(docker run -d --name "$name")
else
  args=(docker create --name "$name")
fi
cmd_args=()

mapfile -t entrypoint < <(jq -r '.[0].Config.Entrypoint[]?' "$META")
mapfile -t cmd < <(jq -r '.[0].Config.Cmd[]?' "$META")
if ((${#entrypoint[@]})); then
  args+=(--entrypoint "${entrypoint[0]}")
  if ((${#entrypoint[@]} > 1)); then
    cmd_args+=("${entrypoint[@]:1}")
  fi
fi
if ((${#cmd[@]})); then
  cmd_args+=("${cmd[@]}")
fi

user="$(jq -r '.[0].Config.User // empty' "$META")"
[[ -n "$user" ]] && args+=(-u "$user")

workdir="$(jq -r '.[0].Config.WorkingDir // empty' "$META")"
[[ -n "$workdir" ]] && args+=(-w "$workdir")

cid="$(jq -r '.[0].Id' "$META")"
default_host="${cid:0:12}"
hostname="$(jq -r '.[0].Config.Hostname // empty' "$META")"
if [[ -n "$hostname" && "$hostname" != "$default_host" ]]; then
  args+=(--hostname "$hostname")
fi

domainname="$(jq -r '.[0].Config.Domainname // empty' "$META")"
[[ -n "$domainname" ]] && args+=(--domainname "$domainname")

mapfile -t envs < <(jq -r '.[0].Config.Env[]?' "$META")
for e in "${envs[@]}"; do args+=(-e "$e"); done

mapfile -t labels < <(jq -r '.[0].Config.Labels // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for l in "${labels[@]}"; do args+=(--label "$l"); done

restart_name="$(jq -r '.[0].HostConfig.RestartPolicy.Name // empty' "$META")"
restart_max="$(jq -r '.[0].HostConfig.RestartPolicy.MaximumRetryCount // 0' "$META")"
if [[ -n "$restart_name" && "$restart_name" != "no" ]]; then
  if [[ "$restart_name" == "on-failure" && "$restart_max" -gt 0 ]]; then
    args+=(--restart "${restart_name}:${restart_max}")
  else
    args+=(--restart "$restart_name")
  fi
fi

jq -e '.[0].HostConfig.Privileged == true' "$META" >/dev/null 2>&1 && args+=(--privileged)
jq -e '.[0].HostConfig.ReadonlyRootfs == true' "$META" >/dev/null 2>&1 && args+=(--read-only)
jq -e '.[0].HostConfig.Init == true' "$META" >/dev/null 2>&1 && args+=(--init)

# --- 设备映射: --device ---
mapfile -t devices < <(jq -r '.[0].HostConfig.Devices[]? | "\(.PathOnHost):\(.PathInContainer)\(if .CgroupPermissions then ":\(.CgroupPermissions)" else "" end)"' "$META")
for d in "${devices[@]}"; do args+=(--device "$d"); done

# --- 资源限制: --memory, --cpus, --shm-size ---
shm_size="$(jq -r '.[0].HostConfig.ShmSize // 0' "$META")"
if [[ "$shm_size" != "0" && "$shm_size" != "null" ]]; then args+=(--shm-size "${shm_size}b"); fi

mem="$(jq -r '.[0].HostConfig.Memory // 0' "$META")"
if [[ "$mem" != "0" && "$mem" != "null" ]]; then args+=(--memory "$mem"); fi

mem_swap="$(jq -r '.[0].HostConfig.MemorySwap // 0' "$META")"
if [[ "$mem_swap" != "0" && "$mem_swap" != "null" ]]; then args+=(--memory-swap "$mem_swap"); fi

mem_res="$(jq -r '.[0].HostConfig.MemoryReservation // 0' "$META")"
if [[ "$mem_res" != "0" && "$mem_res" != "null" ]]; then args+=(--memory-reservation "$mem_res"); fi

nano_cpus="$(jq -r '.[0].HostConfig.NanoCpus // 0' "$META")"
if [[ "$nano_cpus" != "0" && "$nano_cpus" != "null" ]]; then
  cpus="$(awk -v n="$nano_cpus" 'BEGIN { printf "%.9g", n / 1000000000 }')"
  args+=(--cpus "$cpus")
fi

cpu_shares="$(jq -r '.[0].HostConfig.CpuShares // 0' "$META")"
if [[ "$cpu_shares" != "0" && "$cpu_shares" != "null" ]]; then args+=(--cpu-shares "$cpu_shares"); fi

cpu_period="$(jq -r '.[0].HostConfig.CpuPeriod // 0' "$META")"
if [[ "$cpu_period" != "0" && "$cpu_period" != "null" ]]; then args+=(--cpu-period "$cpu_period"); fi

cpu_quota="$(jq -r '.[0].HostConfig.CpuQuota // 0' "$META")"
if [[ "$cpu_quota" != "0" && "$cpu_quota" != "null" ]]; then args+=(--cpu-quota "$cpu_quota"); fi

cpuset_cpus="$(jq -r '.[0].HostConfig.CpusetCpus // empty' "$META")"
[[ -n "$cpuset_cpus" ]] && args+=(--cpuset-cpus "$cpuset_cpus")

cpuset_mems="$(jq -r '.[0].HostConfig.CpusetMems // empty' "$META")"
[[ -n "$cpuset_mems" ]] && args+=(--cpuset-mems "$cpuset_mems")

oom_kill_disable="$(jq -r '.[0].HostConfig.OomKillDisable // false' "$META")"
[[ "$oom_kill_disable" == "true" ]] && args+=(--oom-kill-disable)

# --- 命名空间模式: --pid, --ipc, --uts ---
pid_mode="$(jq -r '.[0].HostConfig.PidMode // empty' "$META")"
if [[ -n "$pid_mode" && "$pid_mode" != "null" ]]; then
  pid_mode="$(resolve_container_mode "$pid_mode")"
  args+=(--pid "$pid_mode")
fi

ipc_mode="$(jq -r '.[0].HostConfig.IpcMode // empty' "$META")"
if [[ -n "$ipc_mode" && "$ipc_mode" != "null" ]]; then
  ipc_mode="$(resolve_container_mode "$ipc_mode")"
  args+=(--ipc "$ipc_mode")
fi

uts_mode="$(jq -r '.[0].HostConfig.UTSMode // empty' "$META")"
if [[ -n "$uts_mode" && "$uts_mode" != "null" && "$uts_mode" != "default" ]]; then
  args+=(--uts "$uts_mode")
fi

# --- 健康检查: 正确区分 NONE / CMD / CMD-SHELL ---
hc_kind="$(jq -r '.[0].Config.Healthcheck.Test[0] // empty' "$META" 2>/dev/null || true)"
if [[ "$hc_kind" == "NONE" ]]; then
  args+=(--no-healthcheck)
elif [[ "$hc_kind" == "CMD" || "$hc_kind" == "CMD-SHELL" ]]; then
  if [[ "$hc_kind" == "CMD-SHELL" ]]; then
    hc_test="$(jq -r '.[0].Config.Healthcheck.Test[1] // empty' "$META")"
  else
    hc_test="$(jq -r '.[0].Config.Healthcheck.Test[1:] | map(@sh) | join(" ")' "$META")"
  fi
  hc_interval="$(jq -r '.[0].Config.Healthcheck.Interval // 30000000000' "$META")"
  hc_timeout="$(jq -r '.[0].Config.Healthcheck.Timeout // 30000000000' "$META")"
  hc_retries="$(jq -r '.[0].Config.Healthcheck.Retries // 3' "$META")"
  hc_start_period="$(jq -r '.[0].Config.Healthcheck.StartPeriod // 0' "$META")"
  hc_start_interval="$(jq -r '.[0].Config.Healthcheck.StartInterval // 5000000000' "$META")"
  args+=(--health-cmd "$hc_test")
  args+=(--health-interval "${hc_interval}ns")
  args+=(--health-timeout "${hc_timeout}ns")
  args+=(--health-retries "$hc_retries")
  [[ "$hc_start_period" != "0" ]] && args+=(--health-start-period "${hc_start_period}ns")
  if [[ "$hc_start_interval" != "0" ]] && docker run --help 2>/dev/null | grep -q -- '--health-start-interval'; then
    args+=(--health-start-interval "${hc_start_interval}ns")
  fi
fi

# --- runtime: --runtime (例如 nvidia) ---
runtime="$(jq -r '.[0].HostConfig.Runtime // empty' "$META")"
if [[ -n "$runtime" && "$runtime" != "null" && "$runtime" != "runc" ]]; then
  args+=(--runtime "$runtime")
fi

# --- --group-add ---
mapfile -t group_add < <(jq -r '.[0].HostConfig.GroupAdd[]?' "$META")
for g in "${group_add[@]}"; do args+=(--group-add "$g"); done

# --- storage opt: --storage-opt ---
mapfile -t storage_opts < <(jq -r '.[0].HostConfig.StorageOpt // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for s in "${storage_opts[@]}"; do args+=(--storage-opt "$s"); done

mapfile -t extra_hosts < <(jq -r '.[0].HostConfig.ExtraHosts[]?' "$META")
for h in "${extra_hosts[@]}"; do args+=(--add-host "$h"); done

mapfile -t dns_list < <(jq -r '.[0].HostConfig.Dns[]?' "$META")
for d in "${dns_list[@]}"; do args+=(--dns "$d"); done
mapfile -t dns_search < <(jq -r '.[0].HostConfig.DnsSearch[]?' "$META")
for d in "${dns_search[@]}"; do args+=(--dns-search "$d"); done
mapfile -t dns_opts < <(jq -r '.[0].HostConfig.DnsOptions[]?' "$META")
for d in "${dns_opts[@]}"; do args+=(--dns-option "$d"); done

mapfile -t cap_add < <(jq -r '.[0].HostConfig.CapAdd[]?' "$META")
for c in "${cap_add[@]}"; do args+=(--cap-add "$c"); done
mapfile -t cap_drop < <(jq -r '.[0].HostConfig.CapDrop[]?' "$META")
for c in "${cap_drop[@]}"; do args+=(--cap-drop "$c"); done
mapfile -t sec_opts < <(jq -r '.[0].HostConfig.SecurityOpt[]?' "$META")
for s in "${sec_opts[@]}"; do args+=(--security-opt "$s"); done
mapfile -t sysctls < <(jq -r '.[0].HostConfig.Sysctls // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for s in "${sysctls[@]}"; do args+=(--sysctl "$s"); done
mapfile -t ulimits < <(jq -r '.[0].HostConfig.Ulimits[]? | "\(.Name)=\(.Soft):\(.Hard)"' "$META")
for u in "${ulimits[@]}"; do args+=(--ulimit "$u"); done
mapfile -t tmpfs < <(jq -r '.[0].HostConfig.Tmpfs // {} | to_entries[]? | "\(.key):\(.value)"' "$META")
for t in "${tmpfs[@]}"; do args+=(--tmpfs "$t"); done

log_driver="$(jq -r '.[0].HostConfig.LogConfig.Type // empty' "$META")"
if [[ -n "$log_driver" && "$log_driver" != "json-file" ]]; then
  args+=(--log-driver "$log_driver")
fi
mapfile -t log_opts < <(jq -r '.[0].HostConfig.LogConfig.Config // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for o in "${log_opts[@]}"; do args+=(--log-opt "$o"); done

publish_all="$(jq -r '.[0].HostConfig.PublishAllPorts // false' "$META")"
if [[ "$publish_all" == "true" ]]; then
  args+=(-P)
fi

# 关键修复：稳健还原 PortBindings。
# 旧脚本在 HostPort 为空或 IPv6 HostIp 场景下容易生成无效 -p；这里跳过空 HostPort，并给 IPv6 加 []。
mapfile -t port_bindings < <(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[]? | .key as $c | .value[]? | "\(.HostIp // "")|\(.HostPort // "")|\($c)"' "$META")
published_ports=()
for p in "${port_bindings[@]}"; do
  host_ip="${p%%|*}"
  rest="${p#*|}"
  host_port="${rest%%|*}"
  cont_port="${rest#*|}"

  # 空 HostPort 是 Docker 随机端口分配（如 -p 80 或 -p 0.0.0.0::80），保留空 HostPort 让 Docker 重新随机分配
  [[ -z "$cont_port" ]] && continue

  if [[ -z "$host_port" || "$host_port" == "null" ]]; then
    # 随机端口：格式为 -p [ip::]containerPort[/proto]
    host_port=""
  fi

  if [[ -n "$host_ip" && "$host_ip" != "0.0.0.0" ]]; then
    if [[ "$host_ip" == *:* ]]; then
      port_binding="[${host_ip}]:${host_port}:${cont_port}"
    else
      port_binding="${host_ip}:${host_port}:${cont_port}"
    fi
  else
    port_binding="${host_port}:${cont_port}"
  fi
  args+=(-p "$port_binding")
  published_ports+=("$port_binding")
  echo "[INFO] restore port: ${host_ip:-0.0.0.0}:${host_port}->${cont_port}"
done

mapfile -t mounts < <(jq -r '.[0].Mounts[]? | @base64' "$META")
for m in "${mounts[@]}"; do
  _jq(){ echo "$m" | decode_base64 | jq -r "$1"; }
  m_type="$(_jq '.Type')"
  dest="$(_jq '.Destination')"
  rw="$(_jq '.RW')"
  mode="$(_jq '.Mode // empty')"
  src=""
  case "$m_type" in
    volume) src="$(_jq '.Name')" ;;
    bind) src="$(_jq '.Source')" ;;
    tmpfs) continue ;;
    *) continue ;;
  esac
  [[ -z "$src" || -z "$dest" || "$src" == "null" || "$dest" == "null" ]] && continue

  opts=()
  if [[ -n "$mode" && "$mode" != "null" ]]; then
    IFS=',' read -r -a mode_parts <<<"$mode"
    for part in "${mode_parts[@]}"; do [[ -n "$part" ]] && opts+=("$part"); done
  fi
  [[ "$rw" != "true" ]] && opts+=(ro)
  if ((${#opts[@]})); then
    optstr="$(IFS=,; echo "${opts[*]}")"
    args+=(-v "${src}:${dest}:${optstr}")
  else
    args+=(-v "${src}:${dest}")
  fi
done

network_mode="$(jq -r '.[0].HostConfig.NetworkMode // empty' "$META")"
network_mode="$(resolve_container_mode "$network_mode")"

primary_net=""
if [[ -n "$network_mode" && "$network_mode" != "default" && "$network_mode" != "bridge" ]]; then
  args+=(--network "$network_mode")
  primary_net="$network_mode"
else
  primary_net="bridge"
fi

if [[ "$primary_net" != "bridge" && "$primary_net" != "host" &&
      "$primary_net" != "none" && "$primary_net" != container:* ]]; then
  primary_ip="$(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].IPAMConfig.IPv4Address // .[0].NetworkSettings.Networks[$n].IPAddress // empty' "$META")"
  primary_ip6="$(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].IPAMConfig.IPv6Address // .[0].NetworkSettings.Networks[$n].GlobalIPv6Address // .[0].NetworkSettings.Networks[$n].IPv6Address // empty' "$META")"
  [[ -z "$primary_ip" ]] || args+=(--ip "$primary_ip")
  [[ -z "$primary_ip6" ]] || args+=(--ip6 "$primary_ip6")
  mapfile -t primary_aliases < <(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].Aliases[]? // empty' "$META")
  for primary_alias in "${primary_aliases[@]}"; do
    [[ -z "$primary_alias" || "$primary_alias" == "$name" ]] || args+=(--network-alias "$primary_alias")
  done
fi

args+=("$image")
if ((${#cmd_args[@]})); then
  args+=("${cmd_args[@]}")
fi

run_output=""
run_log="$(mktemp "${TMPDIR:-/tmp}/docker-migrate-run.XXXXXX")" || exit 1
set +e
dm_run_with_activity "创建并启动容器：$name" dm_capture_command "$run_log" "${args[@]}"
run_rc=$?
set -e
run_output="$(cat "$run_log")"
rm -f "$run_log"

if [[ $run_rc -ne 0 ]]; then
  echo "[ERR] 容器创建或启动失败：$name" >&2
  [[ -z "$run_output" ]] || printf '%s\n' "$run_output" >&2
  if grep -Eqi 'port is already allocated|address already in use|Bind for .* failed|failed to bind host port' \
    <<<"$run_output"; then
    echo "[ERR] 已确认宿主机端口绑定冲突。" >&2
    if ((${#published_ports[@]})); then
      echo "[INFO] 本次尝试绑定的端口：" >&2
      for p in "${published_ports[@]}"; do
        echo "[INFO]   - $p" >&2
      done
    fi
    echo "[INFO] 可执行 sudo ss -lntp 检查占用端口的进程。" >&2
  fi
  exit "$run_rc"
fi

# 连接额外网络。
network_restore_failed=0
if [[ "$network_mode" != "host" && "$network_mode" != "none" && "$network_mode" != container:* ]]; then
  mapfile -t net_entries < <(jq -r '.[0].NetworkSettings.Networks | to_entries[]? | @base64' "$META")
  for entry in "${net_entries[@]}"; do
    _net(){ echo "$entry" | decode_base64 | jq -r "$1"; }
    net_name="$(_net '.key')"
    [[ -z "$net_name" || "$net_name" == "$primary_net" || "$net_name" == "bridge" ]] && continue
    ip="$(_net '.value.IPAMConfig.IPv4Address // .value.IPAddress // empty')"
    ip6="$(_net '.value.IPAMConfig.IPv6Address // .value.GlobalIPv6Address // .value.IPv6Address // empty')"
    aliases_raw="$(_net '.value.Aliases // empty | join(" ")')"
    conn_args=()
    [[ -n "$ip" && "$ip" != "null" ]] && conn_args+=(--ip "$ip")
    [[ -n "$ip6" && "$ip6" != "null" ]] && conn_args+=(--ip6 "$ip6")
    if [[ -n "$aliases_raw" && "$aliases_raw" != "null" ]]; then
      for a in $aliases_raw; do conn_args+=(--alias "$a"); done
    fi
    docker network connect "${conn_args[@]}" "$net_name" "$name" >/dev/null 2>&1 || {
      network_restore_failed=1
      echo "[WARN] 连接额外网络失败：$net_name，容器可能缺少网络" >&2
      case "$net_name" in
        macvlan*|ipvlan*|overlay*)
          echo "[WARN] → 网络 $net_name 需管理员在目标服务器预创建（macvlan/ipvlan/overlay 不自动创建）" >&2
          ;;
      esac
    }
  done
fi
if ((network_restore_failed == 1)); then
  exit 1
fi

# 运行中的源容器必须通过启动验证，避免“docker run -d 成功但进程随即退出”后
# 过早删除旧容器。显式 healthcheck 沿用完整健康等待；没有 healthcheck 时要求
# 容器在一个短暂窗口内持续为 running。
health_kind="$(jq -r '.[0].Config.Healthcheck.Test[0] // empty' "$META" 2>/dev/null || true)"
if [[ "$original_running" == "true" &&
      ("$health_kind" == "CMD" || "$health_kind" == "CMD-SHELL") ]]; then
  health_timeout="${RESTORE_HEALTH_TIMEOUT:-60}"
  if ! [[ "$health_timeout" =~ ^[1-9][0-9]*$ ]] || ((health_timeout > 3600)); then
    echo "[WARN] invalid RESTORE_HEALTH_TIMEOUT: $health_timeout (expected 1-3600 seconds)" >&2
    exit 1
  fi
  health_deadline=$((SECONDS + health_timeout))
  health_started=$SECONDS
  health_next_report=0
  health_last_status=""
  while ((SECONDS < health_deadline)); do
    health_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)"
    health_elapsed=$((SECONDS - health_started))
    case "$health_status" in
      healthy)
        echo "[完成] 容器健康检查：$name · ${health_elapsed}秒" >&2
        break
        ;;
      unhealthy | exited | dead)
        echo "[WARN] new container did not become healthy: $name ($health_status)" >&2
        exit 1
        ;;
    esac
    if [[ "$health_status" != "$health_last_status" ]] || ((health_elapsed >= health_next_report)); then
      echo "[进度] 容器健康检查：$name · ${health_status:-未知} · ${health_elapsed}/${health_timeout}秒" >&2
      health_last_status="$health_status"
      health_next_report=$((health_elapsed + 5))
    fi
    sleep 1
  done
  if [[ "${health_status:-}" != "healthy" ]]; then
    echo "[WARN] healthcheck timed out after ${health_timeout}s: $name" >&2
    exit 1
  fi
elif [[ "$original_running" == "true" ]]; then
  startup_grace="${RESTORE_STARTUP_GRACE:-3}"
  if ! [[ "$startup_grace" =~ ^[1-9][0-9]*$ ]] || ((startup_grace > 300)); then
    echo "[WARN] invalid RESTORE_STARTUP_GRACE: $startup_grace (expected 1-300 seconds)" >&2
    exit 1
  fi
  startup_deadline=$((SECONDS + startup_grace))
  startup_started=$SECONDS
  startup_next_report=5
  while :; do
    startup_status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    case "$startup_status" in
      running) ;;
      *)
        echo "[WARN] new container did not remain running: $name (${startup_status:-missing})" >&2
        exit 1
        ;;
    esac
    startup_elapsed=$((SECONDS - startup_started))
    if ((startup_elapsed >= startup_next_report)); then
      echo "[进度] 容器启动验证：$name · running · ${startup_elapsed}/${startup_grace}秒" >&2
      startup_next_report=$((startup_elapsed + 5))
    fi
    ((SECONDS >= startup_deadline)) && break
    sleep 1
  done
  echo "[完成] 容器启动验证：$name · $((SECONDS - startup_started))秒" >&2
fi

if [[ "$original_paused" == "true" ]]; then
  docker pause "$name" >/dev/null 2>&1 || {
    echo "[WARN] failed to restore paused state: $name" >&2
    exit 1
  }
fi

if ((replacement_active == 1)); then
  if ((transaction_mode == 1)); then
    # 由全局事务在全部项目、数据和健康检查通过后统一删除回滚容器。
    replacement_active=0
    echo "[INFO] replacement verified; rollback container retained until transaction commit: $replacement_backup_name"
  elif docker rm -f "$replacement_backup_name" >/dev/null 2>&1; then
    replacement_active=0
    echo "[INFO] replacement verified; removed rollback container: $replacement_backup_name"
  else
    echo "[WARN] new container is running, but rollback container could not be removed: $replacement_backup_name" >&2
  fi
fi
RUN_SH
  # 安全转义容器名中的 \ / &，防止 sed 替换出错
  local escaped_name="$name"
  escaped_name="${escaped_name//\\/\\\\}" # \ → \\
  escaped_name="${escaped_name//\//\\/}"  # / → \/
  escaped_name="${escaped_name//&/\\&}"   # & → \&
  local rendered="${out}.rendered"
  sed "s/__NAME__/${escaped_name}/g" "$out" >"$rendered"
  mv "$rendered" "$out"
  chmod +x "$out"
}

#####################################
# 生成恢复主脚本
#####################################
write_bundle_restore_script() {
  local out="$1"
  cat >"$out" <<'REST_SH'
#!/usr/bin/env bash
set -euo pipefail
umask 077

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BUNDLE_DIR"

say(){ echo -e "\033[1;34m$*\033[0m"; }
warn(){ echo -e "\033[1;33m$*\033[0m"; }

dm_format_elapsed() {
  local seconds="${1:-0}"
  if ((seconds >= 60)); then
    printf '%d 分 %d 秒' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%d 秒' "$seconds"
  fi
}

dm_human() {
  local bytes="${1:-0}" unit=0
  local -a units=(B KB MB GB TB)
  while ((bytes >= 1024 && unit < ${#units[@]} - 1)); do
    bytes=$((bytes / 1024))
    unit=$((unit + 1))
  done
  printf '%s%s' "$bytes" "${units[$unit]}"
}

dm_file_size() {
  stat -c %s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

restore_load_images() {
  local archive="$1" total
  if command -v pv >/dev/null 2>&1; then
    total="$(dm_file_size "$archive")"
    pv -f -s "$total" "$archive" | docker load
  else
    docker load -i "$archive"
  fi
}

dm_progress_watch() {
  local label="$1" file="$2" total="$3" started="$4" owner_pid="$5"
  local mode="${DOCKER_MIGRATE_PROGRESS_MODE:-auto}" interval current elapsed percent message timer_pid=""
  [[ "$mode" != "plain" && "$mode" != "off" ]] || return 0
  if [[ -n "${DOCKER_MIGRATE_PROGRESS_INTERVAL:-}" ]]; then
    interval="$DOCKER_MIGRATE_PROGRESS_INTERVAL"
  elif [[ -t 2 ]]; then
    interval=1
  else
    interval=10
  fi
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=10
  trap '
    if [[ -n "${timer_pid:-}" ]]; then
      kill "$timer_pid" 2>/dev/null || true
      wait "$timer_pid" 2>/dev/null || true
    fi
    exit 0
  ' TERM INT HUP
  while kill -0 "$owner_pid" 2>/dev/null; do
    # 关闭 timer 继承的 stdin 管道。
    # shellcheck disable=SC2217
    sleep "$interval" </dev/null >/dev/null 2>&1 &
    timer_pid=$!
    wait "$timer_pid" 2>/dev/null || true
    timer_pid=""
    kill -0 "$owner_pid" 2>/dev/null || break
    current=0
    [[ -z "$file" ]] || current="$(dm_file_size "$file")"
    elapsed=$((SECONDS - started))
    if ((total > 0)); then
      ((current <= total)) || current=$total
      percent=$((current * 100 / total))
      message="[进度] ${label} · ${percent}% · $(dm_human "$current")/$(dm_human "$total") · $(dm_format_elapsed "$elapsed")"
    elif ((current > 0)); then
      message="[进度] ${label} · $(dm_human "$current") · $(dm_format_elapsed "$elapsed")"
    else
      message="[进度] ${label} · $(dm_format_elapsed "$elapsed")"
    fi
    if [[ -t 2 ]]; then
      printf '\r%-120s\r%s' "" "$message" >&2
    else
      printf '%s\n' "$message" >&2
    fi
  done
  trap - TERM INT HUP
}

dm_run_with_progress() {
  local label="$1" file="$2" total="$3"
  shift 3
  local started=$SECONDS watcher_pid rc current=0 restore_errexit=0 suffix=""
  case $- in *e*) restore_errexit=1 ;; esac
  dm_progress_watch "$label" "$file" "$total" "$started" "$$" &
  watcher_pid=$!
  set +e
  "$@"
  rc=$?
  ((restore_errexit == 0)) || set -e
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  [[ ! -t 2 ]] || printf '\r%-120s\r' "" >&2
  [[ -z "$file" ]] || current="$(dm_file_size "$file")"
  ((current == 0)) || suffix=" · $(dm_human "$current")"
  if ((rc != 0)); then
    printf '[失败] %s · %s%s\n' "$label" \
      "$(dm_format_elapsed "$((SECONDS - started))")" "$suffix" >&2
  fi
  return "$rc"
}

dm_run_with_activity() {
  local label="$1"
  shift
  dm_run_with_progress "$label" "" 0 "$@"
}

dm_run_with_file_progress() {
  local label="$1" file="$2" total="${3:-0}"
  shift 3
  dm_run_with_progress "$label" "$file" "$total" "$@"
}

# Failure tracking
FAILED_VOLUMES=()
FAILED_BINDS=()
FAILED_NETWORKS=()
FAILED_PROJECTS=()
FAILED_CONTAINERS=()
declare -A SKIP_PROJECTS=()
declare -A SKIP_CONTAINERS=()
declare -A SELECTED_TRANSACTION_VOLUMES=()
declare -A PRESERVED_TRANSACTION_FILES=()
SELECTED_TRANSACTION_BINDS=()
RESTORE_TRANSACTION_DIR=""
TRANSACTION_ACTIVE=0
RESTORE_LOCK_METHOD=""
RESTORE_LOCK_FILE=""
RESTORE_LOCK_DIR=""
RESTORE_STAGE="初始化"
RESTORE_STARTED_AT=$SECONDS
RESTORE_COMMIT_STARTED=0

restore_format_elapsed() {
  local seconds="${1:-0}"
  ((seconds < 0)) && seconds=0
  if ((seconds >= 3600)); then
    printf '%d 小时 %d 分 %d 秒\n' "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
  elif ((seconds >= 60)); then
    printf '%d 分 %d 秒\n' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%d 秒\n' "$seconds"
  fi
}

restore_target_container_names() {
  local run project service found_service inspect_file
  while IFS= read -r run; do
    [[ -n "$run" ]] || continue
    basename "${run%.sh}"
  done < <(jq -r '.runs[]?' manifest.json 2>/dev/null || true)
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    found_service=0
    for inspect_file in meta/*.inspect.json; do
      [[ -f "$inspect_file" ]] || continue
      service="$(jq -r --arg project "$project" '
        if (.[0].Config.Labels["com.docker.compose.project"] // "") == $project
        then .[0].Config.Labels["com.docker.compose.service"] // empty
        else empty end
      ' "$inspect_file" 2>/dev/null || true)"
      [[ -n "$service" ]] || continue
      found_service=1
      docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --filter "label=com.docker.compose.service=${service}" \
        --format '{{.Names}}' 2>/dev/null || true
    done
    if ((found_service == 0)); then
      docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Names}}' 2>/dev/null || true
    fi
  done < <(jq -r '.projects[]?.name' manifest.json 2>/dev/null || true)
}

restore_result_metrics() {
  local name state total=0 running=0 paused=0 stopped=0 missing=0 volumes=0 binds=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    total=$((total + 1))
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    case "$state" in
      running | restarting) running=$((running + 1)) ;;
      paused) paused=$((paused + 1)) ;;
      created | exited | dead | removing) stopped=$((stopped + 1)) ;;
      *) missing=$((missing + 1)) ;;
    esac
  done < <(restore_target_container_names | awk 'NF && !seen[$0]++')
  volumes="$(jq -r '.volumes | length' manifest.json 2>/dev/null || echo 0)"
  binds="$(jq -r '.binds | length' manifest.json 2>/dev/null || echo 0)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$total" "$running" "$paused" "$stopped" "$missing" "$volumes" "$binds"
}

restore_record_result() {
  local status="$1" rollback_dir="${2:-}" result_file="${RESTORE_RESULT_FILE:-}" tmp
  [[ -n "$result_file" ]] || return 0
  tmp="${result_file}.tmp.$$"
  if jq -n --arg status "$status" --arg stage "$RESTORE_STAGE" \
    --arg rollback_dir "$rollback_dir" \
    '{status:$status,stage:$stage,rollback_dir:$rollback_dir}' >"$tmp"; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$result_file"
  else
    rm -f "$tmp"
  fi
}

restore_print_final_result() {
  local status="$1" rollback_dir="${2:-}" metrics total running paused stopped missing volumes binds
  local elapsed container_line data_line
  elapsed="$(restore_format_elapsed "$((SECONDS - RESTORE_STARTED_AT))")"
  container_line=""
  data_line=""
  if [[ "$status" == "SUCCESS" ]]; then
    metrics="$(restore_result_metrics)"
    IFS=$'\t' read -r total running paused stopped missing volumes binds <<<"$metrics"
    container_line="容器：${total} 个（运行 ${running} / 暂停 ${paused} / 停止 ${stopped}"
    ((missing == 0)) || container_line+=" / 缺失 ${missing}"
    container_line+="）"
    data_line="数据：${volumes} 个 volume、${binds} 个 bind 目录"
  fi

  printf '\n%s\n' '━━━━━━━━━━ Docker 迁移结果 ━━━━━━━━━━'
  case "$status" in
    SUCCESS)
      printf '结果：✅ 恢复成功\n%s\n%s\n' "$container_line" "$data_line"
      printf '验证：完整性校验、服务启动与健康检查均已通过\n'
      printf '清理：迁移包目录保持不变（手动恢复模式）\n'
      ;;
    FAILED_ROLLED_BACK)
      printf '结果：❌ 恢复失败，已安全回滚\n失败阶段：%s\n' "$RESTORE_STAGE"
      printf '目标端状态：旧服务与原数据已恢复\n诊断目录：%s\n' "$BUNDLE_DIR"
      ;;
    INTERRUPTED_ROLLED_BACK)
      printf '结果：⚠️ 恢复已中断，已安全回滚\n中断阶段：%s\n' "$RESTORE_STAGE"
      printf '目标端状态：旧服务与原数据已恢复\n诊断目录：%s\n' "$BUNDLE_DIR"
      ;;
    FAILED_ROLLBACK_INCOMPLETE | INTERRUPTED_ROLLBACK_INCOMPLETE)
      if [[ "$status" == INTERRUPTED_* ]]; then
        printf '结果：⚠️ 恢复已中断，自动回滚未完全成功\n中断阶段：%s\n' "$RESTORE_STAGE"
      else
        printf '结果：⚠️ 恢复失败，自动回滚未完全成功\n失败阶段：%s\n' "$RESTORE_STAGE"
      fi
      printf '重要：请勿直接启动相关容器，请根据保留的回滚资料人工处理\n'
      [[ -z "$rollback_dir" ]] || printf '回滚资料：%s\n' "$rollback_dir"
      printf '诊断目录：%s\n' "$BUNDLE_DIR"
      ;;
    FAILED_POST_COMMIT)
      printf '结果：⚠️ 服务与数据已恢复，但提交后的清理未完成\n'
      printf '失败阶段：%s\n' "$RESTORE_STAGE"
      [[ -z "$rollback_dir" ]] || printf '待清理资料：%s\n' "$rollback_dir"
      ;;
    INTERRUPTED)
      printf '结果：⚠️ 恢复已中断\n中断阶段：%s\n诊断目录：%s\n' "$RESTORE_STAGE" "$BUNDLE_DIR"
      ;;
    *)
      printf '结果：❌ 恢复失败\n失败阶段：%s\n诊断目录：%s\n' "$RESTORE_STAGE" "$BUNDLE_DIR"
      ;;
  esac
  printf '耗时：%s\n%s\n' "$elapsed" '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

restore_finish_result() {
  local status="$1" rollback_dir="${2:-}"
  restore_record_result "$status" "$rollback_dir" || true
  if [[ "${RESTORE_DEFER_FINAL_SUMMARY:-0}" != "1" ]]; then
    restore_print_final_result "$status" "$rollback_dir"
  fi
}

restore_nontransaction_exit_handler() {
  local rc=$? status="FAILED" rollback_dir="${RESTORE_TRANSACTION_DIR:-}"
  trap - EXIT INT TERM
  transaction_release_lock || true
  if ((rc == 0)); then
    status="SUCCESS"
  elif ((RESTORE_COMMIT_STARTED == 1)); then
    status="FAILED_POST_COMMIT"
  elif [[ "$rc" == "129" || "$rc" == "130" || "$rc" == "143" ]]; then
    status="INTERRUPTED"
  fi
  restore_finish_result "$status" "$rollback_dir"
  exit "$rc"
}

restore_has_failures() {
  (( ${#FAILED_VOLUMES[@]} > 0 ||
     ${#FAILED_BINDS[@]} > 0 ||
     ${#FAILED_NETWORKS[@]} > 0 ||
     ${#FAILED_PROJECTS[@]} > 0 ||
     ${#FAILED_CONTAINERS[@]} > 0 ))
}

print_failure_summary() {
  restore_has_failures || return 0
  warn "============================================"
  warn "  部分内容恢复失败，请检查以下项目："
  ((${#FAILED_VOLUMES[@]} == 0)) || warn "  · 命名卷失败: ${FAILED_VOLUMES[*]}"
  ((${#FAILED_BINDS[@]} == 0)) || warn "  · 绑定目录失败: ${FAILED_BINDS[*]}"
  ((${#FAILED_NETWORKS[@]} == 0)) || warn "  · 自定义网络失败: ${FAILED_NETWORKS[*]}"
  ((${#FAILED_PROJECTS[@]} == 0)) || warn "  · Compose 项目失败: ${FAILED_PROJECTS[*]}"
  if ((${#FAILED_CONTAINERS[@]} > 0)); then
    warn "  · 独立容器失败: ${FAILED_CONTAINERS[*]}"
    warn "  常见原因：端口冲突、镜像缺失、网络配置不兼容。"
    warn "  可用命令排查端口：sudo ss -lntp"
  fi
  warn "============================================"
}

compose_run() {
  if [[ "${COMPOSE_IMPL:-}" == "plugin" ]]; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

compose_rollback_image_cleanup() {
  local rollback_dir="$1" image
  [[ -f "${rollback_dir}/images.list" ]] || return 0
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    docker image rm "$image" >/dev/null 2>&1 || true
  done <"${rollback_dir}/images.list"
}

compose_capture_rollback_metadata() {
  local project="$1" rollback_dir="$2"
  local first_id old_wdir config_files normalized file id service state
  local -a ids=() config_args=()

  mapfile -t ids < <(docker ps -a \
    --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}')
  ((${#ids[@]} > 0)) || return 2
  mkdir -p "$rollback_dir"
  first_id="${ids[0]}"
  old_wdir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$first_id" 2>/dev/null || true)"
  config_files="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$first_id" 2>/dev/null || true)"
  normalized="${config_files//,/:}"
  if [[ -n "$normalized" ]]; then
    IFS=':' read -r -a old_files <<<"$normalized"
    for file in "${old_files[@]}"; do
      [[ -n "$file" ]] || continue
      [[ "$file" == /* ]] || file="${old_wdir}/${file}"
      [[ -f "$file" ]] || {
        warn " · 目标端旧 Compose 配置不存在，无法建立回滚点：$file"
        return 1
      }
      config_args+=(-f "$file")
    done
  fi

  if [[ -n "$old_wdir" ]]; then
    if ! (cd "$old_wdir" && compose_run -p "$project" "${config_args[@]}" config) \
      >"${rollback_dir}/config.yml" 2>/dev/null; then
      warn " · 无法解析目标端旧 Compose 配置，拒绝破坏性替换：$project"
      return 1
    fi
  elif ! compose_run -p "$project" "${config_args[@]}" config \
    >"${rollback_dir}/config.yml" 2>/dev/null; then
    warn " · 目标端缺少 Compose 工作目录，无法建立回滚点：$project"
    return 1
  fi

  printf '{"services":{}}\n' >"${rollback_dir}/images.yml"
  : >"${rollback_dir}/images.list"
  : >"${rollback_dir}/states.tsv"
  for id in "${ids[@]}"; do
    service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$id" 2>/dev/null || true)"
    [[ -n "$service" ]] || {
      warn " · 目标端容器缺少 Compose service 标签：$id"
      compose_rollback_image_cleanup "$rollback_dir"
      return 1
    }
    if awk -F '\t' -v service="$service" '$1 == service { found=1 } END { exit found ? 0 : 1 }' \
      "${rollback_dir}/states.tsv"; then
      warn " · Compose 服务存在多个副本，当前无法保证逐容器回滚：$service"
      compose_rollback_image_cleanup "$rollback_dir"
      return 1
    fi
    state="$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || echo unknown)"
    printf '%s\t%s\t%s\n' "$service" "$state" "$id" >>"${rollback_dir}/states.tsv"
  done
}

compose_capture_rollback_images() {
  local rollback_dir="$1"
  local service state id image tmp
  : >"${rollback_dir}/images.list"
  printf '{"services":{}}\n' >"${rollback_dir}/images.yml"
  while IFS=$'\t' read -r service state id; do
    [[ -n "$service" && -n "$id" ]] || continue
    if ! docker container inspect "$id" >/dev/null 2>&1; then
      warn " · 目标端旧 Compose 容器在建立回滚镜像前消失：$service"
      compose_rollback_image_cleanup "$rollback_dir"
      return 1
    fi
    image="docker-migrate-rollback:${id:0:12}-$$"
    if ! dm_run_with_activity "创建 Compose 回滚镜像：$service" \
      docker commit "$id" "$image" >/dev/null; then
      warn " · 目标端容器回滚镜像创建失败：$service"
      compose_rollback_image_cleanup "$rollback_dir"
      return 1
    fi
    printf '%s\n' "$image" >>"${rollback_dir}/images.list"
    tmp="${rollback_dir}/images.yml.tmp"
    jq --arg service "$service" --arg image "$image" \
      '.services[$service].image = $image' "${rollback_dir}/images.yml" >"$tmp"
    mv "$tmp" "${rollback_dir}/images.yml"
  done <"${rollback_dir}/states.tsv"
}

compose_restore_existing_states() {
  local project="$1" rollback_dir="$2" restore_running="${3:-1}"
  local service state id rc=0
  [[ -f "${rollback_dir}/states.tsv" ]] || return 1
  while IFS=$'\t' read -r service state id; do
    [[ -n "$id" ]] || continue
    if ! docker container inspect "$id" >/dev/null 2>&1; then
      warn " · 目标端旧 Compose 容器已不存在：$service ($id)"
      rc=1
      continue
    fi
    [[ "$restore_running" == "1" ]] || continue
    case "$state" in
      running | restarting)
        docker start "$id" >/dev/null 2>&1 || rc=1
        ;;
      paused)
        docker start "$id" >/dev/null 2>&1 || {
          rc=1
          continue
        }
        docker pause "$id" >/dev/null 2>&1 || rc=1
        ;;
    esac
  done <"${rollback_dir}/states.tsv"
  return "$rc"
}

compose_restore_rollback() {
  local project="$1" rollback_dir="$2" restore_running="${3:-1}"
  local service state id _recorded_id
  local -a start_services=() pause_services=()
  [[ -s "${rollback_dir}/config.yml" && -s "${rollback_dir}/images.yml" ]] || return 1
  (
    cd "$rollback_dir"
    compose_run -p "$project" -f config.yml -f images.yml up --no-start
    while IFS=$'\t' read -r service state _recorded_id; do
      case "$state" in
        running | restarting) start_services+=("$service") ;;
        paused)
          start_services+=("$service")
          pause_services+=("$service")
          ;;
      esac
    done <states.tsv
    if [[ "$restore_running" == "1" ]]; then
      ((${#start_services[@]} == 0)) || \
        compose_run -p "$project" -f config.yml -f images.yml start "${start_services[@]}"
      for service in "${pause_services[@]}"; do
        while IFS= read -r id; do
          [[ -n "$id" ]] || continue
          docker pause "$id" >/dev/null
        done < <(compose_run -p "$project" -f config.yml -f images.yml ps -q "$service")
      done
    fi
  )
}

compose_source_state_records() {
  local project="$1" file file_project service running paused found=0
  for file in "${BUNDLE_DIR}"/meta/*.inspect.json; do
    [[ -f "$file" ]] || continue
    file_project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$file" 2>/dev/null || true)"
    [[ "$file_project" == "$project" ]] || continue
    service="$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // empty' "$file")"
    [[ -n "$service" ]] || continue
    running="$(jq -r '.[0].State.Running // false' "$file")"
    paused="$(jq -r '.[0].State.Paused // false' "$file")"
    if [[ "$paused" == "true" ]]; then
      printf '%s\tpaused\n' "$service"
    elif [[ "$running" == "true" ]]; then
      printf '%s\trunning\n' "$service"
    else
      printf '%s\tstopped\n' "$service"
    fi
    found=1
  done
  ((found == 1))
}

compose_wait_services() {
  local timeout="$1"
  shift
  local deadline=$((SECONDS + timeout)) started=$SECONDS next_report=0
  local service id status all_ready service_found elapsed pending first_pending
  local -a compose_args=()
  while (($# > 0)) && [[ "$1" != -- ]]; do
    compose_args+=("$1")
    shift
  done
  (($# == 0)) || shift
  local -a services=("$@")

  while ((SECONDS < deadline)); do
    all_ready=1
    pending=0
    first_pending=""
    for service in "${services[@]}"; do
      service_found=0
      while IFS= read -r id; do
        [[ -n "$id" ]] || {
          all_ready=0
          pending=$((pending + 1))
          [[ -n "$first_pending" ]] || first_pending="$service（尚未创建）"
          continue
        }
        service_found=1
        status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)"
        case "$status" in
          healthy | running) ;;
          unhealthy | exited | dead)
            warn "Compose 服务健康检查失败：$service（当前 $status）"
            return 1
            ;;
          *)
            all_ready=0
            pending=$((pending + 1))
            [[ -n "$first_pending" ]] || first_pending="$service（${status:-未知}）"
            ;;
        esac
      done < <(compose_run "${compose_args[@]}" ps -q "$service")
      if ((service_found == 0)); then
        all_ready=0
        pending=$((pending + 1))
        [[ -n "$first_pending" ]] || first_pending="$service（未找到容器）"
      fi
    done
    if ((all_ready == 0)); then
      elapsed=$((SECONDS - started))
      if ((elapsed >= next_report)); then
        echo "[进度] Compose 服务健康检查：${services[*]} · 待就绪 ${pending} 个 · ${first_pending:-未知} · ${elapsed}/${timeout}秒" >&2
        next_report=$((elapsed + 5))
      fi
    else
      echo "[完成] Compose 服务健康检查：${services[*]} · $((SECONDS - started))秒" >&2
      return 0
    fi
    sleep 1
  done
  return 1
}

compose_wait_project_health() {
  local project="$1" timeout="$2"
  local deadline=$((SECONDS + timeout)) started=$SECONDS next_report=0
  local id running health all_ready found elapsed pending first_pending
  while ((SECONDS < deadline)); do
    all_ready=1
    found=0
    pending=0
    first_pending=""
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      found=1
      running="$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || echo false)"
      [[ "$running" == "true" ]] || continue
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)"
      case "$health" in
        healthy | none) ;;
        unhealthy)
          warn "Compose 项目健康检查失败：$project（容器 $id 当前 unhealthy）"
          return 1
          ;;
        *)
          all_ready=0
          pending=$((pending + 1))
          [[ -n "$first_pending" ]] || first_pending="容器 $id（${health:-未知}）"
          ;;
      esac
    done < <(docker ps -a \
      --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}')
    if ((found == 0)); then
      all_ready=0
      pending=1
      first_pending="尚未找到项目容器"
    fi
    if ((all_ready == 0)); then
      elapsed=$((SECONDS - started))
      if ((elapsed >= next_report)); then
        echo "[进度] Compose 项目健康检查：$project · 待就绪 ${pending} 个 · ${first_pending:-未知} · ${elapsed}/${timeout}秒" >&2
        next_report=$((elapsed + 5))
      fi
    else
      echo "[完成] Compose 项目健康检查：$project · $((SECONDS - started))秒" >&2
      return 0
    fi
    sleep 1
  done
  return 1
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    "$@"
  fi
}

restore_sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    return 127
  fi
}

restore_verify_checksums() {
  local expected rel file actual count=0
  local -A verified_paths=()
  [[ -f checksums.sha256 ]] || return 2
  while IFS=$'\t' read -r expected rel; do
    [[ -n "$expected" && -n "$rel" ]] || continue
    case "$rel" in /*|..|../*|*/../*|*/..) return 1 ;; esac
    file="${BUNDLE_DIR}/${rel}"
    [[ -f "$file" ]] || return 1
    actual="$(restore_sha256_file "$file")" || return 1
    [[ "$actual" == "$expected" ]] || return 1
    verified_paths["$rel"]=1
    count=$((count + 1))
  done <checksums.sha256
  (( count > 0 )) || return 1
  while IFS= read -r -d '' file; do
    rel="${file#"${BUNDLE_DIR}/"}"
    case "$rel" in checksums.sha256 | restore.sh | .docker_migrate_rollback/*) continue ;; esac
    [[ -n "${verified_paths["$rel"]+present}" ]] || return 1
  done < <(find "$BUNDLE_DIR" -type f -print0)
}

restore_manifest_is_safe() {
  local run name metadata_name
  jq -e '
    type == "object" and
    (.images | type == "array") and
    (.networks | type == "array") and
    (.projects | type == "array") and
    (.volumes | type == "array") and
    (.binds | type == "array") and
    (.runs | type == "array") and
    all(.runs[]; type == "string" and test("^runs/[A-Za-z0-9][A-Za-z0-9_.-]*\\.sh$")) and
    all(.projects[];
      (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) and
      (.working_dir // "" | type == "string" and
        (. == "" or (startswith("/") and (test("(^|/)\\.\\.(/|$)") | not) and
          all(explode[]; . >= 32 and . != 127))))
    ) and
    all(.volumes[]; (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$"))) and
    all(.binds[];
      (.host | type == "string" and startswith("/") and . != "/" and
        (test("(^|/)\\.\\.(/|$)") | not) and
        all(explode[]; . >= 32 and . != 127)) and
      (.file | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*\\.tgz$"))
    )
  ' manifest.json >/dev/null || return 1
  while IFS= read -r run; do
    [[ -f "${BUNDLE_DIR}/${run}" ]] || return 1
    name="${run#runs/}"
    name="${name%.sh}"
    [[ -f "${BUNDLE_DIR}/meta/${name}.inspect.json" ]] || return 1
    metadata_name="$(jq -r '.[0].Name | ltrimstr("/")' \
      "${BUNDLE_DIR}/meta/${name}.inspect.json" 2>/dev/null || true)"
    [[ "$metadata_name" == "$name" ]] || return 1
  done < <(jq -r '.runs[]' manifest.json)
}

archive_members_safe() {
  local archive="$1"
  local allowed_prefix="${2:-}"
  local entry
  # 单次列出成员即可同时验证 gzip/tar 完整性和成员路径；安全链接仍在解压到
  # 一次性容器后由 tree_links_stay_within_root 校验，保持现有链接支持语义。
  tar -tzf "$archive" 2>/dev/null |
    while IFS= read -r entry; do
      entry="${entry#./}"
      case "$entry" in /*|..|../*|*/../*|*/..) exit 1 ;; esac
      if [[ -n "$allowed_prefix" &&
            "$entry" != "$allowed_prefix" &&
            "$entry" != "${allowed_prefix}/"* ]]; then
        exit 1
      fi
    done || return 1
}

tree_links_stay_within_root() {
  local mount_arg="$1"
  # 归档只在一次性容器中解压。即使 tar 先处理恶意链接，写入也只能逃到该
  # 容器的临时根文件系统；随后再拒绝绝对链接和词法上越过挂载根的相对链接。
  # 合法的内部符号链接和硬链接都会保留。硬链接无法跨文件系统逃出挂载点。
  docker run --rm -v "${mount_arg}:/tree:ro" alpine:3.20 sh -eu -c '
    find /tree -type l -exec sh -eu -c '\''
      root="$1"
      shift
      for link in "$@"; do
        target="$(readlink "$link")"
        case "$target" in /*) exit 1 ;; esac
        rel="${link#"${root}/"}"
        case "$rel" in
          */*) dir="${rel%/*}" ;;
          *) dir="" ;;
        esac
        combined="${dir:+${dir}/}${target}"
        depth=0
        old_ifs="$IFS"
        IFS=/
        set -f
        for component in $combined; do
          case "$component" in
            "" | .) ;;
            ..)
              depth=$((depth - 1))
              [ "$depth" -ge 0 ] || exit 1
              ;;
            *) depth=$((depth + 1)) ;;
          esac
        done
        IFS="$old_ifs"
      done
    '\'' sh /tree {} +
  '
}

volume_clear_and_extract() {
  local volume="$1" archive_dir="$2" archive_file="$3" validate_links="${4:-1}"
  if ! docker run --rm \
    -v "${volume}:/to" \
    -v "${archive_dir}:/from:ro" \
    alpine:3.20 sh -eu -c '
      find /to -mindepth 1 -maxdepth 1 -exec rm -rf -- {} \;
      tar -xzf "/from/$1" -C /to
    ' sh "$archive_file"; then
    return 1
  fi
  if [[ "$validate_links" == "1" ]]; then
    tree_links_stay_within_root "$volume" || return 1
  fi
  return 0
}

restore_volume_exact() {
  local volume="$1" archive_dir="$2" archive_file="$3" rollback_dir="$4" existed="$5"
  local rollback_file="rollback_${volume}.tgz"
  mkdir -p "$rollback_dir"
  if ((existed == 1)); then
    if ! docker run --rm \
      -v "${volume}:/from:ro" \
      -v "${rollback_dir}:/rollback" \
      alpine:3.20 sh -eu -c 'tar -czf "/rollback/$1" -C /from .' sh "$rollback_file"; then
      return 1
    fi
  fi

  # Write-ahead：清空卷之前先持久化回滚记录。即使此后收到 TERM，EXIT trap
  # 也能知道该卷必须恢复；日志写入失败时目标数据仍未改动。
  if [[ -n "${RESTORE_TRANSACTION_DIR:-}" ]]; then
    printf '%s\t%s\t%s\n' "$volume" "$existed" "${rollback_dir}/${rollback_file}" \
      >>"${RESTORE_TRANSACTION_DIR}/volumes.tsv" || return 1
  fi

  if volume_clear_and_extract "$volume" "$archive_dir" "$archive_file" 1; then
    if [[ -z "${RESTORE_TRANSACTION_DIR:-}" ]]; then
      rm -f "${rollback_dir}/${rollback_file}"
    fi
    return 0
  fi

  warn " 卷恢复失败，正在回滚目标端原数据：$volume"
  if [[ -n "${RESTORE_TRANSACTION_DIR:-}" ]]; then
    # 全局事务持有回滚包；不要提前删除，让统一回滚按确定顺序处理。
    return 1
  fi
  if ((existed == 1)); then
    volume_clear_and_extract "$volume" "$rollback_dir" "$rollback_file" 0 || return 1
    rm -f "${rollback_dir}/${rollback_file}"
  else
    docker volume rm "$volume" >/dev/null 2>&1 || true
  fi
  return 1
}

root_exec() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n "$@"
  else
    "$@"
  fi
}

restore_bind_exact() {
  local host="$1" archive="$2"
  local parent base stage old staged had_old=0
  [[ "$host" == /* && "$host" != "/" ]] || return 1
  parent="$(dirname "$host")"
  base="$(basename "$host")"
  stage="${parent}/.${base}.docker-migrate-stage-$$"
  old="${parent}/.${base}.docker-migrate-old-$$"

  root_exec mkdir -p "$parent" || return 1
  root_exec rm -rf "$stage" "$old" || return 1
  root_exec mkdir -p "$stage" || return 1
  # 不在宿主机以高权限直接解压。链接若试图逃出 /stage，只会落入一次性容器。
  if ! docker run --rm \
    -v "${stage}:/stage" \
    -v "${archive}:/archive.tgz:ro" \
    alpine:3.20 tar -C /stage -xzf /archive.tgz; then
    root_exec rm -rf "$stage" || true
    return 1
  fi
  staged="${stage}/${host#/}"
  if ! root_exec test -e "$staged" && ! root_exec test -L "$staged"; then
    root_exec rm -rf "$stage" || true
    return 1
  fi
  # bind 根本身若是链接，移动出 staging 后其相对语义会改变；拒绝这种歧义结构。
  if root_exec test -L "$staged"; then
    root_exec rm -rf "$stage" || true
    return 1
  fi
  # 最终只会把 $staged 子树移动到宿主 $host，因此链接边界必须以该子树
  # 为根校验，而不能以更高层 staging 根校验；否则 ../ 可在 mv 后逃逸。
  if ! tree_links_stay_within_root "$staged"; then
    root_exec rm -rf "$stage" || true
    return 1
  fi

  if root_exec test -e "$host" || root_exec test -L "$host"; then
    had_old=1
  fi
  # Write-ahead：rename 旧路径之前先记下旧路径位置。回滚会以 old 是否存在
  # 判断 rename 是否已经发生，因此“已记日志但尚未改动”也是安全状态。
  if [[ -n "${RESTORE_TRANSACTION_DIR:-}" ]]; then
    printf '%s\t%s\t%s\n' "$host" "$had_old" "$old" \
      >>"${RESTORE_TRANSACTION_DIR}/binds.tsv" || {
      root_exec rm -rf "$stage" || true
      return 1
    }
  fi
  if ((had_old == 1)); then
    root_exec mv "$host" "$old" || {
      root_exec rm -rf "$stage" || true
      return 1
    }
  fi
  if ! root_exec mv "$staged" "$host"; then
    if ((had_old == 1)); then root_exec mv "$old" "$host" || true; fi
    root_exec rm -rf "$stage" || true
    return 1
  fi
  root_exec rm -rf "$stage" || true
  if [[ -z "${RESTORE_TRANSACTION_DIR:-}" && $had_old -eq 1 ]]; then
    root_exec rm -rf "$old" || true
  fi
}

compose_networks_from_meta_all() {
  [[ -d meta ]] || return 0
  local f proj
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$f" 2>/dev/null || true)"
    [[ -n "$proj" ]] || continue
    # 只有 manifest.projects 中实际按 Compose 恢复的项目才跳过 [E]；单容器
    # Compose 会按独立容器恢复，其自定义网络仍必须在 [E] 精确创建。
    jq -e --arg project "$proj" 'any(.projects[]?; .name == $project)' \
      "${BUNDLE_DIR}/manifest.json" >/dev/null 2>&1 || continue
    jq -r '.[0].NetworkSettings.Networks | keys[]?' "$f" 2>/dev/null || true
  done | awk '!/^(bridge|host|none)$/' | sort -u
}

compose_networks_from_meta_for_project() {
  local project="$1"
  [[ -d meta ]] || return 0
  local f proj
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$f" 2>/dev/null || true)"
    [[ "$proj" == "$project" ]] || continue
    jq -r '.[0].NetworkSettings.Networks | keys[]?' "$f" 2>/dev/null || true
  done | awk '!/^(bridge|host|none)$/' | sort -u
}

compose_cleanup_conflicting_network() {
  local project="$1" network_name="$2"
  [[ -n "$network_name" ]] || return 0
  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    return 0
  fi
  local proj_label net_label
  proj_label="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$network_name" 2>/dev/null || true)"
  net_label="$(docker network inspect -f '{{ index .Labels "com.docker.compose.network" }}' "$network_name" 2>/dev/null || true)"
  # 仅当网络属于当前项目（有 project label 且匹配）时才允许删除
  # 空 proj_label 表示非 compose 网络（手动创建或外部共享），跳过删除
  if [[ -n "$proj_label" && -n "$net_label" && "$proj_label" == "$project" ]]; then
    if docker network rm "$network_name" >/dev/null 2>&1; then
      echo " · 已清理旧网络：$network_name"
    else
      warn " · 无法清理网络：$network_name（可能仍被占用）"
    fi
  fi
}

compose_network_records() {
  local project="$1"
  shift
  local tmp_cfg=""
  if command -v mktemp >/dev/null 2>&1; then
    tmp_cfg="$(mktemp)"
  else
    tmp_cfg="/tmp/docker_migrate_compose_config_$$.json"
    : > "$tmp_cfg"
  fi

  if compose_run "$@" config --format json >"$tmp_cfg" 2>/dev/null; then
    jq -r '
      .name as $project |
      ((.networks // {"default": {}}) | to_entries[]) |
      [(.value.name // "\($project)_\(.key)"), ((.value.external // false) | tostring)] | @tsv
    ' "$tmp_cfg"
    rm -f "$tmp_cfg" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp_cfg" 2>/dev/null || true

  while IFS= read -r net; do
    [[ -n "$net" ]] || continue
    if [[ "$net" == "${project}_"* ]]; then
      printf '%s\tfalse\n' "$net"
    else
      printf '%s\tunknown\n' "$net"
    fi
  done < <(compose_networks_from_meta_for_project "$project")
}

compose_prepare_networks() {
  local project="$1"
  shift
  local seen=0 net external network_row
  while IFS=$'\t' read -r net external; do
    [[ -n "$net" ]] || continue
    seen=1
    case "$external" in
      true)
        network_row="$(jq -c --arg name "$net" '
          .networks[]? |
          (if type == "string" then
            {name: ., legacy: true, driver: "bridge", internal: false,
             attachable: false, enable_ipv6: false, options: {}, labels: {},
             ipam: {driver: "default", options: {}, config: []}}
           else . end) |
          select(.name == $name)
        ' "${BUNDLE_DIR}/manifest.json" | head -n1)"
        if [[ -n "$network_row" ]]; then
          if ! docker network inspect "$net" >/dev/null 2>&1; then
            warn " · 检测到外部网络缺失，按迁移记录创建：$net"
          fi
          create_network_from_record "$network_row" || {
            warn " · 外部网络无法按迁移记录准备：$net"
            return 1
          }
        elif ! docker network inspect "$net" >/dev/null 2>&1; then
          warn " · 外部网络缺失且迁移包没有其配置，拒绝创建默认错误网络：$net"
          return 1
        else
          warn " · 旧迁移包没有外部网络配置，继续复用目标端已有网络：$net"
        fi
        ;;
      false)
        compose_cleanup_conflicting_network "$project" "$net"
        ;;
      *)
        if [[ "$net" == "${project}_"* ]]; then
          compose_cleanup_conflicting_network "$project" "$net"
        fi
        ;;
    esac
  done < <(compose_network_records "$project" "$@")

  if (( seen == 0 )); then
    while IFS= read -r net; do
      [[ -n "$net" ]] || continue
      if [[ "$net" == "${project}_"* ]]; then
        compose_cleanup_conflicting_network "$project" "$net"
      fi
    done < <(compose_networks_from_meta_for_project "$project")
  fi
}

create_network_from_record() {
  local row="$1"
  local name driver desired_core actual_core desired_labels actual_labels cfg subnet ip_range gateway
  local ipam_driver pair
  local -a create_args option_pairs label_pairs ipam_option_pairs aux_pairs
  name="$(jq -r '.name' <<<"$row")"
  driver="$(jq -r '.driver // "bridge"' <<<"$row")"
  [[ -n "$name" && "$name" != "null" ]] || return 1

  desired_core="$(jq -cS '{
    driver: (.driver // "bridge"),
    internal: (.internal // false),
    attachable: (.attachable // false),
    enable_ipv6: (.enable_ipv6 // false),
    options: (.options // {}),
    ipam: {
      driver: (.ipam.driver // "default"),
      options: (.ipam.options // {}),
      config: (.ipam.config // [])
    }
  }' <<<"$row")"

  if docker network inspect "$name" >/dev/null 2>&1; then
    if [[ "$(jq -r '.legacy // false' <<<"$row")" == "true" ]]; then
      return 0
    fi
    actual_core="$(docker network inspect "$name" | jq -cS '.[0] | {
      driver: (.Driver // "bridge"),
      internal: (.Internal // false),
      attachable: (.Attachable // false),
      enable_ipv6: (.EnableIPv6 // false),
      options: (.Options // {}),
      ipam: {
        driver: (.IPAM.Driver // "default"),
        options: (.IPAM.Options // {}),
        config: (.IPAM.Config // [])
      }
    }')"
    if [[ "$actual_core" != "$desired_core" ]]; then
      warn " 已存在同名但配置不同的网络：$name；为避免断开其他容器，不自动删除。"
      return 1
    fi
    desired_labels="$(jq -cS '.labels // {}' <<<"$row")"
    actual_labels="$(docker network inspect "$name" | jq -cS '.[0].Labels // {}')"
    if [[ "$actual_labels" != "$desired_labels" ]]; then
      warn " 已存在网络的 labels 与迁移记录不同，继续复用且不修改：$name"
    fi
    return 0
  fi

  create_args=(docker network create --driver "$driver")
  [[ "$(jq -r '.internal // false' <<<"$row")" != "true" ]] || create_args+=(--internal)
  [[ "$(jq -r '.attachable // false' <<<"$row")" != "true" ]] || create_args+=(--attachable)
  [[ "$(jq -r '.enable_ipv6 // false' <<<"$row")" != "true" ]] || create_args+=(--ipv6)
  ipam_driver="$(jq -r '.ipam.driver // "default"' <<<"$row")"
  [[ "$ipam_driver" == "default" ]] || create_args+=(--ipam-driver "$ipam_driver")

  mapfile -t option_pairs < <(jq -r '.options // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row")
  for pair in "${option_pairs[@]}"; do create_args+=(--opt "$pair"); done
  mapfile -t label_pairs < <(jq -r '.labels // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row")
  for pair in "${label_pairs[@]}"; do create_args+=(--label "$pair"); done
  mapfile -t ipam_option_pairs < <(jq -r '.ipam.options // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row")
  for pair in "${ipam_option_pairs[@]}"; do create_args+=(--ipam-opt "$pair"); done

  while IFS= read -r cfg; do
    [[ -n "$cfg" ]] || continue
    subnet="$(jq -r '.Subnet // empty' <<<"$cfg")"
    ip_range="$(jq -r '.IPRange // empty' <<<"$cfg")"
    gateway="$(jq -r '.Gateway // empty' <<<"$cfg")"
    [[ -z "$subnet" ]] || create_args+=(--subnet "$subnet")
    [[ -z "$ip_range" ]] || create_args+=(--ip-range "$ip_range")
    [[ -z "$gateway" ]] || create_args+=(--gateway "$gateway")
    mapfile -t aux_pairs < <(jq -r '.AuxiliaryAddresses // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$cfg")
    for pair in "${aux_pairs[@]}"; do create_args+=(--aux-address "$pair"); done
  done < <(jq -c '.ipam.config[]?' <<<"$row")
  create_args+=("$name")

  "${create_args[@]}" >/dev/null
}

transaction_path_is_safe() {
  local path="$1"
  [[ "$path" == /* && "$path" != "/" ]] || return 1
  case "$path" in *'/../'* | */..) return 1 ;; esac
}

transaction_acquire_lock() {
  local rollback_base="$1" owner_host owner_pid
  RESTORE_LOCK_FILE="${rollback_base}/migration.lock"
  RESTORE_LOCK_DIR="${RESTORE_LOCK_FILE}.d"
  if command -v flock >/dev/null 2>&1; then
    RESTORE_LOCK_METHOD="flock"
    exec 201>"$RESTORE_LOCK_FILE" || return 1
    if ! flock -n 201 2>/dev/null; then
      exec 201>&-
      RESTORE_LOCK_METHOD=""
      warn "另一个 Docker 恢复事务正在运行，已拒绝并发恢复。"
      return 1
    fi
    return 0
  fi

  RESTORE_LOCK_METHOD="mkdir"
  if ! mkdir "$RESTORE_LOCK_DIR" 2>/dev/null; then
    if [[ -f "${RESTORE_LOCK_DIR}/owner" ]]; then
      IFS=$'\t' read -r owner_host owner_pid <"${RESTORE_LOCK_DIR}/owner" || true
      if [[ "$owner_host" == "$(hostname)" && "$owner_pid" =~ ^[0-9]+$ ]] &&
        ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -f "${RESTORE_LOCK_DIR}/owner" 2>/dev/null || true
        rmdir "$RESTORE_LOCK_DIR" 2>/dev/null || true
      fi
    fi
    if ! mkdir "$RESTORE_LOCK_DIR" 2>/dev/null; then
      RESTORE_LOCK_METHOD=""
      warn "另一个 Docker 恢复事务正在运行，已拒绝并发恢复。"
      return 1
    fi
  fi
  if ! printf '%s\t%s\n' "$(hostname)" "$$" >"${RESTORE_LOCK_DIR}/owner"; then
    rm -f "${RESTORE_LOCK_DIR}/owner" 2>/dev/null || true
    rmdir "$RESTORE_LOCK_DIR" 2>/dev/null || true
    RESTORE_LOCK_METHOD=""
    return 1
  fi
}

transaction_release_lock() {
  case "${RESTORE_LOCK_METHOD:-}" in
    flock)
      flock -u 201 2>/dev/null || true
      exec 201>&- 2>/dev/null || true
      ;;
    mkdir)
      rm -f "${RESTORE_LOCK_DIR}/owner" 2>/dev/null || true
      rmdir "$RESTORE_LOCK_DIR" 2>/dev/null || true
      ;;
  esac
  RESTORE_LOCK_METHOD=""
}

transaction_base64_encode() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

transaction_base64_decode() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s' "$1" | base64 -D
  else
    printf '%s' "$1" | base64 -d
  fi
}

transaction_preserve_file() {
  local destination="$1" encoded index backup existed=0
  transaction_path_is_safe "$destination" || return 1
  encoded="$(transaction_base64_encode "$destination")" || return 1
  if [[ -n "${PRESERVED_TRANSACTION_FILES[$encoded]:-}" ]]; then
    return 0
  fi
  PRESERVED_TRANSACTION_FILES["$encoded"]=1
  index="$(wc -l <"${RESTORE_TRANSACTION_DIR}/files.tsv" | tr -d ' ')"
  backup="${RESTORE_TRANSACTION_DIR}/file_backups/${index}"
  if root_exec test -e "$destination" || root_exec test -L "$destination"; then
    root_exec cp -a "$destination" "$backup" || return 1
    existed=1
  fi
  printf '%s\t%s\t%s\n' "$encoded" "$existed" "$backup" \
    >>"${RESTORE_TRANSACTION_DIR}/files.tsv"
}

transaction_install_file() {
  local source="$1" destination="$2"
  [[ -f "$source" ]] || return 1
  transaction_preserve_file "$destination" || return 1
  if root_exec test -e "$destination" || root_exec test -L "$destination"; then
    root_exec rm -rf "$destination" || return 1
  fi
  root_exec mkdir -p "$(dirname "$destination")" || return 1
  root_exec cp -a "$source" "$destination"
}

transaction_install_tree() {
  local source="$1" destination="$2" file rel
  [[ -d "$source" ]] || return 1
  transaction_path_is_safe "${destination}/.docker-migrate-path-check" || return 1
  while IFS= read -r -d '' file; do
    rel="${file#"${source}/"}"
    transaction_install_file "$file" "${destination}/${rel}" || return 1
  done < <(find "$source" -type f -print0)
}

transaction_restore_files() {
  local encoded existed backup destination rc=0 i
  local -a records=()
  [[ -f "${RESTORE_TRANSACTION_DIR}/files.tsv" ]] || return 0
  mapfile -t records <"${RESTORE_TRANSACTION_DIR}/files.tsv"
  for ((i = ${#records[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r encoded existed backup <<<"${records[$i]}"
    destination="$(transaction_base64_decode "$encoded")" || {
      rc=1
      continue
    }
    transaction_path_is_safe "$destination" || {
      rc=1
      continue
    }
    if root_exec test -e "$destination" || root_exec test -L "$destination"; then
      root_exec rm -rf "$destination" || {
        rc=1
        continue
      }
    fi
    if [[ "$existed" == "1" ]]; then
      root_exec mkdir -p "$(dirname "$destination")" || {
        rc=1
        continue
      }
      if ! root_exec cp -a "$backup" "$destination"; then
        warn " · Compose 配置文件回滚失败：$destination"
        rc=1
      fi
    fi
  done
  return "$rc"
}

transaction_mount_paths_overlap() {
  local first="$1" second="$2"
  while [[ "$first" != "/" && "$first" == */ ]]; do first="${first%/}"; done
  while [[ "$second" != "/" && "$second" == */ ]]; do second="${second%/}"; done
  [[ "$first" == "$second" || "$first" == "/" || "$second" == "/" ||
    "$first" == "${second}/"* || "$second" == "${first}/"* ]]
}

transaction_normalize_path() {
  local path="$1" probe component suffix="" resolved parent base component_i last_index
  [[ -n "$path" ]] || return 1
  [[ "$path" == /* ]] || path="${PWD}/${path}"
  while [[ "$path" != "/" && "$path" == */ ]]; do path="${path%/}"; done

  # macOS realpath 没有 GNU -m。先向上寻找最近的已存在祖先，用普通
  # realpath/readlink/pwd -P 解析 symlink，再把不存在的尾部拼回并词法归一化。
  probe="$path"
  while [[ ! -e "$probe" && ! -L "$probe" ]]; do
    [[ "$probe" != "/" ]] || break
    component="${probe##*/}"
    suffix="${component}${suffix:+/${suffix}}"
    probe="${probe%/*}"
    [[ -n "$probe" ]] || probe="/"
  done

  resolved=""
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath "$probe" 2>/dev/null || true)"
  fi
  if [[ -z "$resolved" ]] && command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$probe" 2>/dev/null || true)"
  fi
  if [[ -z "$resolved" ]]; then
    if [[ -d "$probe" ]]; then
      resolved="$(cd -P "$probe" 2>/dev/null && pwd -P)" || return 1
    elif [[ -e "$probe" && ! -L "$probe" ]]; then
      parent="$(dirname "$probe")"
      base="$(basename "$probe")"
      parent="$(cd -P "$parent" 2>/dev/null && pwd -P)" || return 1
      resolved="${parent}/${base}"
    else
      # 无法可靠解析 broken symlink 时必须 fail closed，不能退回易绕过的字符串比较。
      return 1
    fi
  fi

  path="${resolved}${suffix:+/${suffix}}"
  local -a components=() normalized=()
  IFS='/' read -r -a components <<<"$path"
  for component in "${components[@]}"; do
    case "$component" in
      "" | .) ;;
      ..)
        if ((${#normalized[@]} > 0)); then
          last_index=$((${#normalized[@]} - 1))
          unset "normalized[$last_index]"
        fi
        ;;
      *) normalized+=("$component") ;;
    esac
  done
  if ((${#normalized[@]} == 0)); then
    printf '/\n'
  else
    printf '/%s' "${normalized[0]}"
    for ((component_i = 1; component_i < ${#normalized[@]}; component_i++)); do
      printf '/%s' "${normalized[$component_i]}"
    done
    printf '\n'
  fi
}

transaction_internal_paths_are_safe() {
  local rollback_base lock_base host normalized_host label protected normalized_protected protected_i
  rollback_base="${RESTORE_ROLLBACK_BASE:-${HOME:-${BUNDLE_DIR}}/.docker_migrate_rollback}"
  lock_base="${RESTORE_LOCK_BASE:-${HOME:-${BUNDLE_DIR}}/.docker_migrate_locks}"
  local -a protected_paths=(
    "迁移包目录" "$BUNDLE_DIR"
    "事务回滚目录" "$rollback_base"
    "并发锁目录" "$lock_base"
  )
  if [[ -n "${RESTORE_SESSION_DIR:-}" ]]; then
    protected_paths+=("下载恢复会话目录" "$RESTORE_SESSION_DIR")
  fi

  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    normalized_host="$(transaction_normalize_path "$host")" || return 1
    for ((protected_i = 0; protected_i < ${#protected_paths[@]}; protected_i += 2)); do
      label="${protected_paths[$protected_i]}"
      protected="${protected_paths[$((protected_i + 1))]}"
      normalized_protected="$(transaction_normalize_path "$protected")" || return 1
      if transaction_mount_paths_overlap "$normalized_host" "$normalized_protected"; then
        warn "绑定目录与 ${label} 重叠，已在改动目标数据前拒绝恢复：$host"
        warn "冲突路径：$normalized_protected"
        warn "请把 RESTORE_BASE、RESTORE_ROLLBACK_BASE 与 RESTORE_LOCK_BASE 放到该 bind 之外后重试。"
        return 1
      fi
    done
  done < <(jq -r '.binds[].host' manifest.json)
}

transaction_container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

transaction_rename_container() {
  local old_name="$1" new_name="$2"
  for _ in {1..20}; do
    if docker rename "$old_name" "$new_name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

transaction_restore_container_networks() {
  local container="$1" metadata_file="$2" entry network ip ip6 alias
  local -a connect_args=()
  [[ -f "$metadata_file" ]] || return 1
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    network="$(jq -r '.key' <<<"$entry")"
    case "$network" in "" | host | none) continue ;; esac
    if docker inspect "$container" | jq -e --arg network "$network" \
      '.[0].NetworkSettings.Networks[$network] != null' >/dev/null 2>&1; then
      continue
    fi
    if [[ "$network" == "bridge" ]]; then
      docker network connect "$network" "$container" >/dev/null 2>&1 || return 1
      continue
    fi
    connect_args=()
    ip="$(jq -r '.value.IPAMConfig.IPv4Address // .value.IPAddress // empty' <<<"$entry")"
    ip6="$(jq -r '.value.IPAMConfig.IPv6Address // .value.GlobalIPv6Address // .value.IPv6Address // empty' <<<"$entry")"
    [[ -z "$ip" ]] || connect_args+=(--ip "$ip")
    [[ -z "$ip6" ]] || connect_args+=(--ip6 "$ip6")
    while IFS= read -r alias; do
      [[ -z "$alias" ]] || connect_args+=(--alias "$alias")
    done < <(jq -r '.value.Aliases[]? // empty' <<<"$entry")
    docker network connect "${connect_args[@]}" "$network" "$container" >/dev/null 2>&1 || return 1
  done < <(jq -c 'to_entries[]?' "$metadata_file")
}

transaction_restore_container_state() {
  local name="$1" state="$2"
  case "$state" in
    running | restarting)
      dm_run_with_activity "启动目标端旧容器：$name" docker start "$name" >/dev/null || return 1
      [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" == "true" ]]
      ;;
    paused)
      dm_run_with_activity "启动目标端旧容器：$name" docker start "$name" >/dev/null || return 1
      docker pause "$name" >/dev/null 2>&1
      ;;
  esac
}

transaction_quiesce_containers() {
  local name state running stop_rc=0 verify_rc=0
  local -a stop_names=()
  (($# > 0)) || return 0

  for name in "$@"; do
    transaction_container_exists "$name" || return 1
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    [[ "$state" != "paused" ]] || docker unpause "$name" >/dev/null 2>&1 || return 1
    case "$state" in
      running | restarting | paused) stop_names+=("$name") ;;
    esac
  done
  ((${#stop_names[@]} > 0)) || return 0

  dm_run_with_activity "批量停止目标端容器（${#stop_names[@]} 个）" \
    docker stop "${stop_names[@]}" >/dev/null || stop_rc=$?
  for name in "${stop_names[@]}"; do
    if ! running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" ||
      [[ "$running" != "false" ]]; then
      warn " · 目标端容器未能停止或状态不可确认：$name"
      verify_rc=1
    fi
  done
  ((verify_rc == 0)) || return 1
  if ((stop_rc != 0)); then
    warn " · docker stop 返回异常，但已确认所有目标端容器停止。"
  fi
  return 0
}

transaction_quiesce_container() {
  transaction_quiesce_containers "$1"
}

transaction_build_quiesce_list() {
  local shared_file="$1" managed_file="$2" output="$3"
  local partial="${output}.partial.$$" rc=0
  rm -f -- "$partial"
  if {
    cut -f1 "$shared_file" || exit 1
    cat "$managed_file" || exit 1
  } | awk 'NF' | sort -u >"$partial"; then
    if mv "$partial" "$output"; then
      return 0
    else
      rc=$?
    fi
  else
    rc=$?
  fi
  rm -f -- "$partial"
  return "$rc"
}

transaction_discard_prepared() {
  local rollback_dir
  [[ -n "$RESTORE_TRANSACTION_DIR" ]] || return 0
  if [[ -d "${RESTORE_TRANSACTION_DIR}/compose" ]]; then
    for rollback_dir in "${RESTORE_TRANSACTION_DIR}"/compose/*; do
      [[ -d "$rollback_dir" ]] || continue
      compose_rollback_image_cleanup "$rollback_dir"
    done
  fi
  rm -rf "$RESTORE_TRANSACTION_DIR"
  RESTORE_TRANSACTION_DIR=""
  export RESTORE_TRANSACTION_DIR
  transaction_release_lock
  trap restore_nontransaction_exit_handler EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

transaction_remove_new_services() {
  local project had_old name state backup id rc=0
  if [[ -f "${RESTORE_TRANSACTION_DIR}/standalone.tsv" ]]; then
    while IFS=$'\t' read -r name had_old state; do
      [[ -n "$name" ]] || continue
      backup="$(awk -F '\t' -v name="$name" '$1 == name { print $2; exit }' \
        "${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv")"
      if [[ -n "$backup" ]]; then
        if transaction_container_exists "$backup"; then
          if transaction_container_exists "$name"; then
            docker rm -f "$name" >/dev/null 2>&1 || true
            if transaction_container_exists "$name"; then
              warn " · 无法静默并删除本次新建的单容器：$name"
              rc=1
            fi
          fi
        elif transaction_container_exists "$name"; then
          # WAL 已写入但 rename 尚未发生；当前仍是原容器，不删除。
          :
        else
          warn " · 单容器及其预登记回滚点均不存在：$name"
          rc=1
        fi
      elif [[ "$had_old" == "0" ]]; then
        docker rm -f "$name" >/dev/null 2>&1 || true
        if transaction_container_exists "$name"; then
          warn " · 无法静默并删除本次新建的单容器：$name"
          rc=1
        fi
      fi
    done <"${RESTORE_TRANSACTION_DIR}/standalone.tsv"
  fi

  if [[ -f "${RESTORE_TRANSACTION_DIR}/compose.tsv" ]]; then
    while IFS=$'\t' read -r project had_old; do
      [[ -n "$project" ]] || continue
      grep -Fxq "$project" "${RESTORE_TRANSACTION_DIR}/compose_replaced.list" || continue
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        docker rm -f "$id" >/dev/null 2>&1 || rc=1
      done < <(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}')
      if [[ -n "$(docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --format '{{.ID}}')" ]]; then
        warn " · 新 Compose 项目仍有容器未能删除，禁止回灌旧数据：$project"
        rc=1
      fi
    done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  fi
  return "$rc"
}

transaction_restore_volumes() {
  local volume existed rollback_file rc=0 i
  local -a records=()
  [[ -f "${RESTORE_TRANSACTION_DIR}/volumes.tsv" ]] || return 0
  mapfile -t records <"${RESTORE_TRANSACTION_DIR}/volumes.tsv"
  for ((i = ${#records[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r volume existed rollback_file <<<"${records[$i]}"
    [[ -n "$volume" ]] || continue
    if [[ "$existed" == "1" ]]; then
      if ! volume_clear_and_extract "$volume" "$(dirname "$rollback_file")" \
        "$(basename "$rollback_file")" 0; then
        warn " · 命名卷数据回滚失败：$volume"
        rc=1
      fi
    elif ! docker volume rm "$volume" >/dev/null 2>&1; then
      warn " · 无法删除本次新建的命名卷：$volume"
      rc=1
    fi
  done
  return "$rc"
}

transaction_restore_binds() {
  local host had_old old rc=0 i
  local -a records=()
  [[ -f "${RESTORE_TRANSACTION_DIR}/binds.tsv" ]] || return 0
  mapfile -t records <"${RESTORE_TRANSACTION_DIR}/binds.tsv"
  for ((i = ${#records[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r host had_old old <<<"${records[$i]}"
    [[ "$host" == /* && "$host" != "/" ]] || {
      rc=1
      continue
    }
    if [[ "$had_old" == "1" ]]; then
      if root_exec test -e "$old" || root_exec test -L "$old"; then
        if root_exec test -e "$host" || root_exec test -L "$host"; then
          root_exec rm -rf "$host" || {
            warn " · 无法移除本次恢复的绑定路径：$host"
            rc=1
            continue
          }
        fi
      elif root_exec test -e "$host" || root_exec test -L "$host"; then
        # WAL 可能已写入但 rename 尚未发生，或本地失败处理已把旧路径移回。
        continue
      else
        warn " · 绑定目录及其回滚点均不存在：$host"
        rc=1
        continue
      fi
      if ! root_exec mv "$old" "$host"; then
        warn " · 绑定目录数据回滚失败：$host"
        rc=1
      fi
    elif root_exec test -e "$host" || root_exec test -L "$host"; then
      root_exec rm -rf "$host" || {
        warn " · 无法移除本次新建的绑定路径：$host"
        rc=1
      }
    fi
  done
  return "$rc"
}

transaction_restore_standalones() {
  local restore_running="$1" name had_old state backup network_file rc=0 restored_from_backup
  [[ -f "${RESTORE_TRANSACTION_DIR}/standalone.tsv" ]] || return 0
  while IFS=$'\t' read -r name had_old state; do
    [[ -n "$name" ]] || continue
    if [[ "$had_old" == "1" ]]; then
      restored_from_backup=0
      backup="$(awk -F '\t' -v name="$name" '$1 == name { print $2; exit }' \
        "${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv")"
      if [[ -n "$backup" ]] && transaction_container_exists "$backup"; then
        docker rm -f "$name" >/dev/null 2>&1 || true
        if ! transaction_rename_container "$backup" "$name"; then
          warn " · 无法恢复旧单容器名称：$name（回滚点：$backup）"
          rc=1
          continue
        fi
        restored_from_backup=1
      elif ! transaction_container_exists "$name"; then
        warn " · 旧单容器及其回滚点均不存在：$name"
        rc=1
        continue
      fi
      if ((restored_from_backup == 1)); then
        network_file="${RESTORE_TRANSACTION_DIR}/standalone_networks/${name}.json"
        if ! transaction_restore_container_networks "$name" "$network_file"; then
          warn " · 旧单容器网络恢复失败：$name"
          rc=1
          continue
        fi
      fi
      if [[ "$restore_running" == "1" ]] && ! transaction_restore_container_state "$name" "$state"; then
        warn " · 无法恢复旧单容器运行状态：$name ($state)"
        rc=1
      fi
    fi
  done <"${RESTORE_TRANSACTION_DIR}/standalone.tsv"
  return "$rc"
}

transaction_restore_compose() {
  local restore_running="$1" project had_old rollback_dir rc=0
  [[ -f "${RESTORE_TRANSACTION_DIR}/compose.tsv" ]] || return 0
  while IFS=$'\t' read -r project had_old; do
    [[ -n "$project" ]] || continue
    [[ "$had_old" == "1" ]] || continue
    rollback_dir="${RESTORE_TRANSACTION_DIR}/compose/${project}"
    if grep -Fxq "$project" "${RESTORE_TRANSACTION_DIR}/compose_replaced.list"; then
      if ! compose_restore_rollback "$project" "$rollback_dir" "$restore_running"; then
        warn " · Compose 项目自动回滚失败：$project（回滚点：$rollback_dir）"
        rc=1
      fi
    elif ! compose_restore_existing_states "$project" "$rollback_dir" "$restore_running"; then
      warn " · Compose 原容器运行状态恢复失败：$project"
      rc=1
    fi
  done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  return "$rc"
}

transaction_restore_shared() {
  local name state rc=0
  [[ -f "${RESTORE_TRANSACTION_DIR}/shared.tsv" ]] || return 0
  while IFS=$'\t' read -r name state; do
    [[ -n "$name" ]] || continue
    if ! transaction_restore_container_state "$name" "$state"; then
      warn " · 无法恢复共享挂载容器状态：$name ($state)"
      rc=1
    fi
    done <"${RESTORE_TRANSACTION_DIR}/shared.tsv"
  return "$rc"
}

transaction_cleanup_artifacts() {
  local preserve_compose="${1:-0}"
  local name backup state project had_old rollback_dir volume existed rollback_file host old image
  local rc=0
  if [[ -f "${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv" ]]; then
    while IFS=$'\t' read -r name backup state; do
      [[ -n "$backup" ]] || continue
      if ! docker rm -f "$backup" >/dev/null 2>&1; then
        if ! docker info >/dev/null 2>&1 || transaction_container_exists "$backup"; then
          warn " · 无法清理旧单容器回滚点：$backup"
          rc=1
        fi
      fi
    done <"${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv"
  fi
  if [[ "$preserve_compose" != "1" && -f "${RESTORE_TRANSACTION_DIR}/compose.tsv" ]]; then
    while IFS=$'\t' read -r project had_old; do
      [[ "$had_old" == "1" ]] || continue
      rollback_dir="${RESTORE_TRANSACTION_DIR}/compose/${project}"
      [[ -f "${rollback_dir}/images.list" ]] || continue
      while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        if ! docker image rm "$image" >/dev/null 2>&1; then
          if ! docker info >/dev/null 2>&1 ||
            docker image inspect "$image" >/dev/null 2>&1; then
            warn " · 无法清理 Compose 回滚镜像：$image"
            rc=1
          fi
        fi
      done <"${rollback_dir}/images.list"
    done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  fi
  if [[ -f "${RESTORE_TRANSACTION_DIR}/volumes.tsv" ]]; then
    while IFS=$'\t' read -r volume existed rollback_file; do
      [[ "$existed" == "1" ]] || continue
      if ! rm -f "$rollback_file"; then
        warn " · 无法清理命名卷回滚包：$rollback_file"
        rc=1
      fi
    done <"${RESTORE_TRANSACTION_DIR}/volumes.tsv"
  fi
  if [[ -f "${RESTORE_TRANSACTION_DIR}/binds.tsv" ]]; then
    while IFS=$'\t' read -r host had_old old; do
      [[ "$had_old" == "1" ]] || continue
      if ! root_exec rm -rf "$old"; then
        warn " · 无法清理绑定目录回滚点：$old"
        rc=1
      fi
    done <"${RESTORE_TRANSACTION_DIR}/binds.tsv"
  fi
  if ! root_exec rm -rf "${RESTORE_TRANSACTION_DIR}/file_backups"; then
    warn " · 无法清理文件回滚点：${RESTORE_TRANSACTION_DIR}/file_backups"
    rc=1
  fi

  # 清理失败时保留所有事务清单。提交后的 EXIT handler 会将该目录报告为
  # FAILED_POST_COMMIT 的待清理资料，便于定位尚未删除的回滚点。
  return "$rc"
}

transaction_rollback() {
  local name state project had_old services_quiet=1 data_ok=1 rc=0 preserve_compose=0
  ((TRANSACTION_ACTIVE == 1)) || return 0
  warn "恢复事务失败，正在统一回滚服务与数据……"

  # 提交阶段若某个共享写入者重启失败，先重新静默已经启动的写入者。
  if [[ -f "${RESTORE_TRANSACTION_DIR}/shared.tsv" ]]; then
    while IFS=$'\t' read -r name state; do
      [[ -n "$name" ]] || continue
      transaction_quiesce_container "$name" >/dev/null || true
    done <"${RESTORE_TRANSACTION_DIR}/shared.tsv"
  fi

  dm_run_with_activity "自动回滚：停止并移除本次新服务" \
    transaction_remove_new_services || services_quiet=0
  if ((services_quiet == 1)); then
    # 目标文件最后写入、但可能位于已替换 bind 内；严格按修改逆序回滚，
    # 先撤销单文件覆盖，再整体换回 bind，最后恢复 volume。
    dm_run_with_activity "自动回滚：恢复被替换的配置文件" \
      transaction_restore_files || data_ok=0
    dm_run_with_activity "自动回滚：恢复绑定目录数据" \
      transaction_restore_binds || data_ok=0
    dm_run_with_activity "自动回滚：恢复命名卷数据" \
      transaction_restore_volumes || data_ok=0
    ((data_ok == 1)) || rc=1

    say "[进度] 自动回滚：恢复旧 Compose 项目"
    transaction_restore_compose "$data_ok" || rc=1
    say "[进度] 自动回滚：恢复旧独立容器"
    transaction_restore_standalones "$data_ok" || rc=1
    if ((data_ok == 1)); then
      say "[进度] 自动回滚：恢复共享挂载写入者"
      transaction_restore_shared || rc=1
    else
      warn "数据回滚不完整，旧服务与共享写入者保持停止，请按回滚目录人工处理。"
    fi
  else
    rc=1
    data_ok=0
    warn "新服务未能全部静默，禁止回灌旧数据；已保留全部回滚点供人工处理。"
  fi

  if ((rc == 0)); then
    while IFS=$'\t' read -r project had_old; do
      if [[ "$had_old" == "1" ]] &&
        grep -Fxq "$project" "${RESTORE_TRANSACTION_DIR}/compose_replaced.list"; then
        preserve_compose=1
        break
      fi
    done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
    if ((preserve_compose == 1)); then
      # Compose 会把实际配置文件路径写入容器 labels。回滚后的容器仍引用这里的
      # config.yml/images.yml，因此保留这些小文件，后续迁移才能再次建立回滚点。
      if ! transaction_cleanup_artifacts 1; then
        warn "部分无用回滚资料未能清理，事务清单已保留：$RESTORE_TRANSACTION_DIR"
      fi
      warn "目标端旧服务、volume 与 bind 数据已统一恢复。"
      warn "Compose 回滚配置需随旧容器保留：$RESTORE_TRANSACTION_DIR"
    else
      if transaction_cleanup_artifacts; then
        rm -rf "$RESTORE_TRANSACTION_DIR" ||
          warn "回滚已完成，但事务目录未能删除：$RESTORE_TRANSACTION_DIR"
      else
        warn "回滚已完成，但部分无用回滚资料未能清理：$RESTORE_TRANSACTION_DIR"
      fi
      warn "目标端旧服务、volume 与 bind 数据已统一恢复。"
    fi
  else
    warn "自动回滚未完全成功，已保留回滚目录：$RESTORE_TRANSACTION_DIR"
  fi
  TRANSACTION_ACTIVE=0
  transaction_release_lock
  return "$rc"
}

transaction_exit_handler() {
  local original_rc=$? exit_rc rollback_rc=0 rollback_dir="${RESTORE_TRANSACTION_DIR:-}" status
  exit_rc=$original_rc
  trap - EXIT INT TERM

  # RESTORE_COMMIT_STARTED 是唯一的不可逆提交点。它置位后绝不再回滚，即使
  # TRANSACTION_ACTIVE 尚未来得及清零或清理过程中收到 INT/TERM。
  if ((RESTORE_COMMIT_STARTED == 1)); then
    transaction_release_lock || true
    if ((original_rc == 0)); then
      status="SUCCESS"
    else
      status="FAILED_POST_COMMIT"
    fi
    restore_finish_result "$status" "$rollback_dir"
    exit "$exit_rc"
  fi

  if ((TRANSACTION_ACTIVE == 1)); then
    set +e
    transaction_rollback
    rollback_rc=$?
    set -e
    ((exit_rc != 0)) || exit_rc=1
  fi
  if [[ "$original_rc" == "129" || "$original_rc" == "130" || "$original_rc" == "143" ]]; then
    if ((rollback_rc == 0)); then
      status="INTERRUPTED_ROLLED_BACK"
    else
      status="INTERRUPTED_ROLLBACK_INCOMPLETE"
    fi
  elif ((rollback_rc == 0)); then
    status="FAILED_ROLLED_BACK"
  else
    status="FAILED_ROLLBACK_INCOMPLETE"
  fi
  restore_finish_result "$status" "$rollback_dir"
  exit "$exit_rc"
}

transaction_prepare() {
  local policy="${RESTORE_EXISTING:-replace}" has_data=0 existing_targets=0
  local project run name state had_old id inspect mount type source selected_path matched
  local rollback_dir rollback_base lock_base self_container_name="" quiesce_list_file
  local -a quiesce_names=()

  case "$policy" in replace | skip | fail) ;; *)
    warn "RESTORE_EXISTING 值无效：$policy（应为 replace、skip 或 fail）"
    return 1
    ;;
  esac

  rollback_base="${RESTORE_ROLLBACK_BASE:-${HOME:-${BUNDLE_DIR}}/.docker_migrate_rollback}"
  lock_base="${RESTORE_LOCK_BASE:-${HOME:-${BUNDLE_DIR}}/.docker_migrate_locks}"
  transaction_internal_paths_are_safe || return 1
  mkdir -p "$rollback_base"
  chmod 700 "$rollback_base" 2>/dev/null || true
  mkdir -p "$lock_base"
  chmod 700 "$lock_base" 2>/dev/null || true
  transaction_acquire_lock "$lock_base" || return 1
  trap restore_nontransaction_exit_handler EXIT

  if jq -e '(.volumes | length) > 0 or (.binds | length) > 0' manifest.json >/dev/null; then
    has_data=1
  fi
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    if [[ -n "$(docker ps -a --filter "label=com.docker.compose.project=${project}" \
      --format '{{.ID}}')" ]]; then
      existing_targets=$((existing_targets + 1))
    fi
  done < <(jq -r '.projects[].name' manifest.json)
  while IFS= read -r run; do
    name="$(basename "${run%.sh}")"
    transaction_container_exists "$name" && existing_targets=$((existing_targets + 1))
  done < <(jq -r '.runs[]' manifest.json)

  if [[ "$policy" == "fail" && "$existing_targets" -gt 0 ]]; then
    warn "目标端已存在待恢复服务，RESTORE_EXISTING=fail 在修改任何数据前终止。"
    transaction_release_lock
    trap restore_nontransaction_exit_handler EXIT
    return 1
  fi
  if [[ "$policy" == "skip" && "$has_data" == "1" && "$existing_targets" -gt 0 ]]; then
    warn "RESTORE_EXISTING=skip 无法安全区分共享数据归属；存在 volume/bind 时拒绝部分覆盖。"
    transaction_release_lock
    trap restore_nontransaction_exit_handler EXIT
    return 1
  fi

  if jq -e '.projects | length > 0' manifest.json >/dev/null; then
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      COMPOSE_IMPL="plugin"
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_IMPL="legacy"
    else
      warn "新机未安装 docker compose/docker-compose，恢复尚未修改目标端。"
      transaction_release_lock
      trap restore_nontransaction_exit_handler EXIT
      return 1
    fi
  fi

  RESTORE_TRANSACTION_DIR="$(mktemp -d \
    "${rollback_base}/transaction.XXXXXX")" || {
    transaction_release_lock
    trap restore_nontransaction_exit_handler EXIT
    return 1
  }
  export RESTORE_TRANSACTION_DIR
  mkdir -p "${RESTORE_TRANSACTION_DIR}/compose" \
    "${RESTORE_TRANSACTION_DIR}/file_backups" \
    "${RESTORE_TRANSACTION_DIR}/standalone_networks"
  : >"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/standalone.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/shared.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/volumes.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/binds.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/files.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/managed_names.list"
  : >"${RESTORE_TRANSACTION_DIR}/all_target_names.list"
  : >"${RESTORE_TRANSACTION_DIR}/compose_replaced.list"

  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    had_old=0
    if [[ -n "$(docker ps -a --filter "label=com.docker.compose.project=${project}" \
      --format '{{.ID}}')" ]]; then
      had_old=1
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        printf '%s\n' "$name" >>"${RESTORE_TRANSACTION_DIR}/all_target_names.list"
      done < <(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}')
      if [[ "$policy" == "skip" ]]; then
        SKIP_PROJECTS["$project"]=1
        continue
      fi
      rollback_dir="${RESTORE_TRANSACTION_DIR}/compose/${project}"
      echo " · 保存目标端旧 Compose 配置与运行状态：$project"
      if ! compose_capture_rollback_metadata "$project" "$rollback_dir"; then
        warn " · 无法安全读取 Compose 回滚元数据，目标端尚未停止：$project"
        transaction_discard_prepared
        return 1
      fi
      docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}' \
        >>"${RESTORE_TRANSACTION_DIR}/managed_names.list"
    fi
    printf '%s\t%s\n' "$project" "$had_old" >>"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  done < <(jq -r '.projects[].name' manifest.json)

  while IFS= read -r run; do
    [[ -n "$run" ]] || continue
    name="$(basename "${run%.sh}")"
    had_old=0
    state="absent"
    if transaction_container_exists "$name"; then
      had_old=1
      state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo unknown)"
      printf '%s\n' "$name" >>"${RESTORE_TRANSACTION_DIR}/all_target_names.list"
      if [[ "$policy" == "skip" ]]; then
        SKIP_CONTAINERS["$name"]=1
        continue
      fi
      printf '%s\n' "$name" >>"${RESTORE_TRANSACTION_DIR}/managed_names.list"
    fi
    printf '%s\t%s\t%s\n' "$name" "$had_old" "$state" \
      >>"${RESTORE_TRANSACTION_DIR}/standalone.tsv"
  done < <(jq -r '.runs[]' manifest.json)

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    SELECTED_TRANSACTION_VOLUMES["$name"]=1
  done < <(jq -r '.volumes[].name' manifest.json)
  mapfile -t SELECTED_TRANSACTION_BINDS < <(jq -r '.binds[].host' manifest.json)

  # restore.sh 也可在挂载 Docker socket 的工具容器中运行；绝不能把执行自身停掉。
  if docker container inspect "$(hostname)" >/dev/null 2>&1; then
    self_container_name="$(docker inspect -f '{{.Name}}' "$(hostname)" 2>/dev/null | sed 's#^/##')"
  fi

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')"
    [[ -n "$name" ]] || continue
    grep -Fxq "$name" "${RESTORE_TRANSACTION_DIR}/all_target_names.list" && continue
    inspect="$(docker inspect "$id" 2>/dev/null)" || continue
    matched=0
    while IFS= read -r mount; do
      [[ -n "$mount" ]] || continue
      type="$(jq -r '.Type // empty' <<<"$mount")"
      source="$(jq -r 'if .Type == "volume" then .Name else .Source end // empty' <<<"$mount")"
      if [[ "$type" == "volume" && -n "${SELECTED_TRANSACTION_VOLUMES[$source]:-}" ]]; then
        matched=1
        break
      fi
      if [[ "$type" == "bind" ]]; then
        for selected_path in "${SELECTED_TRANSACTION_BINDS[@]}"; do
          if transaction_mount_paths_overlap "$source" "$selected_path"; then
            matched=1
            break 2
          fi
        done
      fi
    done < <(jq -c '.[0].Mounts[]?' <<<"$inspect")
    if ((matched == 1)); then
      if [[ -n "$self_container_name" && "$name" == "$self_container_name" ]]; then
        warn " · 恢复脚本运行容器共享目标路径，保持自身运行：$name"
        continue
      fi
      case ",${RESTORE_IGNORE_CONTAINERS:-${DOCKER_MIGRATE_IGNORE_CONTAINERS:-}}," in
        *,"$name",*)
          warn " · 已显式忽略共享挂载容器：$name"
          continue
          ;;
      esac
      state="$(jq -r '.[0].State.Status // "running"' <<<"$inspect")"
      printf '%s\t%s\n' "$name" "$state" >>"${RESTORE_TRANSACTION_DIR}/shared.tsv"
    fi
  done < <(docker ps -q)

  sort -u -o "${RESTORE_TRANSACTION_DIR}/managed_names.list" \
    "${RESTORE_TRANSACTION_DIR}/managed_names.list"
  sort -u -o "${RESTORE_TRANSACTION_DIR}/shared.tsv" "${RESTORE_TRANSACTION_DIR}/shared.tsv"

  TRANSACTION_ACTIVE=1
  trap transaction_exit_handler EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  quiesce_list_file="${RESTORE_TRANSACTION_DIR}/quiesce_names.list"
  if ! transaction_build_quiesce_list \
    "${RESTORE_TRANSACTION_DIR}/shared.tsv" \
    "${RESTORE_TRANSACTION_DIR}/managed_names.list" "$quiesce_list_file"; then
    warn "无法完整生成目标端停机名单，尚未停止服务或回灌数据。"
    return 1
  fi
  mapfile -t quiesce_names <"$quiesce_list_file"
  for name in "${quiesce_names[@]}"; do
    echo " · 准备暂停目标端服务或共享写入者：$name"
  done
  transaction_quiesce_containers "${quiesce_names[@]}" || return 1

  # 所有目标服务及共享写入者停止后再提交 writable layer，使容器快照与
  # 随后建立的 volume/bind 数据回滚点处于同一个静默窗口。
  while IFS=$'\t' read -r project had_old; do
    [[ "$had_old" == "1" ]] || continue
    rollback_dir="${RESTORE_TRANSACTION_DIR}/compose/${project}"
    echo " · 保存已静默的旧 Compose 容器镜像：$project"
    compose_capture_rollback_images "$rollback_dir" || return 1
  done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
}

transaction_commit() {
  local name state shared_ok=1
  ((TRANSACTION_ACTIVE == 1)) || return 0
  if [[ -f "${RESTORE_TRANSACTION_DIR}/shared.tsv" ]]; then
    while IFS=$'\t' read -r name state; do
      [[ -n "$name" ]] || continue
      if ! transaction_restore_container_state "$name" "$state"; then
        warn " · 新服务已验证，但共享挂载容器无法恢复：$name"
        shared_ok=0
      fi
    done <"${RESTORE_TRANSACTION_DIR}/shared.tsv"
  fi
  ((shared_ok == 1)) || return 1

  # 这是不可逆提交点：新服务及数据已验证，共享写入者也已恢复。
  # EXIT handler 始终保持不变，只用这一条赋值区分“可回滚”与“已提交”；
  # 因此 INT/TERM 不会落入 trap 切换或两个状态变量之间的竞态窗口。
  RESTORE_STAGE="提交与清理回滚点"
  RESTORE_COMMIT_STARTED=1
  TRANSACTION_ACTIVE=0
  if ! dm_run_with_activity "提交事务：清理旧容器、镜像和数据回滚点" \
    transaction_cleanup_artifacts; then
    warn "服务与数据已恢复，但部分旧回滚资料清理失败：$RESTORE_TRANSACTION_DIR"
    return 1
  fi
  if ! dm_run_with_activity "提交事务：删除临时事务目录" \
    rm -rf "$RESTORE_TRANSACTION_DIR"; then
    warn "服务与数据已恢复，但事务目录清理失败：$RESTORE_TRANSACTION_DIR"
    return 1
  fi
  RESTORE_TRANSACTION_DIR=""
  export RESTORE_TRANSACTION_DIR
  transaction_release_lock
  RESTORE_STAGE="完成"
  say "所有服务与数据已通过验证，恢复事务已提交。"
}

trap restore_nontransaction_exit_handler EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RESTORE_STAGE="迁移包校验"
if [[ "${RESTORE_CHECKSUM_VERIFIED:-0}" == "1" ]]; then
  :
elif [[ -f checksums.sha256 ]]; then
  say "[0] 验证迁移包完整性"
  if ! dm_run_with_activity "校验迁移包内全部文件" restore_verify_checksums; then
    warn "迁移包完整性校验失败，拒绝恢复。"
    exit 1
  fi
else
  warn "旧版迁移包未包含校验清单，按兼容模式继续。"
fi
if ! restore_manifest_is_safe; then
  warn "迁移包 manifest 结构或路径不安全，拒绝恢复。"
  exit 1
fi
if ! transaction_internal_paths_are_safe; then
  exit 1
fi

RESTORE_STAGE="预检数据归档"
say "[0.1] 在停止目标服务前预检 volume 与 bind 归档"
if jq -e '.volumes|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r row; do
    vname="$(jq -r '.name' <<<"$row")"
    file="vol_${vname}.tgz"
    if [[ ! -f "volumes/$file" ]]; then
      warn " 命名卷缺少备份文件：$vname（volumes/$file）"
      FAILED_VOLUMES+=("$vname")
    elif ! dm_run_with_activity "预检命名卷归档：$vname" \
      archive_members_safe "volumes/$file"; then
      warn " 命名卷归档结构异常：$vname"
      FAILED_VOLUMES+=("$vname")
    fi
  done < <(jq -c '.volumes[]' manifest.json)
fi
if jq -e '.binds|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r row; do
    host="$(jq -r '.host' <<<"$row")"
    file="$(jq -r '.file' <<<"$row")"
    bind_prefix="${host#/}"
    if [[ ! -f "binds/$file" ]]; then
      warn " 绑定目录缺少备份文件：$host（binds/$file）"
      FAILED_BINDS+=("$host")
    elif ! dm_run_with_activity "预检绑定目录归档：$host" \
      archive_members_safe "binds/$file" "$bind_prefix"; then
      warn " 绑定目录归档结构异常：$host"
      FAILED_BINDS+=("$host")
    fi
  done < <(jq -c '.binds[]' manifest.json)
fi
if ((${#FAILED_VOLUMES[@]} > 0 || ${#FAILED_BINDS[@]} > 0)); then
  print_failure_summary
  exit 1
fi

RESTORE_STAGE="加载镜像"
say "[A] 加载镜像（如 images.tar 存在）"
if [[ -f images.tar ]]; then
  dm_run_with_activity "加载镜像归档 images.tar" restore_load_images images.tar || \
    warn "部分镜像加载失败，将尝试在线拉取"
else
  warn "images.tar 不存在，将按需在线拉取镜像。"
fi

RESTORE_STAGE="建立统一回滚事务"
say "[A.1] 建立目标端服务与数据统一回滚事务"
if jq -e '(.volumes | length) > 0 or (.binds | length) > 0' manifest.json >/dev/null &&
  ! docker image inspect alpine:3.20 >/dev/null 2>&1; then
  dm_run_with_activity "拉取卷操作镜像 alpine:3.20" docker pull alpine:3.20 || {
    warn "无法准备 alpine:3.20；为避免在无回滚能力时修改数据，恢复终止。"
    exit 1
  }
fi
transaction_prepare

RESTORE_STAGE="回灌命名卷"
say "[B] 回灌命名卷"
if jq -e '.volumes|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p volumes
  while IFS= read -r row; do
    vname=$(jq -r '.name' <<<"$row")
    file="vol_${vname}.tgz"
    if [[ ! -f "volumes/$file" ]]; then
      warn " 命名卷缺少备份文件：$vname（volumes/$file）"
      FAILED_VOLUMES+=("$vname")
      continue
    fi
    echo " - ${vname}"
    # 使用备份时记录的 driver 和 options 创建卷；同名卷已存在时必须先
    # 核对后端，绝不能把 NFS/plugin 数据误写进碰巧同名的 local 卷。
    v_driver=$(jq -r '.driver // "local"' <<<"$row")
    desired_volume_opts="$(jq -cS '.opts // {}' <<<"$row")"
    volume_existed=0
    if docker volume inspect "$vname" >/dev/null 2>&1; then
      volume_existed=1
      actual_volume_driver="$(docker volume inspect "$vname" | jq -r '.[0].Driver // "local"')"
      actual_volume_opts="$(docker volume inspect "$vname" | jq -cS '.[0].Options // {}')"
      if [[ "$actual_volume_driver" != "$v_driver" ||
            "$actual_volume_opts" != "$desired_volume_opts" ]]; then
        warn " 已存在同名但 driver/options 不同的卷，拒绝覆盖：$vname"
        FAILED_VOLUMES+=("$vname")
        continue
      fi
    else
      volume_create_args=(docker volume create --driver "$v_driver")
      mapfile -t volume_opts < <(jq -r '.opts // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row" 2>/dev/null || true)
      for volume_opt in "${volume_opts[@]}"; do
        volume_create_args+=(--opt "$volume_opt")
      done
      volume_create_args+=("$vname")
      if ! "${volume_create_args[@]}" >/dev/null 2>&1; then
        warn " 卷创建失败（driver=$v_driver）：$vname"
        FAILED_VOLUMES+=("$vname")
        continue
      fi
    fi
    if ! dm_run_with_activity "回灌命名卷：$vname" \
      restore_volume_exact "$vname" "$PWD/volumes" "$file" \
      "${RESTORE_TRANSACTION_DIR}/volume_data" "$volume_existed"; then
      warn " 恢复卷 ${vname} 失败，跳过"
      FAILED_VOLUMES+=("$vname")
    fi
  done < <(jq -c '.volumes[]' manifest.json)
fi

RESTORE_STAGE="回灌绑定目录"
say "[C] 回灌绑定目录"
if jq -e '.binds|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p binds
  while IFS= read -r row; do
    host=$(jq -r '.host' <<<"$row")
    file=$(jq -r '.file' <<<"$row")
    if [[ ! -f "binds/$file" ]]; then
      warn " 绑定目录缺少备份文件：$host（binds/$file）"
      FAILED_BINDS+=("$host")
      continue
    fi
    echo " - ${host}"
    if ! dm_run_with_activity "回灌绑定目录：$host" \
      restore_bind_exact "$host" "$PWD/binds/${file}"; then
      warn " 无法恢复绑定目录：$host（可能需要 root 权限）"
      FAILED_BINDS+=("$host")
    fi
  done < <(jq -c '.binds[]' manifest.json)
fi

# 数据恢复失败时禁止继续启动容器，避免 Docker 自动创建空卷/空目录。
if ((${#FAILED_VOLUMES[@]} > 0 || ${#FAILED_BINDS[@]} > 0)); then
  print_failure_summary
  exit 1
fi

RESTORE_STAGE="恢复 Compose 项目"
say "[D] 恢复 Compose 项目"
if jq -e '.projects|length>0' manifest.json >/dev/null 2>&1; then
  COMPOSE_RESTORE_ROOT="${RESTORE_TRANSACTION_DIR}/incoming_compose"
  mkdir -p "$COMPOSE_RESTORE_ROOT"
  while IFS= read -r row; do
    USE_WDIR=0
    name=$(jq -r '.name' <<<"$row")
    wdir=$(jq -r '.working_dir // ""' <<<"$row")
    echo " - project: $name"
    mkdir -p "${COMPOSE_RESTORE_ROOT}/${name}"

    if [[ -n "${SKIP_PROJECTS[$name]:-}" ]]; then
      warn " · Compose 项目已存在，按 RESTORE_EXISTING=skip 保持不变：$name"
      continue
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      compose_impl="plugin"
    elif command -v docker-compose >/dev/null 2>&1; then
      compose_impl="legacy"
    else
      warn " 新机未安装 docker compose/docker-compose，跳过该项目。"
      FAILED_PROJECTS+=("$name")
      continue
    fi
    COMPOSE_IMPL="$compose_impl"

    if [[ -d "compose/${name}" ]]; then
      cp -a "compose/${name}/." "${COMPOSE_RESTORE_ROOT}/${name}/"
    fi

    # 在第一个目标端文件或服务被改动前先写入 WAL；回滚据此判断是否需要
    # 删除本次 Compose 容器并从静默快照重建旧项目。
    printf '%s\n' "$name" >>"${RESTORE_TRANSACTION_DIR}/compose_replaced.list"

    if [[ -n "$wdir" ]]; then
      echo " · 还原 compose 配置到原路径：$wdir"
      transaction_install_tree "compose/${name}" "$wdir"
      # 如果 wdir 存在且 compose 文件已还原到 wdir，则从 wdir 执行 compose up
      # 这确保 1Panel / 宝塔等使用相对路径 bind mount 的 compose 项目能正确解析路径
      USE_WDIR=1
    fi

    # 恢复原本使用绝对路径的 env_file（普通相对路径已由递归复制保留）。
    if [[ -f "compose/${name}/.env_file_map.jsonl" ]]; then
      while IFS= read -r env_map; do
        env_source="$(jq -r '.source' <<<"$env_map")"
        env_stored="$(jq -r '.stored' <<<"$env_map")"
        [[ -n "$env_source" && -f "compose/${name}/${env_stored}" ]] || continue
        transaction_install_file "compose/${name}/${env_stored}" "$env_source"
      done < "compose/${name}/.env_file_map.jsonl"
    fi

    # 构建多文件 -f 参数：从 manifest 的 config_files 提取 basename
    # 如果没有 config_files，compose 会按默认文件名自动扫描
    declare -a COMPOSE_FILE_ARGS=()
    if jq -e '.config_files|length>0' <<<"$row" >/dev/null 2>&1; then
      while IFS= read -r cf; do
        [[ -n "$cf" ]] || continue
        local_fn="${COMPOSE_RESTORE_ROOT}/${name}/$(basename "$cf")"
        if [[ -f "$local_fn" ]]; then
          COMPOSE_FILE_ARGS+=(-f "$(basename "$cf")")
        fi
      done < <(jq -r '.config_files[]?' <<<"$row")
    fi

    if [[ "$USE_WDIR" == "1" ]]; then
      compose_dir="$wdir"
    else
      compose_dir="${COMPOSE_RESTORE_ROOT}/${name}"
    fi
    compose_rc=0
    (
      cd "$compose_dir"
      COMPOSE_IMPL="$compose_impl"
      compose_run "${COMPOSE_FILE_ARGS[@]}" config >/dev/null || exit 1
      compose_prepare_networks "$name" "${COMPOSE_FILE_ARGS[@]}" || exit 1
      declare -a source_state_records=() start_services=() pause_services=()
      mapfile -t source_state_records < <(compose_source_state_records "$name" || true)
      echo " · 已读取 ${#source_state_records[@]} 条源端服务状态"
      if ((${#source_state_records[@]} == 0)); then
        # 兼容旧迁移包：没有状态元数据时沿用全部启动行为。
        compose_run "${COMPOSE_FILE_ARGS[@]}" up -d 2>&1 || exit 1
        compose_wait_project_health "$name" "${RESTORE_HEALTH_TIMEOUT:-60}" || exit 1
      else
        compose_run "${COMPOSE_FILE_ARGS[@]}" up --no-start 2>&1 || exit 1
        for state_record in "${source_state_records[@]}"; do
          service="${state_record%%$'\t'*}"
          state="${state_record#*$'\t'}"
          case "$state" in
            running) start_services+=("$service") ;;
            paused)
              start_services+=("$service")
              pause_services+=("$service")
              ;;
          esac
        done
        if ((${#start_services[@]} > 0)); then
          compose_run "${COMPOSE_FILE_ARGS[@]}" start "${start_services[@]}" 2>&1 || exit 1
          compose_wait_services "${RESTORE_HEALTH_TIMEOUT:-60}" \
            "${COMPOSE_FILE_ARGS[@]}" -- "${start_services[@]}" || exit 1
        fi
        compose_wait_project_health "$name" "${RESTORE_HEALTH_TIMEOUT:-60}" || exit 1
        for service in "${pause_services[@]}"; do
          while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            docker pause "$id" >/dev/null || exit 1
          done < <(compose_run "${COMPOSE_FILE_ARGS[@]}" ps -q "$service")
        done
      fi
    ) || compose_rc=$?

    if ((compose_rc != 0)); then
      warn " · 新 Compose 项目启动失败：$name"
      FAILED_PROJECTS+=("$name")
      print_failure_summary
      exit 1
    fi
  done < <(jq -c '.projects[]' manifest.json)
fi

RESTORE_STAGE="创建独立容器网络"
say "[E] 创建独立容器自定义网络（非 Compose）"
declare -A COMPOSE_NETS=()
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  COMPOSE_NETS["$n"]=1
done < <(compose_networks_from_meta_all)

if jq -e '.networks|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r network_row; do
    n="$(jq -r '.name // empty' <<<"$network_row")"
    case "$n" in bridge|host|none|"") continue ;; esac
    if [[ -n "${COMPOSE_NETS[$n]:-}" ]]; then
      continue
    fi
    if ! create_network_from_record "$network_row"; then
      FAILED_NETWORKS+=("$n")
    fi
  done < <(jq -c '.networks[] | if type == "string" then
    {name: ., legacy: true, driver: "bridge", internal: false, attachable: false,
     enable_ipv6: false, options: {}, labels: {},
     ipam: {driver: "default", options: {}, config: []}}
    else . end' manifest.json)
fi

if ((${#FAILED_NETWORKS[@]} > 0)); then
  print_failure_summary
  exit 1
fi

RESTORE_STAGE="恢复独立容器"
say "[F] 恢复单容器（非 Compose）"
if jq -e '.runs|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    cname_from_script="${r#runs/}"
    cname_from_script="${cname_from_script%.sh}"
    if [[ -n "${SKIP_CONTAINERS[$cname_from_script]:-}" ]]; then
      warn " 同名单容器按 RESTORE_EXISTING=skip 保持不变：$cname_from_script"
      continue
    fi
    echo " - $r"
    if ! RESTORE_TRANSACTION_DIR="$RESTORE_TRANSACTION_DIR" bash "$r" 2>&1; then
      warn " 容器恢复脚本失败：$r"
      FAILED_CONTAINERS+=("$cname_from_script")
      print_failure_summary
      exit 1
    fi
  done < <(jq -r '.runs[]' manifest.json)
fi

if restore_has_failures; then
  print_failure_summary
  exit 1
fi

transaction_commit
REST_SH
  chmod +x "$out"
}

#####################################
# 恢复模式
#####################################
restore_prompt_url() {
  local restore_url="${1:-}"
  if [[ -z "$restore_url" ]]; then
    read -rp "请输入旧服务器的一键包下载链接： " restore_url
  fi
  if ! [[ "$restore_url" =~ ^https?://[^[:space:]]+\.tar\.gz(\.enc)?($|[?#]) ]]; then
    RED "[ERR] 链接必须是 http/https 的 .tar.gz 或 .tar.gz.enc 文件。"
    exit 1
  fi
  echo "$restore_url"
}

restore_find_bundle_dir() {
  local outdir="$1" rid="$2"
  if [[ -d "${outdir}/${rid}" && -f "${outdir}/${rid}/restore.sh" ]]; then
    echo "${outdir}/${rid}"
    return 0
  fi
  local first
  first="$(find "$outdir" -maxdepth 2 -type f -name restore.sh -print | head -n1 || true)"
  [[ -n "$first" ]] && dirname "$first"
}

restore_ensure_deps() {
  local require_openssl="${1:-0}" pm
  pm="$(pm_detect)"
  local pair bin pkg
  local -a required_pairs=("curl curl" "tar tar" "jq jq" "docker docker")
  if [[ "$require_openssl" == "1" ]]; then
    required_pairs+=("openssl openssl")
  fi
  for pair in "${required_pairs[@]}"; do
    bin="${pair%% *}"
    pkg="${pair##* }"
    if ! command -v "$bin" >/dev/null 2>&1; then
      if [[ "$pm" == "none" ]]; then
        RED "[ERR] 缺少命令：$bin，请在新服务器安装该命令后重试。"
        exit 1
      fi
      if [[ "$bin" == "docker" ]]; then
        YEL "[INFO] 安装依赖：$bin（以及 docker compose）"
        case "$pm" in
          apt) pm_install "$pm" docker.io ;;
          dnf | yum | zypper | apk) pm_install "$pm" docker ;;
          *) pm_install "$pm" docker || true ;;
        esac
        if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
          case "$pm" in
            apt) pm_install "$pm" docker-compose-plugin || pm_install "$pm" docker-compose || true ;;
            dnf | yum | zypper | apk) pm_install "$pm" docker-compose || true ;;
            *) pm_install "$pm" docker-compose || true ;;
          esac
        fi
      else
        YEL "[INFO] 安装依赖：$bin"
        pm_install "$pm" "$pkg"
      fi
    fi
  done
  ensure_docker_running
}

restore_main() {
  local URL DOWNLOAD_URL EXPECTED_SHA256 ENCRYPTION_SCHEME ENCRYPTION_SECRET
  local ENCRYPTION_IV ENCRYPTION_MAC ENCRYPTION_KEY MAC_KEY encrypted=0
  local restore_started=$SECONDS
  URL="$(restore_prompt_url "${1:-}")"
  DOWNLOAD_URL="$(bundle_download_url "$URL")"
  EXPECTED_SHA256="$(bundle_expected_sha256 "$URL")"
  ENCRYPTION_SCHEME="$(bundle_encryption_scheme "$URL")"
  ENCRYPTION_SECRET="$(bundle_encryption_secret "$URL")"
  ENCRYPTION_IV="$(bundle_encryption_iv "$URL")"
  ENCRYPTION_MAC="$(bundle_encryption_mac "$URL")"
  if [[ -n "$EXPECTED_SHA256" ]] && ! valid_sha256 "$EXPECTED_SHA256"; then
    RED "[ERR] 下载链接中的 SHA-256 摘要格式无效。"
    exit 1
  fi
  case "$ENCRYPTION_SCHEME" in
    "")
      if [[ -n "$ENCRYPTION_SECRET" || -n "$ENCRYPTION_IV" || -n "$ENCRYPTION_MAC" ||
        "$DOWNLOAD_URL" == *.enc ]]; then
        RED "[ERR] 加密链接缺少完整的 enc/secret/iv/mac 参数。"
        exit 1
      fi
      ;;
    "$BUNDLE_ENCRYPTION_SCHEME")
      encrypted=1
      if ! valid_hex_length "$ENCRYPTION_SECRET" 128 ||
        ! valid_hex_length "$ENCRYPTION_IV" 32 ||
        ! valid_hex_length "$ENCRYPTION_MAC" 64 ||
        [[ -z "$EXPECTED_SHA256" ]]; then
        RED "[ERR] 加密链接中的密钥、IV、HMAC 或 SHA-256 参数无效。"
        exit 1
      fi
      ;;
    *)
      RED "[ERR] 不支持的迁移包加密格式：$ENCRYPTION_SCHEME"
      exit 1
      ;;
  esac
  if [[ -z "$EXPECTED_SHA256" && "${RESTORE_ALLOW_UNVERIFIED:-0}" != "1" ]]; then
    if [[ -t 0 ]]; then
      YEL "[WARN] 链接没有外部 SHA-256 摘要，无法确认迁移包来源。"
      local allow_unverified
      read -rp "仍要恢复这个旧版链接吗？[y/N] " allow_unverified
      [[ "$allow_unverified" =~ ^[Yy]$ ]] || exit 1
    else
      RED "[ERR] 链接缺少外部 SHA-256 摘要；非交互模式拒绝恢复。"
      YEL "[INFO] 仅兼容可信旧包时可显式设置 RESTORE_ALLOW_UNVERIFIED=1。"
      exit 1
    fi
  fi
  restore_ensure_deps "$encrypted"
  local BASE="${RESTORE_BASE:-$HOME/docker_migrate_restore}"
  mkdir -p "$BASE"
  local SESSION_DIR
  SESSION_DIR="$(mktemp -d "${BASE}/restore.XXXXXX")" || {
    RED "[ERR] 无法创建独立恢复工作目录：$BASE"
    exit 1
  }
  local RID
  RID="$(basename "$DOWNLOAD_URL" | sed 's/\.tar\.gz.*$//' | tr -dc 'A-Za-z0-9_-')"
  [[ -n "$RID" ]] || RID="$(date +%s)"
  local TGZ="${SESSION_DIR}/bundle.tar.gz"
  local ENCRYPTED_BUNDLE="${SESSION_DIR}/bundle.tar.gz.enc"
  local DOWNLOAD_FILE="$TGZ"
  if ((encrypted == 1)); then
    DOWNLOAD_FILE="$ENCRYPTED_BUNDLE"
  fi
  local OUTDIR="${SESSION_DIR}/unpacked"

  BLUE "[INFO] 下载：$DOWNLOAD_URL"
  if ! curl -fL --progress-bar --retry 5 --retry-delay 10 --retry-max-time 300 \
    --connect-timeout 30 --output "$DOWNLOAD_FILE" --url "$DOWNLOAD_URL"; then
    RED "[ERR] 下载失败：$DOWNLOAD_URL"
    exit 1
  fi
  OK "[OK] 保存路径：$DOWNLOAD_FILE"
  BLUE "[INFO] 文件大小：$(du -h "$DOWNLOAD_FILE" | awk '{print $1}')"
  if ((encrypted == 1)); then
    ENCRYPTION_KEY="$(bundle_secret_encryption_key "$ENCRYPTION_SECRET")"
    MAC_KEY="$(bundle_secret_mac_key "$ENCRYPTION_SECRET")"
    if ! run_with_activity "验证加密迁移包完整性" verify_bundle_digests \
      "$ENCRYPTED_BUNDLE" "$MAC_KEY" "$ENCRYPTION_IV" \
      "$EXPECTED_SHA256" "$ENCRYPTION_MAC"; then
      RED "[ERR] 加密迁移包摘要或认证失败，文件可能被篡改或链接密钥不正确。"
      exit 1
    fi
    OK "[OK] 加密迁移包来源摘要与认证均通过"
    if ! run_with_file_progress "解密迁移包" "${TGZ}.partial.$$" \
      "$(progress_file_size "$ENCRYPTED_BUNDLE")" bundle_decrypt_file \
      "$ENCRYPTED_BUNDLE" "$TGZ" "$ENCRYPTION_KEY" "$ENCRYPTION_IV"; then
      rm -f "$TGZ"
      RED "[ERR] 迁移包解密失败。"
      exit 1
    fi
    ENCRYPTION_SECRET=""
    ENCRYPTION_KEY=""
    MAC_KEY=""
    OK "[OK] 迁移包解密完成"
  elif [[ -n "$EXPECTED_SHA256" ]]; then
    if ! run_with_activity "校验下载包 SHA-256" \
      verify_archive_sha256 "$DOWNLOAD_FILE" "$EXPECTED_SHA256"; then
      RED "[ERR] 下载包与源服务器提供的 SHA-256 摘要不一致，拒绝解压。"
      exit 1
    fi
    OK "[OK] 下载包来源摘要校验通过"
  else
    YEL "[WARN] 已按兼容模式跳过外部来源校验。"
  fi
  if ! run_with_activity "扫描迁移包目录结构" archive_layout_is_safe "$TGZ"; then
    RED "[ERR] 迁移包结构不安全或已损坏，拒绝解压。"
    exit 1
  fi
  mkdir -p "$OUTDIR"
  if ! run_with_activity "解压迁移包" tar -xzf "$TGZ" -C "$OUTDIR"; then
    RED "[ERR] 解压失败，请检查磁盘空间或确认文件是否完整。"
    exit 1
  fi
  if ((encrypted == 1)) && [[ "${RESTORE_KEEP:-0}" != "1" ]]; then
    rm -f "$TGZ"
  fi

  local BUNDLE_DIR
  BUNDLE_DIR="$(restore_find_bundle_dir "$OUTDIR" "$RID" || true)"
  if [[ -z "$BUNDLE_DIR" || ! -f "${BUNDLE_DIR}/restore.sh" ]]; then
    RED "[ERR] 未找到 restore.sh，解压内容异常：$OUTDIR"
    exit 1
  fi
  if [[ -f "${BUNDLE_DIR}/checksums.sha256" ]]; then
    if ! run_with_activity "校验迁移包内全部文件" \
      verify_bundle_checksums "$BUNDLE_DIR"; then
      RED "[ERR] 完整性校验未通过，拒绝恢复。"
      exit 1
    fi
    OK "[OK] 迁移包完整性校验通过"
  else
    YEL "[WARN] 这是未带校验清单的旧版迁移包，将按兼容模式继续。"
  fi
  if ! bundle_manifest_is_safe "$BUNDLE_DIR"; then
    RED "[ERR] manifest.json 结构或路径不安全，拒绝恢复。"
    exit 1
  fi

  # 使用当前脚本内置的修复版 restore.sh 覆盖包内旧 restore.sh。
  write_bundle_restore_script "${BUNDLE_DIR}/restore.sh"

  local rc result_file="${SESSION_DIR}/restore-result.json" result_status result_stage rollback_dir
  local metrics total running paused stopped missing volumes binds
  local container_line="" data_line="" cleanup_line="" diagnostic_dir="" elapsed
  set +e
  RESTORE_CHECKSUM_VERIFIED=1 RESTORE_SESSION_DIR="$SESSION_DIR" \
    RESTORE_RESULT_FILE="$result_file" RESTORE_DEFER_FINAL_SUMMARY=1 \
    bash "${BUNDLE_DIR}/restore.sh"
  rc=$?
  set -e

  result_status=""
  result_stage="执行恢复脚本"
  rollback_dir=""
  if [[ -s "$result_file" ]]; then
    result_status="$(jq -r '.status // empty' "$result_file" 2>/dev/null || true)"
    result_stage="$(jq -r '.stage // "执行恢复脚本"' "$result_file" 2>/dev/null || true)"
    rollback_dir="$(jq -r '.rollback_dir // empty' "$result_file" 2>/dev/null || true)"
  fi
  if [[ -z "$result_status" ]]; then
    if ((rc == 0)); then
      result_status="SUCCESS"
    elif [[ "$rc" == "129" || "$rc" == "130" || "$rc" == "143" ]]; then
      result_status="INTERRUPTED"
    else
      result_status="FAILED"
    fi
  fi

  if [[ "$result_status" == "SUCCESS" ]]; then
    metrics="$(collect_restore_result_metrics "$BUNDLE_DIR")"
    IFS=$'\t' read -r total running paused stopped missing volumes binds <<<"$metrics"
    container_line="容器：${total} 个（运行 ${running} / 暂停 ${paused} / 停止 ${stopped}"
    ((missing == 0)) || container_line+=" / 缺失 ${missing}"
    container_line+="）"
    data_line="数据：${volumes} 个 volume、${binds} 个 bind 目录"
    if [[ "${RESTORE_KEEP:-0}" == "1" ]]; then
      cleanup_line="恢复文件已按 RESTORE_KEEP=1 保留：$SESSION_DIR"
    else
      if run_with_activity "清理恢复临时文件" rm -rf "$SESSION_DIR"; then
        cleanup_line="下载文件与临时目录已删除"
      else
        cleanup_line="恢复成功，但部分下载文件或临时目录未能删除，请人工检查"
        diagnostic_dir="$SESSION_DIR"
      fi
    fi
  else
    if [[ "${RESTORE_CLEAN_ALL:-0}" == "1" ]]; then
      if run_with_activity "清理恢复临时文件" rm -rf "$SESSION_DIR"; then
        cleanup_line="已按 RESTORE_CLEAN_ALL=1 删除下载文件与临时目录"
      else
        cleanup_line="RESTORE_CLEAN_ALL=1 清理未完成，请人工检查"
        diagnostic_dir="$SESSION_DIR"
      fi
    else
      cleanup_line="恢复文件已保留，便于排查"
      diagnostic_dir="$SESSION_DIR"
    fi
  fi

  elapsed="$(format_elapsed "$((SECONDS - restore_started))")"
  print_restore_result_summary "$result_status" "$result_stage" "$container_line" "$data_line" \
    "$cleanup_line" "$diagnostic_dir" "$rollback_dir" "$elapsed"
  exit "$rc"
}

if [[ "${DOCKER_MIGRATE_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

#####################################
# 模式选择：1) 备份并传输 2) 下载并恢复
#####################################
REQUESTED_MODE=""
RESTORE_URL=""
declare -a ORIGINAL_ARGS=("$@")
for ((arg_i = 0; arg_i < ${#ORIGINAL_ARGS[@]}; arg_i++)); do
  case "${ORIGINAL_ARGS[$arg_i]}" in
    -h | --help)
      show_help
      exit 0
      ;;
    --backup) REQUESTED_MODE=1 ;;
    --restore=*)
      REQUESTED_MODE=2
      RESTORE_URL="${ORIGINAL_ARGS[$arg_i]#*=}"
      ;;
    --restore)
      REQUESTED_MODE=2
      if ((arg_i + 1 < ${#ORIGINAL_ARGS[@]})) &&
        [[ "${ORIGINAL_ARGS[$((arg_i + 1))]}" != --* ]]; then
        RESTORE_URL="${ORIGINAL_ARGS[$((arg_i + 1))]}"
      fi
      ;;
  esac
done

if [[ -n "$REQUESTED_MODE" ]]; then
  MODE_PICK="$REQUESTED_MODE"
elif [[ -t 0 ]]; then
  show_banner
  echo "请选择功能："
  echo " 1) 备份容器并传输"
  echo " 2) 下载备份并恢复"
  read -rp "请输入序号 [回车=1]：" MODE_PICK || true
  MODE_PICK="${MODE_PICK:-1}"
else
  MODE_PICK=1
fi

case "$MODE_PICK" in
  1) : ;;
  2)
    restore_main "$RESTORE_URL"
    exit 0
    ;;
  *)
    RED "[ERR] 无效选择：${MODE_PICK}"
    exit 1
    ;;
esac

#####################################
# 依赖检测 / 安装
#####################################
PKGMGR="$(pm_detect)"

case "$PKGMGR" in
  apt)
    need_bin curl curl
    need_bin jq jq
    try_optional_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    try_optional_bin pigz pigz
    need_bin openssl openssl
    need_bin docker docker.io
    ;;
  yum | dnf)
    need_bin curl curl
    need_bin jq jq
    try_optional_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    try_optional_bin pigz pigz
    need_bin openssl openssl
    if ! command -v docker >/dev/null 2>&1; then
      pm_install "$PKGMGR" docker || pm_install "$PKGMGR" docker-ce || true
    fi
    ;;
  zypper)
    need_bin curl curl
    need_bin jq jq
    try_optional_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    try_optional_bin pigz pigz
    need_bin openssl openssl
    need_bin docker docker
    ;;
  apk)
    need_bin curl curl
    need_bin jq jq
    try_optional_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    try_optional_bin pigz pigz
    need_bin openssl openssl
    need_bin docker docker
    ;;
  none)
    for required_bin in curl jq tar gzip openssl docker; do
      if ! command -v "$required_bin" >/dev/null 2>&1; then
        RED "[ERR] 缺少命令：$required_bin，且未检测到受支持的包管理器，请手动安装。"
        exit 1
      fi
    done
    ;;
esac
ensure_docker_running

#####################################
# 参数解析
#####################################
NO_STOP=0
INCLUDE_LIST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) shift ;;
    --no-stop)
      NO_STOP=1
      shift
      ;;
    --include=*)
      INCLUDE_LIST="${1#*=}"
      shift
      ;;
    --include)
      shift
      INCLUDE_LIST="${1:-}"
      [[ $# -gt 0 ]] && shift || true
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *)
      RED "[ERR] 未知参数：$1"
      exit 1
      ;;
  esac
done

#####################################
# Bundle 路径与 ID
#####################################
DEFAULT_PORT="${PORT:-8080}"
PORT="$(pick_free_port "$DEFAULT_PORT")"
WORKDIR="$(pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
RID="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 10)"
BUNDLE_ROOT="${WORKDIR}/bundle"
BUNDLE="${BUNDLE_ROOT}/${RID}"
mkdir -p "${BUNDLE}"/{runs,volumes,binds,compose,meta,networks}
BLUE "[INFO] Bundle 目录：${BUNDLE}"

#####################################
# 并发锁：防止同机同时运行两个实例互相干扰
#####################################
LOCK_BASE="${DOCKER_MIGRATE_LOCK_BASE:-${HOME:-${WORKDIR}}/.docker_migrate_locks}"
mkdir -p "$LOCK_BASE"
chmod 700 "$LOCK_BASE" 2>/dev/null || true
LOCKFILE="${LOCK_BASE}/migration.lock"
LOCK_METHOD="mkdir"
LOCKDIR="${LOCKFILE}.d"
if command -v flock >/dev/null 2>&1; then
  LOCK_METHOD="flock"
  exec 200>"$LOCKFILE"
  if ! flock -n 200 2>/dev/null; then
    RED "[ERR] 检测到另一个 docker_migrate 实例正在运行。"
    exit 1
  fi
elif ! mkdir "$LOCKDIR" 2>/dev/null; then
  RED "[ERR] 检测到另一个 docker_migrate 实例正在运行。"
  RED "[ERR] 若确认没有实例运行，可删除：$LOCKDIR"
  exit 1
fi

SHPID=""
CLEANUP_DONE=0
SOURCE_TASK_STARTED_AT=$SECONDS
SOURCE_PACKAGE_READY=0
SOURCE_TRANSFER_PUBLISHED=0
SOURCE_RESTORE_EXPECTED=0
SOURCE_RESTORED_COUNT=0
HTTP_WAS_STARTED=0
HTTP_EXIT_UNEXPECTED=0
HTTP_DIAGNOSTICS_SHOWN=0
HTTP_CLEANUP_STATUS="未启动"
CLEANUP_STATUS="未执行"

cleanup_http() {
  if ((HTTP_WAS_STARTED == 0)); then
    HTTP_CLEANUP_STATUS="未启动"
    return 0
  fi
  if ((HTTP_EXIT_UNEXPECTED == 1)); then
    SHPID=""
    HTTP_CLEANUP_STATUS="异常退出"
    return 1
  fi
  if [[ -n "${SHPID:-}" ]] && kill -0 "${SHPID}" 2>/dev/null; then
    if ! kill "${SHPID}" 2>/dev/null; then
      if kill -0 "${SHPID}" 2>/dev/null; then
        HTTP_EXIT_UNEXPECTED=1
        HTTP_CLEANUP_STATUS="未能停止，请人工检查进程 ${SHPID}"
        return 1
      fi
    else
      wait "${SHPID}" 2>/dev/null || true
    fi
  fi
  SHPID=""
  HTTP_CLEANUP_STATUS="已停止"
}

hard_clean() {
  local preserve_http_log="${1:-0}" failed=0
  cleanup_snapshot_images || failed=1
  [[ -z "${BUNDLE:-}" ]] || rm -rf "${BUNDLE}" 2>/dev/null || failed=1
  [[ -z "${SINGLE_TAR_PATH:-}" ]] || rm -f "${SINGLE_TAR_PATH}" 2>/dev/null || failed=1
  [[ -z "${ENCRYPTED_TAR_PATH:-}" ]] || rm -f "${ENCRYPTED_TAR_PATH}" 2>/dev/null || failed=1
  [[ -z "${ENCRYPTED_PARTIAL_PATH:-}" ]] || rm -f "${ENCRYPTED_PARTIAL_PATH}" 2>/dev/null || failed=1
  [[ -z "${BUNDLE_ROOT:-}" ]] || rm -rf "${BUNDLE_ROOT}/_bb_http_serve" 2>/dev/null || failed=1
  [[ -z "${BUNDLE_ROOT:-}" ]] || rm -f "${BUNDLE_ROOT}/nc_http_response.http" 2>/dev/null || failed=1
  if [[ "$preserve_http_log" != "1" && -n "${HTTP_LOG:-}" ]]; then
    rm -f "$HTTP_LOG" 2>/dev/null || failed=1
  fi
  if ((failed == 0)); then
    CLEANUP_STATUS="临时迁移文件已删除"
  else
    CLEANUP_STATUS="部分临时文件未能删除，请人工检查"
  fi
  return "$failed"
}

restart_source_containers() {
  if ((${#STOPPED_ON_BACKUP[@]} == 0)); then
    return 0
  fi
  local observed_total attempted
  attempted=${#STOPPED_ON_BACKUP[@]}
  observed_total=$((SOURCE_RESTORED_COUNT + attempted))
  if ((observed_total > SOURCE_RESTORE_EXPECTED)); then
    SOURCE_RESTORE_EXPECTED=$observed_total
  fi
  BLUE "[INFO] 恢复源服务器容器原始运行状态（共 ${#STOPPED_ON_BACKUP[@]} 个）..."
  local ok=0 fail=0 record n original_state current_state restore_ok
  local -a remaining=()
  for record in "${STOPPED_ON_BACKUP[@]}"; do
    IFS=$'\t' read -r n original_state <<<"$record"
    printf " [恢复源状态] %s (%s)\n" "$n" "$original_state"
    current_state="$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo missing)"
    restore_ok=1
    case "$original_state" in
      paused)
        if [[ "$current_state" != "paused" ]]; then
          case "$current_state" in
            running | restarting) ;;
            *)
              run_with_activity "启动源容器：$n" \
                run_with_timeout 60 docker start "$n" >/dev/null || restore_ok=0
              ;;
          esac
          ((restore_ok == 0)) || docker pause "$n" >/dev/null 2>&1 || restore_ok=0
        fi
        ;;
      *)
        case "$current_state" in
          running | restarting) ;;
          paused) docker unpause "$n" >/dev/null 2>&1 || restore_ok=0 ;;
          *)
            run_with_activity "启动源容器：$n" \
              run_with_timeout 60 docker start "$n" >/dev/null || restore_ok=0
            ;;
        esac
        ;;
    esac
    if ((restore_ok == 1)); then
      printf " [恢复源状态] %s：ok\n" "$n"
      ok=$((ok + 1))
    else
      printf " [恢复源状态] %s：fail\n" "$n"
      fail=$((fail + 1))
      remaining+=("$record")
    fi
  done
  STOPPED_ON_BACKUP=("${remaining[@]}")
  SOURCE_RESTORED_COUNT=$((SOURCE_RESTORE_EXPECTED - ${#STOPPED_ON_BACKUP[@]}))
  if ((fail > 0)); then
    RED "[ERR] 有 ${fail} 个源容器未能重启，请立即人工检查。"
    return 1
  fi
  OK "[OK] 源容器已恢复：${ok}/${attempted}"
}

graceful_exit() {
  local rc="${1:-0}" initial_rc status package_line source_line elapsed final_rc
  ((CLEANUP_DONE == 0)) || return "$rc"
  initial_rc="$rc"
  CLEANUP_DONE=1
  trap - EXIT INT TERM HUP
  if ! cleanup_http; then
    print_http_diagnostics_once "${HTTP_LOG:-}"
    ((rc != 0)) || rc=1
  fi
  if ! restart_source_containers; then
    ((rc != 0)) || rc=1
  fi
  # 由仍待恢复的 write-ahead 记录推导结果，避免信号落在两次账本赋值之间
  # 时出现重复计数或明明已恢复却少计数。
  SOURCE_RESTORED_COUNT=$((SOURCE_RESTORE_EXPECTED - ${#STOPPED_ON_BACKUP[@]}))
  if ! run_with_activity "清理源端临时文件与快照" hard_clean "$HTTP_EXIT_UNEXPECTED"; then
    ((rc != 0)) || rc=1
  fi
  if [[ "$LOCK_METHOD" == "flock" ]]; then
    flock -u 200 2>/dev/null || true
  else
    rmdir "$LOCKDIR" 2>/dev/null || true
  fi

  if ((SOURCE_TRANSFER_PUBLISHED == 1)); then
    package_line="已生成、完成加密并提供下载"
  elif ((SOURCE_PACKAGE_READY == 1)); then
    package_line="已生成并完成加密，但未成功发布下载"
  else
    package_line="未完成"
  fi
  if ((SOURCE_RESTORE_EXPECTED == 0)); then
    source_line="无需恢复（本次未改变源容器状态）"
  elif ((SOURCE_RESTORED_COUNT == SOURCE_RESTORE_EXPECTED)); then
    source_line="已恢复 ${SOURCE_RESTORED_COUNT}/${SOURCE_RESTORE_EXPECTED}"
  else
    source_line="恢复不完整 ${SOURCE_RESTORED_COUNT}/${SOURCE_RESTORE_EXPECTED}，请立即人工检查"
  fi
  final_rc="$rc"
  if ((rc == 0)) || {
    [[ "$initial_rc" == "129" || "$initial_rc" == "130" || "$initial_rc" == "143" ]] &&
      ((SOURCE_TRANSFER_PUBLISHED == 1)) &&
      ((SOURCE_RESTORED_COUNT == SOURCE_RESTORE_EXPECTED)) &&
      [[ "$HTTP_CLEANUP_STATUS" == "已停止" ]] &&
      [[ "$CLEANUP_STATUS" == "临时迁移文件已删除" ]]
  }; then
    status="SUCCESS"
    final_rc=0
  elif [[ "$initial_rc" == "129" || "$initial_rc" == "130" || "$initial_rc" == "143" ]]; then
    status="INTERRUPTED"
  else
    status="FAILED"
  fi
  elapsed="$(format_elapsed "$((SECONDS - SOURCE_TASK_STARTED_AT))")"
  print_source_result_summary "$status" "$package_line" "$HTTP_CLEANUP_STATUS" \
    "$source_line" "$CLEANUP_STATUS" "$elapsed"
  exit "$final_rc"
}

# 从获得锁开始，任何正常退出、错误或信号都会恢复源容器并清理临时包。
trap 'graceful_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

#####################################
# 容器选择（支持 compose 分组）
#####################################
if [[ -n "$INCLUDE_LIST" ]]; then
  declare -A INCLUDE_ID_BY_NAME=()
  include_container_count=0
  while IFS=$'\t' read -r id n; do
    [[ -n "$id" && -n "$n" ]] || continue
    INCLUDE_ID_BY_NAME["$n"]="$id"
    include_container_count=$((include_container_count + 1))
  done < <(docker ps -a --format '{{.ID}}\t{{.Names}}')
  ((include_container_count > 0)) || {
    RED "[ERR] 没有任何容器（运行中或已停止）"
    exit 1
  }
  IFS=',' read -r -a NAMES <<<"$INCLUDE_LIST"
  for n in "${NAMES[@]}"; do
    n="$(echo "$n" | xargs)"
    [[ -z "$n" ]] && continue
    # 一次性建立精确 name -> ID 索引，避免每个 --include 名称都重新扫描 Docker。
    id="${INCLUDE_ID_BY_NAME[$n]:-}"
    if [[ -n "$id" ]]; then
      IDS+=("$id")
    else
      YEL "[WARN] 未找到容器：$n"
    fi
  done
  ((${#IDS[@]})) || {
    RED "[ERR] --include 未匹配到任何容器"
    exit 1
  }
else
  mapfile -t PS_LINES < <(docker ps -a --format '{{.ID}} {{.Names}}')
  ((${#PS_LINES[@]})) || {
    RED "[ERR] 没有任何容器（运行中或已停止）"
    exit 1
  }

  declare -a STANDALONE_IDS=()
  declare -a STANDALONE_NAMES=()
  declare -A NAME_OF_ID=()
  declare -A GROUP_IDS=()
  declare -A GROUP_LABELS=()
  declare -A GROUP_SEEN=()
  declare -a GROUP_KEYS=()
  declare -a PANEL_CONTAINERS=()
  declare -A PANEL_WARN_OF=()

  scan_total=${#PS_LINES[@]}
  scan_index=0
  BLUE "[INFO] 正在识别容器与 Compose 分组（共 ${scan_total} 个）..."
  for line in "${PS_LINES[@]}"; do
    scan_index=$((scan_index + 1))
    id="${line%% *}"
    cname="${line#* }"
    [[ -z "$cname" || "$cname" == "$id" ]] && cname="$id"
    progress_count "识别容器分组" "$scan_index" "$scan_total" "$cname"
    NAME_OF_ID["$id"]="$cname"

    j="$(docker inspect "$id")"
    proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
    wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")

    # 面板管理容器检测：btpanel/baota/1Panel 自身 — 标记警告
    panel_warn=""
    img_name="$(jq -r '.[0].Config.Image // ""' <<<"$j")"
    case "$img_name" in
      *btpanel* | *baota* | *1panel* | *1Panel*)
        PANEL_CONTAINERS+=("$id")
        panel_warn=" [⚡ 面板管理容器，迁移可能导致管理界面异常]"
        ;;
    esac
    # 检测挂载了面板关键路径的容器
    mounts_json="$(jq -r '.[0].Mounts[]?.Source // empty' <<<"$j" 2>/dev/null || true)"
    case "$mounts_json" in
      *"/www/server/panel/"* | *"/opt/1panel/"*)
        if [[ -z "$panel_warn" ]]; then
          PANEL_CONTAINERS+=("$id")
          panel_warn=" [⚡ 挂载了面板关键路径，请确认是否为管理容器]"
        fi
        ;;
    esac
    PANEL_WARN_OF["$id"]="$panel_warn"
    # 兼容 docker-compose v1（无 working_dir label）：将 v1 的 project 容器也归入 compose 组。
    # v1 缺少 working_dir 时，使用 compose config_files 中第一个文件的父目录作为 wdir。
    if [[ -z "$wdir" && -n "$proj" ]]; then
      cfgs_raw=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$j")
      if [[ -n "$cfgs_raw" ]]; then
        IFS=':' read -r -a cfgs_arr <<<"$cfgs_raw"
        for cfg in "${cfgs_arr[@]}"; do
          cfg="${cfg#./}"
          if [[ -n "$cfg" ]]; then
            d="$(dirname "$cfg")"
            if [[ "$cfg" == /* ]]; then wdir="$d"; else wdir="${PWD}/${d}"; fi
            break
          fi
        done
      fi
    fi
    if [[ -n "$proj" && -n "$wdir" ]]; then
      key="${proj}|${wdir}"
      if [[ -z "${GROUP_SEEN[$key]:-}" ]]; then
        GROUP_SEEN["$key"]=1
        GROUP_IDS["$key"]="$id"
        GROUP_LABELS["$key"]="$cname"
        GROUP_KEYS+=("$key")
      else
        GROUP_IDS["$key"]="${GROUP_IDS[$key]} $id"
        GROUP_LABELS["$key"]="${GROUP_LABELS[$key]} $cname"
      fi
    else
      STANDALONE_IDS+=("$id")
      STANDALONE_NAMES+=("$cname")
    fi
  done

  # 关键修复：只有一个容器的 compose 项目归类为“独立容器”。
  # 这样 danmu_api 这类单容器项目会走 docker run 恢复路径，从 inspect 还原 -p 端口。
  if ((${#GROUP_KEYS[@]})); then
    declare -a TRUE_GROUP_KEYS=()
    for key in "${GROUP_KEYS[@]}"; do
      cnt=0
      for cid in ${GROUP_IDS[$key]}; do cnt=$((cnt + 1)); done
      if ((cnt > 1)); then
        TRUE_GROUP_KEYS+=("$key")
      else
        for cid in ${GROUP_IDS[$key]}; do
          STANDALONE_IDS+=("$cid")
          STANDALONE_NAMES+=("${NAME_OF_ID[$cid]}")
        done
      fi
    done
    GROUP_KEYS=("${TRUE_GROUP_KEYS[@]}")
  fi

  declare -a MENU_KIND=()
  declare -a MENU_VAL=()
  idx=0
  if ((${#STANDALONE_IDS[@]})); then
    BLUE "独立 docker 容器："
    for i in "${!STANDALONE_IDS[@]}"; do
      idx=$((idx + 1))
      id="${STANDALONE_IDS[$i]}"
      name="${STANDALONE_NAMES[$i]}"
      pw="${PANEL_WARN_OF[$id]:-}"
      printf " %2d) %s%s\n" "$idx" "$name" "$pw"
      MENU_KIND[$idx]="single"
      MENU_VAL[$idx]="$id"
    done
    echo ""
  fi

  if ((${#PANEL_CONTAINERS[@]})); then
    YEL " ⚡ 提示：检测到面板管理容器（btpanel/1Panel/baota），迁移可能导致面板界面异常。"
    YEL "    建议仅迁移业务容器，排除面板管理容器。"
    echo ""
  fi

  if ((${#GROUP_KEYS[@]})); then
    BLUE "docker compose 容器组："
    for key in "${GROUP_KEYS[@]}"; do
      idx=$((idx + 1))
      label_display=""
      for cname in ${GROUP_LABELS[$key]}; do label_display+="〖${cname}〗"; done
      printf " %2d) %s\n" "$idx" "$label_display"
      MENU_KIND[$idx]="compose"
      MENU_VAL[$idx]="$key"
    done
    echo ""
  fi

  if ((idx == 0)); then
    RED "[ERR] 没有运行中的容器"
    exit 1
  fi

  read -rp "请输入要迁移的序号 [回车=全部 / 逗号分隔，如 1,3]： " PICK
  if [[ -z "$PICK" ]]; then
    IDS=("${STANDALONE_IDS[@]}")
    for key in "${GROUP_KEYS[@]}"; do
      for cid in ${GROUP_IDS[$key]}; do IDS+=("$cid"); done
    done
  else
    IFS=',' read -r -a INDEX_LIST <<<"$PICK"
    declare -A SEEN_ID=()
    for t in "${INDEX_LIST[@]}"; do
      t="$(echo "$t" | xargs)"
      [[ -z "$t" ]] && continue
      if ! [[ "$t" =~ ^[0-9]+$ ]]; then
        YEL "[WARN] 非法序号：$t"
        continue
      fi
      num="$t"
      if ((num < 1 || num > idx)); then
        YEL "[WARN] 序号越界：$t"
        continue
      fi
      kind="${MENU_KIND[$num]}"
      val="${MENU_VAL[$num]}"
      if [[ "$kind" == "single" ]]; then
        cid="$val"
        if [[ -z "${SEEN_ID[$cid]:-}" ]]; then
          SEEN_ID["$cid"]=1
          IDS+=("$cid")
        fi
      elif [[ "$kind" == "compose" ]]; then
        for cid in ${GROUP_IDS[$val]}; do
          if [[ -z "${SEEN_ID[$cid]:-}" ]]; then
            SEEN_ID["$cid"]=1
            IDS+=("$cid")
          fi
        done
      fi
    done
    ((${#IDS[@]})) || {
      RED "[ERR] 未选择任何容器"
      exit 1
    }
  fi
fi

#####################################
# 元数据采集
#####################################
BLUE "[INFO] 采集容器元数据 ..."
declare -A IMGSET=()
declare -A NETWORKS=()
declare -A CONTAINER_NAME=()
declare -A CONTAINER_IS_COMPOSE=()
declare -A COMPOSE_GROUP=()
declare -A COMPOSE_CFGS=()
declare -A SELECTED_COMPOSE_COUNT=()
declare -A COMPOSE_SERVICE_COUNT=()
declare -A SELECTED_INSPECT_JSON=()

# 关键修复：重新按最终选择的容器统计 compose 分组数量，避免菜单阶段归类为单容器，元数据阶段又被重新归为 compose。
metadata_total=${#IDS[@]}
metadata_index=0
for id in "${IDS[@]}"; do
  metadata_index=$((metadata_index + 1))
  progress_count "分析所选容器" "$metadata_index" "$metadata_total" "$id"
  jtmp="$(docker inspect "$id")"
  SELECTED_INSPECT_JSON["$id"]="$jtmp"
  projtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$jtmp")
  wdirtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$jtmp")
  # 兼容 v1：缺少 working_dir 时从 config_files 推断
  if [[ -z "$wdirtmp" && -n "$projtmp" ]]; then
    cfgstmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$jtmp")
    if [[ -n "$cfgstmp" ]]; then
      IFS=':' read -r -a cfgs_tmp <<<"$cfgstmp"
      for ct in "${cfgs_tmp[@]}"; do
        ct="${ct#./}"
        if [[ -n "$ct" ]]; then
          if [[ "$ct" == /* ]]; then wdirtmp="$(dirname "$ct")"; else wdirtmp="${PWD}/$(dirname "$ct")"; fi
          break
        fi
      done
    fi
  fi
  if [[ -n "$projtmp" && -n "$wdirtmp" ]]; then
    keytmp="${projtmp}|${wdirtmp}"
    SELECTED_COMPOSE_COUNT["$keytmp"]=$((${SELECTED_COMPOSE_COUNT["$keytmp"]:-0} + 1))
  fi
done

metadata_index=0
for id in "${IDS[@]}"; do
  metadata_index=$((metadata_index + 1))
  j="${SELECTED_INSPECT_JSON[$id]}"
  name=$(jq -r '.[0].Name | ltrimstr("/")' <<<"$j")
  progress_count "采集容器元数据" "$metadata_index" "$metadata_total" "$name"
  img=$(jq -r '.[0].Config.Image' <<<"$j")
  CONTAINER_NAME["$id"]="$name"
  IMGSET["$img"]=1

  proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
  wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")
  cfgs=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$j")
  # 兼容 v1：缺少 working_dir 时从 config_files 推断
  if [[ -z "$wdir" && -n "$proj" ]]; then
    if [[ -n "$cfgs" ]]; then
      IFS=':' read -r -a cfgs_arr <<<"$cfgs"
      for cg in "${cfgs_arr[@]}"; do
        cg="${cg#./}"
        if [[ -n "$cg" ]]; then
          if [[ "$cg" == /* ]]; then wdir="$(dirname "$cg")"; else wdir="${PWD}/$(dirname "$cg")"; fi
          break
        fi
      done
    fi
  fi
  key=""
  if [[ -n "$proj" && -n "$wdir" ]]; then
    key="${proj}|${wdir}"
  fi

  if [[ -n "$key" && "${SELECTED_COMPOSE_COUNT[$key]:-0}" -gt 1 ]]; then
    COMPOSE_GROUP["$key"]=1
    [[ -n "$cfgs" ]] && COMPOSE_CFGS["$key"]="$cfgs"
    CONTAINER_IS_COMPOSE["$id"]=1
    compose_service="$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // empty' <<<"$j")"
    if [[ -n "$compose_service" ]]; then
      service_key="${key}|${compose_service}"
      COMPOSE_SERVICE_COUNT["$service_key"]=$((${COMPOSE_SERVICE_COUNT["$service_key"]:-0} + 1))
    else
      BACKUP_FAILURES+=("Compose 容器缺少 service 标签：$name")
    fi
  else
    CONTAINER_IS_COMPOSE["$id"]=0
  fi

  # 所有选中容器的非内置网络都要保存。多服务 Compose 的 external 网络
  # 也依赖这里的完整 driver/IPAM/options，不能只采集独立容器网络。
  mapfile -t nets < <(jq -r '.[0].NetworkSettings.Networks | keys[]?' <<<"$j" || true)
  for n in "${nets[@]}"; do
    case "$n" in bridge | host | none) : ;; *) NETWORKS["$n"]=1 ;; esac
  done

  echo "$j" >"${BUNDLE}/meta/${name}.inspect.json"
done

# 保存选中容器使用的自定义网络定义，而不只保存网络名称。
for network_name in "${!NETWORKS[@]}"; do
  network_id="$(printf '%s' "$network_name" | cksum | awk '{print $1}')"
  if ! docker network inspect "$network_name" | jq '.[0] | {
      name: .Name,
      driver: (.Driver // "bridge"),
      internal: (.Internal // false),
      attachable: (.Attachable // false),
      enable_ipv6: (.EnableIPv6 // false),
      options: (.Options // {}),
      labels: (.Labels // {}),
      ipam: {
        driver: (.IPAM.Driver // "default"),
        options: (.IPAM.Options // {}),
        config: (.IPAM.Config // [])
      }
    }' >"${BUNDLE}/networks/${network_id}.json"; then
    BACKUP_FAILURES+=("网络元数据采集失败：$network_name")
  fi
done

#####################################
# 打包 Compose 配置（绝对/相对路径）
#####################################
if ((${#COMPOSE_GROUP[@]})); then
  BLUE "[INFO] 打包 docker compose 项目配置 ..."
  compose_total=${#COMPOSE_GROUP[@]}
  compose_index=0
  for key in "${!COMPOSE_GROUP[@]}"; do
    compose_index=$((compose_index + 1))
    proj="${key%%|*}"
    wdir="${key#*|}"
    progress_count "采集 Compose 配置" "$compose_index" "$compose_total" "$proj"
    dest="${BUNDLE}/compose/${proj}"
    mkdir -p "$dest"
    cfgs="${COMPOSE_CFGS[$key]:-}"
    declare -a CFG_SOURCE_ARGS=()

    if [[ -n "$cfgs" ]]; then
      IFS=':' read -r -a CFG_ARR <<<"$cfgs"
      for cfg in "${CFG_ARR[@]}"; do
        cfg="${cfg#./}"
        [[ -z "$cfg" ]] && continue
        src=""
        if [[ "$cfg" == /* ]]; then
          src="$cfg"
        elif [[ -n "$wdir" ]]; then
          src="${wdir}/${cfg}"
        else
          src="$cfg"
        fi
        if [[ -f "$src" ]]; then
          cp -a "$src" "$dest/"
          CFG_SOURCE_ARGS+=(-f "$src")
        else
          BACKUP_FAILURES+=("Compose 配置文件缺失：$src")
        fi
      done
    fi

    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env docker-compose.override.yml compose.override.yaml; do
      if [[ -n "$wdir" && -f "${wdir}/${f}" ]]; then
        cp -a "${wdir}/${f}" "$dest/" 2>/dev/null || true
      fi
    done

    # 使用全部 -f 文件生成规范配置，合并覆盖文件并解析 env_file。
    if ((${#CFG_SOURCE_ARGS[@]} > 0)); then
      resolved_tmp="${dest}/.resolved_config.yml.tmp"
      BLUE "[INFO] 解析 Compose 配置：$proj"
      if docker compose version >/dev/null 2>&1 &&
        { docker compose --project-directory "$wdir" "${CFG_SOURCE_ARGS[@]}" config --no-path-resolution >"$resolved_tmp" 2>/dev/null ||
          docker compose --project-directory "$wdir" "${CFG_SOURCE_ARGS[@]}" config >"$resolved_tmp" 2>/dev/null; }; then
        mv "$resolved_tmp" "${dest}/_resolved_config.yml"
      elif command -v docker-compose >/dev/null 2>&1 &&
        (cd "$wdir" && docker-compose "${CFG_SOURCE_ARGS[@]}" config) >"$resolved_tmp" 2>/dev/null; then
        mv "$resolved_tmp" "${dest}/_resolved_config.yml"
      else
        rm -f "$resolved_tmp"
        YEL "[WARN] 无法生成解析后的 Compose 配置，将使用原始配置文件。"
      fi
    fi

    # 原始配置回退：收集常见 env_file 语法并保留相对目录结构。
    for cfg in "$dest"/*.yml "$dest"/*.yaml; do
      [[ -f "$cfg" ]] || continue
      while IFS= read -r ef; do
        ef="${ef#./}"
        [[ -z "$ef" ]] && continue
        if [[ "$ef" == /* ]]; then
          if [[ -f "$ef" ]]; then
            env_id="$(printf '%s' "$ef" | cksum | awk '{print $1}')"
            stored="_env_files/${env_id}_$(basename "$ef")"
            mkdir -p "${dest}/$(dirname "$stored")"
            cp -a "$ef" "${dest}/${stored}"
            jq -cn --arg source "$ef" --arg stored "$stored" \
              '{source:$source,stored:$stored}' >>"${dest}/.env_file_map.jsonl"
          fi
        elif [[ -n "$wdir" && -f "${wdir}/${ef}" ]]; then
          mkdir -p "${dest}/$(dirname "$ef")"
          cp -a "${wdir}/${ef}" "${dest}/${ef}"
        fi
      done < <(compose_env_file_refs "$cfg" || true)
    done
  done
fi

#####################################
# 预拉取卷操作镜像，避免把下载时间计入后面的停机快照窗口
#####################################
BLUE "[INFO] 预拉取 alpine:3.20 镜像（用于卷操作）..."
if docker image inspect alpine:3.20 >/dev/null 2>&1; then
  OK "[OK] 已存在 alpine:3.20，跳过联网检查"
else
  run_with_activity "拉取卷操作镜像 alpine:3.20" docker pull alpine:3.20 ||
    YEL "[WARN] 无法拉取 alpine:3.20，卷操作可能失败"
fi

#####################################
# 检查未选中容器是否仍在写共享挂载
#####################################
declare -a SHARED_MOUNT_ROWS=()
mapfile -t SHARED_MOUNT_ROWS < <(
  run_with_activity "检查未选中容器的共享挂载写入" \
    collect_shared_running_containers "${IDS[@]}"
)
if ((${#SHARED_MOUNT_ROWS[@]} > 0)); then
  YEL "[WARN] 检测到未选中的运行容器正在使用相同 volume 或重叠 bind 路径："
  for shared_row in "${SHARED_MOUNT_ROWS[@]}"; do
    IFS=$'\t' read -r _ shared_name shared_reason <<<"$shared_row"
    YEL " - ${shared_name} (${shared_reason})"
  done

  if ((NO_STOP == 1)); then
    RED "[ERR] --no-stop 无法保证共享挂载一致性，已取消备份。"
    RED "[INFO] 请停止这些容器，或去掉 --no-stop 让脚本临时暂停并自动恢复。"
    exit 1
  fi

  stop_shared=0
  if [[ -t 0 ]]; then
    read -rp "是否临时停止这些共享挂载容器？备份结束会自动重启。[Y/n] " STOP_SHARED
    STOP_SHARED=${STOP_SHARED:-Y}
    [[ "$STOP_SHARED" =~ ^[Yy]$ ]] && stop_shared=1
  elif [[ "${STOP_SHARED_MOUNTS:-0}" == "1" ]]; then
    stop_shared=1
  fi
  if ((stop_shared == 0)); then
    RED "[ERR] 未获得停止共享挂载容器的许可，已取消备份以避免不一致数据。"
    RED "[INFO] 非交互模式可显式设置 STOP_SHARED_MOUNTS=1。"
    exit 1
  fi

  declare -a SHARED_STOP_NAMES=()
  for shared_row in "${SHARED_MOUNT_ROWS[@]}"; do
    IFS=$'\t' read -r _ shared_name _ <<<"$shared_row"
    shared_state="$(docker inspect -f '{{.State.Status}}' "$shared_name" 2>/dev/null || echo running)"
    printf "[停机-共享挂载] %s\n" "$shared_name"
    # Write-ahead：在 unpause/stop 前登记原状态；信号可在任意指令后安全恢复。
    STOPPED_ON_BACKUP+=("${shared_name}"$'\t'"${shared_state}")
    [[ "$shared_state" != "paused" ]] || docker unpause "$shared_name" >/dev/null 2>&1 || true
    SHARED_STOP_NAMES+=("$shared_name")
  done
  if ! docker_stop_batch_verified \
    "批量停止共享挂载容器（${#SHARED_STOP_NAMES[@]} 个）" "${SHARED_STOP_NAMES[@]}"; then
    BACKUP_FAILURES+=("共享挂载容器未能全部停止")
  fi
  if ((${#BACKUP_FAILURES[@]} > 0)); then
    RED "[ERR] 共享挂载容器未全部停止，已取消备份。"
    exit 1
  fi
fi

#####################################
# 停机窗口（可选）
#####################################
if ((NO_STOP == 1)); then
  YEL "[WARN] 使用 --no-stop：不停机备份，数据可能不一致（尤其数据库类容器）。"
else
  read -rp "是否现在停机以确保一致性备份？[Y/n] " STOPNOW
  STOPNOW=${STOPNOW:-Y}
  if [[ "$STOPNOW" =~ ^[Yy]$ ]]; then
    total_count=${#IDS[@]}
    idx=0
    declare -a SOURCE_STOP_NAMES=()
    for id in "${IDS[@]}"; do
      idx=$((idx + 1))
      n="${CONTAINER_NAME[$id]}"
      source_state_row="$(docker inspect -f '{{.State.Running}} {{.State.Status}}' \
        "$id" 2>/dev/null || echo 'false missing')"
      read -r was_running source_state <<<"$source_state_row"
      if [[ "$was_running" != "true" ]]; then
        printf "[停机] (%d/%d) %s ... already stopped\n" "$idx" "$total_count" "$n"
        continue
      fi
      printf "[停机] (%d/%d) %s\n" "$idx" "$total_count" "$n"
      # Write-ahead：先登记再改变源容器状态，避免 TERM 落在 stop 与数组追加之间。
      STOPPED_ON_BACKUP+=("${n}"$'\t'"${source_state}")
      [[ "$source_state" != "paused" ]] || docker unpause "$n" >/dev/null 2>&1 || true
      SOURCE_STOP_NAMES+=("$n")
    done
    if ! docker_stop_batch_verified \
      "批量停止源容器（${#SOURCE_STOP_NAMES[@]} 个）" "${SOURCE_STOP_NAMES[@]}"; then
      BACKUP_FAILURES+=("源容器未能全部停止")
    fi
    if ((${#BACKUP_FAILURES[@]} > 0)); then
      RED "[ERR] 停机阶段失败，已取消备份以避免不一致数据。"
      exit 1
    fi
  else
    YEL "[WARN] 你选择了不停机备份。"
  fi
fi

#####################################
# 捕获容器 writable layer
#####################################
BLUE "[INFO] 捕获容器可写层快照 ..."
for service_key in "${!COMPOSE_SERVICE_COUNT[@]}"; do
  if ((${COMPOSE_SERVICE_COUNT[$service_key]} > 1)); then
    BACKUP_FAILURES+=("Compose 服务存在多个副本，无法逐容器保留可写层：${service_key##*|}")
  fi
done
if ((${#BACKUP_FAILURES[@]} > 0)); then
  RED "[ERR] 可写层快照预检查失败："
  for failure in "${BACKUP_FAILURES[@]}"; do RED " - $failure"; done
  exit 1
fi

# 后续只需保存临时快照镜像；其父镜像层会由 docker image save 自动包含。
IMGSET=()
snapshot_total=${#IDS[@]}
snapshot_index=0
for id in "${IDS[@]}"; do
  snapshot_index=$((snapshot_index + 1))
  n="${CONTAINER_NAME[$id]}"
  snapshot_image="$(snapshot_image_ref "$RID" "$id")"
  printf " [SNAPSHOT] (%d/%d) %s\n" "$snapshot_index" "$snapshot_total" "$n"
  if ! run_with_activity "创建容器可写层快照：$n" \
    snapshot_container_image "$id" "${BUNDLE}/meta/${n}.inspect.json" "$snapshot_image"; then
    BACKUP_FAILURES+=("容器可写层快照失败：$n")
    continue
  fi
  IMGSET["$snapshot_image"]=1

  if [[ "${CONTAINER_IS_COMPOSE[$id]}" == "1" ]]; then
    j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")"
    compose_service="$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // empty' <<<"$j")"
    if ! write_compose_snapshot_override \
      "${BUNDLE}/compose/${proj}/_migration_images.yml" "$compose_service" "$snapshot_image"; then
      YEL " [WARN] Compose 快照覆盖配置生成失败：$n"
      BACKUP_FAILURES+=("Compose 快照覆盖配置生成失败：$n")
      continue
    fi
  fi
done
if ((${#BACKUP_FAILURES[@]} > 0)); then
  RED "[ERR] 可写层快照不完整，已取消备份。"
  exit 1
fi

#####################################
# 备份卷与绑定目录
#####################################
BLUE "[INFO] 备份卷与绑定目录 ..."
declare -a MAN_VOL=()
declare -a MAN_BIND=()
declare -A BACKED_VOLUMES=()
declare -A BACKED_BINDS=()
vol_count=0
bind_count=0
for id in "${IDS[@]}"; do
  n="${CONTAINER_NAME[$id]}"
  j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
  vc=$(jq -r '.[0].Mounts[]? | select(.Type=="volume") | 1' <<<"$j" | wc -l || echo 0)
  bc=$(jq -r '.[0].Mounts[]? | select(.Type=="bind") | 1' <<<"$j" | wc -l || echo 0)
  vol_count=$((vol_count + vc))
  bind_count=$((bind_count + bc))
done

v_idx=0
b_idx=0
for id in "${IDS[@]}"; do
  n="${CONTAINER_NAME[$id]}"
  j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    t=$(jq -r '.Type' <<<"$m")
    dest=$(jq -r '.Destination' <<<"$m")
    case "$t" in
      volume)
        v_idx=$((v_idx + 1))
        vname=$(jq -r '.Name' <<<"$m")
        [[ -z "${BACKED_VOLUMES[$vname]:-}" ]] || continue
        BACKED_VOLUMES["$vname"]=1
        # 捕获卷的 driver 和 options，用于恢复时精确还原
        if v_inspect="$(docker volume inspect "$vname" 2>/dev/null)"; then
          v_driver="$(jq -r '.[0].Driver // "local"' <<<"$v_inspect")"
          v_opts_json="$(jq -c '.[0].Options // {}' <<<"$v_inspect")"
        else
          v_driver="local"
          v_opts_json='{}'
        fi
        printf " [VOL] (%d/%d) %s :: %s -> %s\n" "$v_idx" "$vol_count" "$n" "$vname" "$dest"
        mkdir -p "${BUNDLE}/volumes"
        out="${BUNDLE}/volumes/vol_${vname}.tgz"
        if ! run_with_file_progress "打包命名卷：$vname" "$out" 0 \
          archive_volume_to_gzip "$vname" "$out"; then
          YEL " [WARN] 打包卷失败：$vname"
          BACKUP_FAILURES+=("命名卷备份失败：$vname")
          continue
        fi
        MAN_VOL+=("$(jq -cn --arg name "$vname" --arg dest "$dest" --arg driver "$v_driver" --argjson opts "$v_opts_json" '{name:$name,dest:$dest,driver:$driver,opts:$opts}')")
        ;;
      bind)
        src=$(jq -r '.Source' <<<"$m")
        # 过滤 Docker socket 等 Unix socket 文件，防止恢复时覆盖目标服务器 daemon
        case "$src" in
          */docker.sock | */podman.sock | */containerd.sock)
            YEL " [SKIP] 跳过 Docker socket bind mount：$src"
            continue
            ;;
        esac
        b_idx=$((b_idx + 1))
        [[ -z "${BACKED_BINDS[$src]:-}" ]] || continue
        BACKED_BINDS["$src"]=1
        esc="$(basename "$src" | tr -c 'A-Za-z0-9_.-' '_')"
        src_id="$(printf '%s' "$src" | cksum | awk '{print $1}')"
        out="${BUNDLE}/binds/bind_${esc}_${src_id}.tgz"
        printf " [BIND] (%d/%d) %s :: %s -> %s\n" "$b_idx" "$bind_count" "$n" "$src" "$dest"
        mkdir -p "${BUNDLE}/binds"
        if ! run_with_file_progress "打包绑定目录：$src" "$out" 0 \
          archive_bind_to_gzip "$src" "$out"; then
          YEL " [WARN] 跳过不可读路径：$src"
          BACKUP_FAILURES+=("绑定目录备份失败：$src")
          continue
        fi
        MAN_BIND+=("$(jq -cn --arg host "$src" --arg dest "$dest" --arg file "$(basename "$out")" '{host:$host,dest:$dest,file:$file}')")
        ;;
      *)
        YEL " [SKIP] 未处理的 mount 类型：$t (dest=$dest)"
        ;;
    esac
  done < <(jq -c '.[0].Mounts[]?' <<<"$j")
done

if ((${#BACKUP_FAILURES[@]} > 0)); then
  RED "[ERR] 数据备份不完整，已取消生成迁移包："
  for failure in "${BACKUP_FAILURES[@]}"; do
    RED " - $failure"
  done
  exit 1
fi

# 容器可写层、volume 与 bind 数据现在都已经真正归档为同一停机快照；后续
# 镜像保存、压缩、加密和下载不再需要业务保持停止，立即恢复源端状态。
SOURCE_RESTORE_EXPECTED=${#STOPPED_ON_BACKUP[@]}
if ((SOURCE_RESTORE_EXPECTED > 0)); then
  BLUE "[INFO] 数据快照已完成，立即恢复源服务器容器状态 ..."
  if ! restart_source_containers; then
    RED "[ERR] 源容器未能全部恢复，已停止后续打包，请立即人工检查。"
    exit 1
  fi
fi

#####################################
# 生成独立容器 run 脚本
#####################################
if ((${#IDS[@]})); then
  BLUE "[INFO] 生成独立容器 run 脚本 ..."
  for id in "${IDS[@]}"; do
    if [[ "${CONTAINER_IS_COMPOSE[$id]}" == "1" ]]; then
      continue
    fi
    n="${CONTAINER_NAME[$id]}"
    run_file="${BUNDLE}/runs/${n}.sh"
    write_run_script "$n" "$run_file"
    RUNS+=("runs/$(basename "$run_file")")
  done
fi

#####################################
# 保存镜像 images.tar
#####################################
mapfile -t IMAGES < <(printf "%s\n" "${!IMGSET[@]}" | awk 'NF' | sort -u)
if ((${#IMAGES[@]})); then
  OUT_IMG="${BUNDLE}/images.tar"
  if progress_docker_save "${OUT_IMG}" docker image save "${IMAGES[@]}"; then
    OK "[OK] images.tar 已生成，大小：$(du -h "${OUT_IMG}" | awk '{print $1}')"
    if ! cleanup_snapshot_images; then
      YEL "[WARN] 部分临时 snapshot image 暂未删除，退出清理时会自动重试。"
    fi
  else
    RED "[ERR] docker image save 失败，请检查磁盘空间或 Docker 状态。"
    rm -f "${OUT_IMG}" 2>/dev/null || true
    BACKUP_FAILURES+=("镜像归档失败")
  fi
else
  YEL "[WARN] 未收集到镜像名（可能是只用了本地 none 镜像）。"
fi

if ((${#BACKUP_FAILURES[@]} > 0)); then
  RED "[ERR] 备份未完成，不会生成可误用的迁移包。"
  exit 1
fi

#####################################
# 生成 manifest.json 与 restore.sh
#####################################
generate_manifest_and_restore() {
  declare -a MAN_PROJECTS=()
  local key
  for key in "${!COMPOSE_GROUP[@]}"; do
    local proj="${key%%|*}"
    local wdir="${key#*|}"
    local files_json="[]"
    local cfgs_json="[]"
    if [[ -d "${BUNDLE}/compose/${proj}" ]]; then
      mapfile -t FLS < <(find "${BUNDLE}/compose/${proj}" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | sort || true)
      if ((${#FLS[@]})); then
        files_json="$(json_array_from_lines "${FLS[@]}")"
      fi
    fi
    # 解析后的单文件配置优先；否则保持原始 config_files 顺序。
    local cfs="${COMPOSE_CFGS[$key]:-}"
    if [[ -f "${BUNDLE}/compose/${proj}/_resolved_config.yml" ]]; then
      if [[ -f "${BUNDLE}/compose/${proj}/_migration_images.yml" ]]; then
        cfgs_json='["_resolved_config.yml","_migration_images.yml"]'
      else
        cfgs_json='["_resolved_config.yml"]'
      fi
    elif [[ -n "$cfs" ]]; then
      IFS=':' read -r -a CFS_ARR <<<"$cfs"
      declare -a cfgs_abs
      cfgs_abs=()
      for c in "${CFS_ARR[@]}"; do
        c="${c#./}"
        [[ -z "$c" ]] && continue
        if [[ "$c" == /* ]]; then cfgs_abs+=("$c"); elif [[ -n "$wdir" ]]; then cfgs_abs+=("${wdir}/${c}"); else cfgs_abs+=("$c"); fi
      done
      if ((${#cfgs_abs[@]})); then
        if [[ -f "${BUNDLE}/compose/${proj}/_migration_images.yml" ]]; then
          cfgs_abs+=("_migration_images.yml")
        fi
        cfgs_json="$(json_array_from_lines "${cfgs_abs[@]}")"
      fi
    fi
    MAN_PROJECTS+=("$(jq -cn --arg name "$proj" --arg working_dir "$wdir" --argjson files "$files_json" --argjson config_files "$cfgs_json" '{name:$name,working_dir:$working_dir,files:$files,config_files:$config_files}')")
  done

  local images_json nets_json projects_json vols_json binds_json runs_json
  # 使用正确的 bash 数组展开语法，避免空数组产生空字符串参数
  images_json="$(json_array_from_lines ${IMAGES[@]+"${IMAGES[@]}"})"
  runs_json="$(json_array_from_lines ${RUNS[@]+"${RUNS[@]}"})"
  mapfile -t NETWORK_FILES < <(find "${BUNDLE}/networks" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort || true)
  if ((${#NETWORK_FILES[@]})); then
    nets_json="$(jq -s . "${NETWORK_FILES[@]}")"
  else
    nets_json='[]'
  fi

  if ((${#MAN_PROJECTS[@]})); then
    projects_json="$(printf '%s\n' "${MAN_PROJECTS[@]}" | jq -cs .)"
  else
    projects_json='[]'
  fi
  if ((${#MAN_VOL[@]})); then
    vols_json="$(printf '%s\n' "${MAN_VOL[@]}" | jq -cs .)"
  else
    vols_json='[]'
  fi
  if ((${#MAN_BIND[@]})); then
    binds_json="$(printf '%s\n' "${MAN_BIND[@]}" | jq -cs .)"
  else
    binds_json='[]'
  fi

  jq -n \
    --arg created_at "$STAMP" \
    --arg script_version "$SCRIPT_VERSION" \
    --argjson images "$images_json" \
    --argjson networks "$nets_json" \
    --argjson projects "$projects_json" \
    --argjson volumes "$vols_json" \
    --argjson binds "$binds_json" \
    --argjson runs "$runs_json" \
    '{created_at:$created_at,script_version:$script_version,images:$images,networks:$networks,projects:$projects,volumes:$volumes,binds:$binds,runs:$runs}' \
    >"${BUNDLE}/manifest.json"

  write_bundle_restore_script "${BUNDLE}/restore.sh"

  cat >"${BUNDLE}/README.txt" <<README
Docker 迁移包
生成时间：${STAMP}

恢复方法：
1. 新服务器运行同一份 docker_migrate_perfect.sh，选择 2，然后粘贴下载链接；或
2. 手动解压本包后，在包目录执行：bash restore.sh

本版修复端口丢失问题：
- 单容器 compose 项目会以独立容器方式迁移。
- 已存在同名容器但端口绑定不一致时，恢复脚本会删除并重建容器。
README
}

generate_manifest_and_restore
run_with_activity "计算迁移包内文件校验值" generate_bundle_checksums "$BUNDLE"

#####################################
# 流式压缩并加密成单文件
#####################################
BUNDLE_BASENAME="docker_migrate_${STAMP}_${RID}"
SINGLE_TAR_PATH="${BUNDLE_ROOT}/${BUNDLE_BASENAME}.tar.gz"
BUNDLE_SECRET="$(openssl rand -hex 64)" || {
  RED "[ERR] 无法生成迁移包加密密钥。"
  exit 1
}
BUNDLE_IV="$(openssl rand -hex 16)" || {
  RED "[ERR] 无法生成迁移包加密 IV。"
  exit 1
}
valid_hex_length "$BUNDLE_SECRET" 128 && valid_hex_length "$BUNDLE_IV" 32 || {
  RED "[ERR] OpenSSL 返回了无效的随机密钥材料。"
  exit 1
}
BUNDLE_ENCRYPTION_KEY="$(bundle_secret_encryption_key "$BUNDLE_SECRET")"
BUNDLE_MAC_KEY="$(bundle_secret_mac_key "$BUNDLE_SECRET")"
ENCRYPTED_TAR_PATH="${SINGLE_TAR_PATH}.enc"
ENCRYPTED_PARTIAL_PATH="${ENCRYPTED_TAR_PATH}.partial.$$"
if ! BUNDLE_DIGESTS="$(run_with_file_progress "压缩并加密迁移包" \
  "$ENCRYPTED_PARTIAL_PATH" 0 bundle_pack_encrypt_directory \
  "$BUNDLE_ROOT" "$RID" "$ENCRYPTED_PARTIAL_PATH" \
  "$BUNDLE_ENCRYPTION_KEY" "$BUNDLE_MAC_KEY" "$BUNDLE_IV")"; then
  RED "[ERR] 迁移包压缩或加密失败，拒绝启动下载服务。"
  exit 1
fi
IFS=$'\t' read -r BUNDLE_SHA256 BUNDLE_HMAC BUNDLE_DIGEST_EXTRA <<<"$BUNDLE_DIGESTS"
if [[ -n "$BUNDLE_DIGEST_EXTRA" ]] || ! valid_sha256 "$BUNDLE_SHA256" ||
  ! valid_sha256 "$BUNDLE_HMAC"; then
  RED "[ERR] 无法生成加密迁移包摘要。"
  exit 1
fi
if ! mv "$ENCRYPTED_PARTIAL_PATH" "$ENCRYPTED_TAR_PATH"; then
  RED "[ERR] 无法提交已完成的加密迁移包。"
  exit 1
fi
TRANSFER_NAME="${BUNDLE_BASENAME}.tar.gz.enc"
TRANSFER_PATH="$ENCRYPTED_TAR_PATH"
TRANSFER_FRAGMENT="#sha256=${BUNDLE_SHA256}&enc=${BUNDLE_ENCRYPTION_SCHEME}&secret=${BUNDLE_SECRET}&iv=${BUNDLE_IV}&mac=${BUNDLE_HMAC}"
BUNDLE_ENCRYPTION_KEY=""
BUNDLE_MAC_KEY=""
BUNDLE_SECRET=""
OK "[OK] 加密迁移包已生成，大小：$(du -h "$TRANSFER_PATH" | awk '{print $1}')"
SOURCE_PACKAGE_READY=1

#####################################
# HTTP 下载服务
#####################################
if [[ -t 0 ]]; then
  echo ""
  read -rp "HTTP 下载端口 [回车=${PORT}]： " IN_PORT || true
  if [[ -n "${IN_PORT:-}" ]]; then
    if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && ((IN_PORT >= 1 && IN_PORT <= 65535)); then
      NEW_PORT="$(pick_free_port "$IN_PORT")"
      if [[ "$NEW_PORT" != "$IN_PORT" ]]; then
        YEL "[WARN] 端口 ${IN_PORT} 已占用，改用临近可用端口：${NEW_PORT}"
      fi
      PORT="$NEW_PORT"
    else
      YEL "[WARN] 输入端口无效，继续使用默认端口：${PORT}"
    fi
  fi
fi

SECRET_TOKEN="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
BASE_URL="$(pick_advertise_url "$PORT")"
FINAL_URL="" # will be set below by the chosen HTTP server

SHPID=""

HTTP_LOG="${BUNDLE_ROOT}/http_server_${RID}.log"
: >"$HTTP_LOG"
cd "${BUNDLE_ROOT}" || exit 1

# start_http_server: multi-fallback — python3 > busybox httpd > netcat
TRANSFER_SIZE="$(stat -c%s "$TRANSFER_PATH" 2>/dev/null || stat -f%z "$TRANSFER_PATH" 2>/dev/null || echo 0)"

if command -v python3 >/dev/null 2>&1; then
  # --- Fallback 1: Python3 HTTP server (best — supports secret token + proper headers) ---
  http_log_event "启动 backend=python3 port=${PORT} file=${TRANSFER_NAME} size=${TRANSFER_SIZE}"
  python3 - "$PORT" "$SECRET_TOKEN" "$TRANSFER_NAME" >>"${HTTP_LOG}" 2>&1 <<'PY' &
import http.server
import os
from socketserver import ThreadingTCPServer
import sys

port = int(sys.argv[1])
secret = sys.argv[2]
fname = sys.argv[3]
allowed_path = "/" + secret + "/" + fname
root = os.getcwd()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        if path != allowed_path:
            self.send_response(404)
            self.end_headers()
            return
        fpath = os.path.join(root, fname)
        try:
            st = os.stat(fpath)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(st.st_size))
        self.send_header("Content-Disposition", 'attachment; filename="' + fname + '"')
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        with open(fpath, "rb") as f:
            while True:
                chunk = f.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def log_message(self, format, *args):
        message = format % args
        message = message.replace(secret, "<token>")
        sys.stderr.write(
            "%s client=%s %s\n"
            % (self.log_date_time_string(), self.client_address[0], message)
        )
        sys.stderr.flush()

from socketserver import ThreadingTCPServer

with ThreadingTCPServer(("", port), Handler) as httpd:
    httpd.serve_forever()
PY
  SHPID=$!
  FINAL_URL="${BASE_URL}/${SECRET_TOKEN}/${TRANSFER_NAME}${TRANSFER_FRAGMENT}"

elif command -v busybox >/dev/null 2>&1; then
  # --- Fallback 2: Busybox httpd (widespread on minimal/embedded systems) ---
  # 通过子目录隔离：创建一个符号链接，只暴露 tar.gz 文件而不暴露整个 bundle_root
  http_log_event "启动 backend=busybox-httpd port=${PORT} file=${TRANSFER_NAME} size=${TRANSFER_SIZE}"
  BUSYBOX_WEB="${BUNDLE_ROOT}/_bb_http_serve"
  mkdir -p "$BUSYBOX_WEB/$SECRET_TOKEN"
  printf 'Not found\n' >"$BUSYBOX_WEB/index.html"
  ln -sf "$TRANSFER_PATH" "$BUSYBOX_WEB/$SECRET_TOKEN/$TRANSFER_NAME"
  busybox httpd -f -p "$PORT" -h "$BUSYBOX_WEB" >>"${HTTP_LOG}" 2>&1 &
  SHPID=$!
  FINAL_URL="${BASE_URL}/${SECRET_TOKEN}/${TRANSFER_NAME}${TRANSFER_FRAGMENT}"

elif command -v nc >/dev/null 2>&1; then
  # --- Fallback 3: Netcat one-shot HTTP (virtually universal) ---
  http_log_event "启动 backend=netcat port=${PORT} file=${TRANSFER_NAME} size=${TRANSFER_SIZE}"
  # Build a raw HTTP response; serve the same file for any path
  cat >"${BUNDLE_ROOT}/nc_http_response.http" <<NCEOF
HTTP/1.1 200 OK
Content-Type: application/octet-stream
Content-Length: ${TRANSFER_SIZE}
Content-Disposition: attachment; filename="${TRANSFER_NAME}"
Cache-Control: no-store
X-Content-Type-Options: nosniff
Connection: close

NCEOF
  # 兼容常见 nc/ncat/BSD 参数；若全部不支持必须退出，让启动检查报告失败，
  # 不能留下一个空转但永远无法下载的后台进程。
  netcat_http_serve "$PORT" "${BUNDLE_ROOT}/nc_http_response.http" \
    "$TRANSFER_PATH" >>"${HTTP_LOG}" 2>&1 &
  SHPID=$!
  # nc fallback: no secret token — URL is just http://host:port/<file>
  FINAL_URL="${BASE_URL}/${TRANSFER_NAME}${TRANSFER_FRAGMENT}"

else
  RED "[ERR] 未找到可用的 HTTP 服务方式（python3 / busybox httpd / nc），请手动安装其一后重试。"
  exit 1
fi
HTTP_WAS_STARTED=1

cd "$WORKDIR"
sleep 1

if ! kill -0 "$SHPID" 2>/dev/null; then
  HTTP_EXIT_UNEXPECTED=1
  RED "[ERR] HTTP 服务启动失败，请检查端口 ${PORT} 或防火墙设置。"
  print_http_diagnostics_once "$HTTP_LOG"
  graceful_exit 1
fi
SOURCE_TRANSFER_PUBLISHED=1

if [[ -t 0 ]]; then
  print_transfer_instructions "$FINAL_URL" interactive
  while kill -0 "$SHPID" 2>/dev/null; do
    if read -r -t 1 _; then
      graceful_exit 0
    fi
  done
  http_wait_rc=0
  wait "$SHPID" || http_wait_rc=$?
  HTTP_EXIT_UNEXPECTED=1
  SHPID=""
  RED "[ERR] HTTP 服务在用户确认退出前意外停止（rc=${http_wait_rc}）。"
  print_http_diagnostics_once "$HTTP_LOG"
  graceful_exit 1
else
  print_transfer_instructions "$FINAL_URL" noninteractive "$$"
  http_wait_rc=0
  wait "$SHPID" || http_wait_rc=$?
  HTTP_EXIT_UNEXPECTED=1
  SHPID=""
  RED "[ERR] HTTP 服务在收到停止指令前意外退出（rc=${http_wait_rc}）。"
  print_http_diagnostics_once "$HTTP_LOG"
  graceful_exit 1
fi
