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
# 源码：本文件由 build.sh 从 src/ 目录合并生成，修改请改 src/ 下的源码后重新运行 ./build.sh。
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

SCRIPT_VERSION="2.5.1"
BUNDLE_ENCRYPTION_SCHEME="aes-256-ctr-hmac-sha256-v1"
declare -a IDS=()
declare -a RUNS=()
declare -a STOPPED_ON_BACKUP=()
declare -a BACKUP_FAILURES=()
declare -a TEMP_IMAGES=()

# 彩色输出：主脚本与生成的恢复脚本共用。
BLUE() { echo -e "\033[1;34m$*\033[0m"; }
YEL() { echo -e "\033[1;33m$*\033[0m"; }
RED() { echo -e "\033[1;31m$*\033[0m"; }
OK() { echo -e "\033[1;32m$*\033[0m"; }

# 通用工具：主脚本与生成的恢复脚本共用。

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

# 运行日志：主脚本与生成的恢复脚本共用。
#
# 屏幕只显示阶段、进度、警告和最终结果；每一步的细节、执行的命令及其完整
# 输出都写进日志文件。成功后日志自动删除，失败时保留并在结果中给出路径，
# 方便用户反馈。子脚本（restore.sh、单容器恢复脚本）通过环境变量沿用父进程
# 的日志文件，由创建日志的进程负责收尾。
#
# DOCKER_MIGRATE_VERBOSE=1（或 --verbose）时，细节同时显示在屏幕上。
# DOCKER_MIGRATE_LOG_DIR 可指定日志目录，默认 ~/docker_migrate_logs。

# 写入日志前隐藏敏感信息：迁移链接中的密钥，以及 -e/--env 传入或形如
# *PASSWORD=*、*TOKEN=* 的环境变量值（容器配置里常有数据库密码）。
log_redact() {
  sed -E \
    -e 's/((secret|iv|mac)=)[0-9A-Fa-f]+/\1***/g' \
    -e 's/((^|[[:space:]])(-e|--env)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=)[^[:space:]]*/\1***/g' \
    -e 's/(--env=[A-Za-z_][A-Za-z0-9_]*=)[^[:space:]]*/\1***/g' \
    -e 's/([A-Za-z0-9_]*(PASS|PASSWD|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|pass|password|secret|token)[A-Za-z0-9_]*=)[^[:space:]"&]*/\1***/g'
}

log_timestamp() {
  date '+%H:%M:%S'
}

# 追加一行到日志（不显示在屏幕上）。
log_line() {
  [[ -n "${DM_LOG_FILE:-}" ]] || return 0
  printf '[%s] %s\n' "$(log_timestamp)" "$*" | log_redact >>"$DM_LOG_FILE" 2>/dev/null || true
}

# 细节信息：总是写入日志，--verbose 时也显示在屏幕上。
detail() {
  log_line "$*"
  if [[ "${DOCKER_MIGRATE_VERBOSE:-0}" == "1" ]]; then
    screen_clear_line
    printf '    %s\n' "$*" >&2
  fi
}

# 运行命令，把标准输出与错误输出都记进日志而不是丢弃；没有日志时保持静默。
# 命令失败时记录退出码，失败原因因此有据可查。
dm_quiet() {
  local rc=0
  if [[ -z "${DM_LOG_FILE:-}" ]]; then
    "$@" >/dev/null 2>&1 || rc=$?
    return "$rc"
  fi
  log_line "\$ $*"
  "$@" >>"$DM_LOG_FILE" 2>&1 || rc=$?
  ((rc == 0)) || log_line "  → 退出码 ${rc}"
  return "$rc"
}

# 只把错误输出记进日志，标准输出照常返回给调用方（用于需要捕获输出的命令）。
dm_logged() {
  local rc=0
  if [[ -z "${DM_LOG_FILE:-}" ]]; then
    "$@" 2>/dev/null || rc=$?
    return "$rc"
  fi
  log_line "\$ $*"
  "$@" 2>>"$DM_LOG_FILE" || rc=$?
  ((rc == 0)) || log_line "  → 退出码 ${rc}"
  return "$rc"
}

# 日志开头的环境信息：反馈问题时最常需要的版本与资源情况。
log_environment() {
  local kind="$1"
  shift
  printf '===== Docker Migrate %s · %s · %s =====\n' "${SCRIPT_VERSION:-unknown}" "$kind" "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf '参数：%s\n' "$*"
  printf '系统：%s\n' "$(uname -srm 2>/dev/null || echo unknown)"
  if [[ -r /etc/os-release ]]; then
    printf '发行版：%s\n' "$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}")"
  fi
  printf 'bash：%s\n' "${BASH_VERSION:-unknown}"
  printf '用户：uid=%s\n' "$(id -u 2>/dev/null || echo unknown)"
  printf 'Docker：%s\n' "$(docker version --format 'client {{.Client.Version}} / server {{.Server.Version}}' 2>&1 | head -n1)"
  printf 'Docker 存储：%s\n' "$(docker info --format '{{.Driver}} · {{.DockerRootDir}} · cgroup {{.CgroupVersion}}' 2>&1 | head -n1)"
  printf 'Compose：%s\n' "$({ docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null || echo '未安装'; } | head -n1)"
  printf '工具：jq %s · python3 %s · openssl %s\n' \
    "$(jq --version 2>/dev/null || echo '未安装')" \
    "$(python3 --version 2>/dev/null | awk '{print $2}' || true)" \
    "$(openssl version 2>/dev/null | awk '{print $2}' || true)"
  printf '磁盘：\n'
  df -h "$PWD" "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | sed 's/^/  /' || true
  printf '%s\n' '=================================================='
}

# 创建日志文件；子进程已从父进程继承日志时直接沿用。
log_init() {
  local kind="$1" dir
  shift
  if [[ -n "${DM_LOG_FILE:-}" && -f "${DM_LOG_FILE}" ]]; then
    return 0
  fi
  dir="${DOCKER_MIGRATE_LOG_DIR:-${HOME:-/tmp}/docker_migrate_logs}"
  if ! mkdir -p "$dir" 2>/dev/null; then
    dir="${TMPDIR:-/tmp}"
  fi
  chmod 700 "$dir" 2>/dev/null || true
  DM_LOG_FILE="${dir}/${kind}-$(date +%Y%m%d-%H%M%S)-$$.log"
  if ! : >"$DM_LOG_FILE" 2>/dev/null; then
    DM_LOG_FILE=""
    return 0
  fi
  chmod 600 "$DM_LOG_FILE" 2>/dev/null || true
  DM_LOG_OWNER="$$"
  DM_REASON_FILE="${DM_LOG_FILE%.log}.reason"
  DM_WARN_FILE="${DM_LOG_FILE%.log}.warnings"
  DM_TIMING_FILE="${DM_LOG_FILE%.log}.timings"
  : >"$DM_REASON_FILE" 2>/dev/null || true
  : >"$DM_WARN_FILE" 2>/dev/null || true
  : >"$DM_TIMING_FILE" 2>/dev/null || true
  export DM_LOG_FILE DM_LOG_OWNER DM_REASON_FILE DM_WARN_FILE DM_TIMING_FILE
  log_environment "$kind" "$@" 2>&1 | log_redact >>"$DM_LOG_FILE" 2>/dev/null || true
}

# 创建日志的进程在结束时调用：成功则删除日志及附属文件，失败则保留。
log_finish() {
  local success="$1"
  [[ -n "${DM_LOG_FILE:-}" && "${DM_LOG_OWNER:-}" == "$$" ]] || return 0
  # DOCKER_MIGRATE_KEEP_LOG=1 时成功也保留日志，便于排查或测试。
  [[ "${DOCKER_MIGRATE_KEEP_LOG:-0}" != "1" ]] || success=0
  if [[ "$success" == "1" ]]; then
    rm -f "$DM_LOG_FILE" "${DM_REASON_FILE:-}" "${DM_WARN_FILE:-}" "${DM_TIMING_FILE:-}" 2>/dev/null || true
    rmdir "$(dirname "$DM_LOG_FILE")" 2>/dev/null || true
  else
    rm -f "${DM_WARN_FILE:-}" "${DM_TIMING_FILE:-}" 2>/dev/null || true
  fi
}

# 记录本次失败的原因与建议；只保留第一条，它通常就是根因。
fail_reason() {
  local reason="$1" hint="${2:-}"
  log_line "失败原因：${reason}${hint:+（建议：${hint}）}"
  [[ -n "${DM_REASON_FILE:-}" ]] || return 0
  if [[ ! -s "$DM_REASON_FILE" ]]; then
    printf '%s\t%s\n' "$reason" "$hint" >"$DM_REASON_FILE" 2>/dev/null || true
  fi
}

# 读取已记录的失败原因，输出“原因<TAB>建议”。
fail_reason_read() {
  [[ -n "${DM_REASON_FILE:-}" && -s "$DM_REASON_FILE" ]] || return 1
  head -n1 "$DM_REASON_FILE"
}

# 屏幕输出：分阶段显示整体进度。主脚本与生成的恢复脚本共用。
#
# 每个阶段在屏幕上只占一行：进行中时由进度显示原地刷新这一行，完成后
# 替换为“✓ 结果 · 耗时”。警告单独占一行并汇总到最终结果；细节只写日志。
# 阶段信息通过环境变量传给子脚本，让它们的进度行带上同一个阶段前缀。

screen_is_tty() {
  [[ -t 2 ]]
}

screen_clear_line() {
  screen_is_tty || return 0
  printf '\r\033[K' >&2
}

screen_color() {
  local code="$1"
  shift
  if screen_is_tty; then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}

# 当前阶段的前缀，例如“[5/7] 保存镜像”；不在任何阶段内时为空。
stage_prefix() {
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  printf '[%s/%s] %s' "${DM_STAGE_NUM:-?}" "${DM_STAGE_TOTAL:-?}" "$DM_STAGE_TITLE"
}

# 进度行开头：阶段前缀加上正在处理的对象。
stage_label() {
  local label="${1:-}" prefix
  prefix="$(stage_prefix)"
  # 子步骤与阶段同名时不重复显示。
  [[ "$label" != "${DM_STAGE_TITLE:-}" ]] || label=""
  if [[ -n "$prefix" && -n "$label" ]]; then
    printf '%s · %s' "$prefix" "$label"
  else
    printf '%s' "${prefix}${label}"
  fi
}

stage_begin() {
  DM_STAGE_NUM="$1"
  DM_STAGE_TOTAL="$2"
  DM_STAGE_TITLE="$3"
  DM_STAGE_STARTED=$SECONDS
  export DM_STAGE_NUM DM_STAGE_TOTAL DM_STAGE_TITLE
  log_line "===== [${DM_STAGE_NUM}/${DM_STAGE_TOTAL}] ${DM_STAGE_TITLE} ====="
  if screen_is_tty; then
    printf '\r%s\033[K' "$(stage_prefix) …" >&2
  else
    printf '%s\n' "$(stage_prefix)" >&2
  fi
}

# 阶段内需要提问或列出菜单时，先把阶段标题固定成一整行。
stage_hold() {
  screen_is_tty || return 0
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  printf '\r%s\033[K\n' "$(stage_prefix)" >&2
}

stage_record_timing() {
  local elapsed="$1"
  [[ -n "${DM_TIMING_FILE:-}" && -n "${DM_STAGE_TITLE:-}" ]] || return 0
  printf '%s\t%s\n' "$DM_STAGE_TITLE" "$elapsed" >>"$DM_TIMING_FILE" 2>/dev/null || true
}

stage_end() {
  local summary="${1:-}" elapsed
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  elapsed=$((SECONDS - ${DM_STAGE_STARTED:-$SECONDS}))
  stage_record_timing "$elapsed"
  log_line "完成：$(stage_prefix)${summary:+ · ${summary}} · $(format_elapsed "$elapsed")"
  screen_clear_line
  printf '%s %s %s%s\n' "$(stage_prefix)" "$(screen_color '1;32' '✓')" \
    "${summary:+${summary} · }" "$(format_elapsed "$elapsed")" >&2
  DM_STAGE_TITLE=""
  export DM_STAGE_TITLE
}

stage_fail() {
  local elapsed
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  elapsed=$((SECONDS - ${DM_STAGE_STARTED:-$SECONDS}))
  stage_record_timing "$elapsed"
  log_line "失败：$(stage_prefix)"
  screen_clear_line
  printf '%s %s\n' "$(stage_prefix)" "$(screen_color '1;31' '✗')" >&2
  DM_FAILED_STAGE="$(stage_prefix)"
  export DM_FAILED_STAGE
  DM_STAGE_TITLE=""
  export DM_STAGE_TITLE
}

# 警告：屏幕上单独一行，写入日志，并在最终结果中汇总。
warn_user() {
  log_line "警告：$*"
  screen_clear_line
  printf '    %s %s\n' "$(screen_color '1;33' '!')" "$*" >&2
  if [[ -n "${DM_WARN_FILE:-}" ]]; then
    printf '%s\n' "$*" >>"$DM_WARN_FILE" 2>/dev/null || true
  fi
}

# 错误：写入日志并记录为失败原因；屏幕上的完整说明由最终结果统一给出。
error_user() {
  local reason="$1" hint="${2:-}"
  fail_reason "$reason" "$hint"
  if [[ "${DM_SUMMARY_ARMED:-0}" != "1" ]]; then
    screen_clear_line
    printf '%s %s\n' "$(screen_color '1;31' '✗')" "$reason" >&2
    [[ -z "$hint" ]] || printf '  建议：%s\n' "$hint" >&2
  fi
}

# 最终结果中的“阶段耗时”与“警告”部分。
print_stage_timings() {
  local title seconds line=""
  [[ -n "${DM_TIMING_FILE:-}" && -s "$DM_TIMING_FILE" ]] || return 0
  while IFS=$'\t' read -r title seconds; do
    [[ -n "$title" ]] || continue
    line+="${line:+ · }${title} $(format_elapsed "$seconds")"
  done <"$DM_TIMING_FILE"
  [[ -z "$line" ]] || printf '阶段耗时：%s\n' "$line"
}

print_warning_summary() {
  local warning count
  [[ -n "${DM_WARN_FILE:-}" && -s "$DM_WARN_FILE" ]] || return 0
  count="$(awk 'NF' "$DM_WARN_FILE" | wc -l | tr -d ' ')"
  printf '警告：%s 条\n' "$count"
  while IFS= read -r warning; do
    [[ -n "$warning" ]] || continue
    printf '  · %s\n' "$warning"
  done < <(awk 'NF && !seen[$0]++' "$DM_WARN_FILE" | head -n 10)
}

# 失败时的说明：原因、建议、日志位置与最近的日志内容。
print_failure_details() {
  local reason hint row
  if row="$(fail_reason_read)"; then
    IFS=$'\t' read -r reason hint <<<"$row"
    [[ -z "$reason" ]] || printf '原因：%s\n' "$reason"
    [[ -z "$hint" ]] || printf '建议：%s\n' "$hint"
  fi
  if [[ -n "${DM_LOG_FILE:-}" && -f "$DM_LOG_FILE" ]]; then
    printf '日志：%s\n' "$DM_LOG_FILE"
    printf '      反馈问题时请附上这个文件（密钥与密码已自动隐藏），或运行 --diagnose 生成诊断包。\n'
    printf '最近日志：\n'
    tail -n 15 "$DM_LOG_FILE" | sed 's/^/  /'
  fi
}

# 常见错误识别：把 Docker、curl 等工具的英文报错翻译成“原因 + 建议”。
# 主脚本与生成的恢复脚本共用。

# 根据错误文本输出“原因<TAB>建议”；无法识别时返回 1。
explain_error() {
  local text="$1" port
  shopt -s nocasematch
  case "$text" in
    *"port is already allocated"* | *"address already in use"* | *"failed to bind host port"* | *"Bind for "*" failed"*)
      port="$(grep -oE '(Bind for [^ ]*:|host port |0\.0\.0\.0:|\]:)[0-9]+' <<<"$text" | grep -oE '[0-9]+$' | head -n1 || true)"
      printf '宿主机端口%s已被其他程序占用\t执行 ss -lntp%s 查看占用的进程，停止它或修改端口后重试\n' \
        "${port:+ ${port} }" "${port:+ | grep \":${port} \"}"
      ;;
    *"no space left on device"*)
      printf '磁盘空间不足\t执行 df -h 查看剩余空间，清理后重试（docker system prune 可以清理无用的镜像和容器）\n'
      ;;
    *"permission denied while trying to connect to the docker"*)
      printf '当前用户没有访问 Docker 的权限\t请用 root 运行，或用 sudo 运行脚本\n'
      ;;
    *"cannot connect to the docker daemon"* | *"is the docker daemon running"*)
      printf 'Docker 服务没有运行\t执行 systemctl start docker 启动 Docker 后重试\n'
      ;;
    *"exec format error"* | *"does not match the detected host platform"* | *"no matching manifest for"*)
      printf '镜像的 CPU 架构与本机不一致\t请在相同 CPU 架构（如都是 x86_64 或都是 arm64）的服务器之间迁移\n'
      ;;
    *"pull access denied"* | *"repository does not exist"* | *"manifest unknown"* | *"not found: manifest"*)
      printf '镜像仓库中找不到该镜像，或需要登录才能拉取\t检查镜像名；私有镜像请先执行 docker login\n'
      ;;
    *"tls handshake timeout"* | *"i/o timeout"* | *"client.timeout exceeded"* | *"request canceled while waiting"*)
      printf '连接镜像仓库超时\t检查服务器网络，或为 Docker 配置可用的镜像加速地址后重试\n'
      ;;
    *"is already in use by container"*)
      printf '容器名称已被其他容器占用\t删除或重命名同名容器，或设置 RESTORE_EXISTING=replace\n'
      ;;
    *"bind source path does not exist"* | *"invalid mount config"*)
      printf '挂载的宿主机路径不存在\t确认该路径在本机存在后重试\n'
      ;;
    *"could not resolve host"*)
      printf '无法解析链接中的主机名\t检查链接是否完整、DNS 是否可用\n'
      ;;
    *"failed to connect"* | *"connection refused"* | *"couldn't connect to server"*)
      printf '无法连接旧服务器的下载服务\t确认旧服务器上的脚本仍在运行，并检查旧服务器防火墙和云厂商安全组是否放行了下载端口\n'
      ;;
    *"unhealthy"* | *"did not become healthy"* | *"healthcheck timed out"*)
      printf '容器启动后健康检查没有通过\t执行 docker logs <容器名> 查看应用日志；启动较慢的服务可以调大 RESTORE_HEALTH_TIMEOUT\n'
      ;;
    *"timed out"* | *"connection reset"*)
      printf '与旧服务器的连接超时或中断\t检查两台服务器之间的网络，以及旧服务器防火墙和安全组设置，然后重试\n'
      ;;
    *"returned error: 404"* | *"404 not found"*)
      printf '下载地址不存在\t旧服务器可能已经结束传输，或链接没有完整复制；请在旧服务器重新运行备份\n'
      ;;
    *"did not remain running"*)
      printf '容器启动后立即退出\t执行 docker logs <容器名> 查看应用日志\n'
      ;;
    *"operation not permitted"* | *"permission denied"*)
      printf '权限不足\t请用 root 或 sudo 运行脚本\n'
      ;;
    *)
      shopt -u nocasematch
      return 1
      ;;
  esac
  shopt -u nocasematch
}

# 记录失败原因：能识别的报错给出具体原因和建议，否则使用调用方给出的描述。
fail_with_output() {
  local fallback="$1" output="${2:-}" row reason hint
  if [[ -n "$output" ]] && row="$(explain_error "$output")"; then
    IFS=$'\t' read -r reason hint <<<"$row"
    error_user "${fallback}：${reason}" "$hint"
  else
    error_user "$fallback" "${3:-查看下方日志中的最后几行了解详情}"
  fi
}

# 日志末尾的报错文本，用于在命令失败后识别原因。
log_tail_text() {
  [[ -n "${DM_LOG_FILE:-}" && -f "$DM_LOG_FILE" ]] || return 0
  tail -n "${1:-30}" "$DM_LOG_FILE" 2>/dev/null || true
}

# 终端输出：颜色、耗时、结果摘要与帮助信息。

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
      print_stage_timings
      print_warning_summary
      ;;
    FAILED_ROLLED_BACK)
      printf '结果：❌ 恢复失败，已安全回滚\n'
      printf '失败阶段：%s\n' "${stage:-未知阶段}"
      printf '新服务器：原来的服务和数据已还原\n'
      ;;
    INTERRUPTED_ROLLED_BACK)
      printf '结果：⚠️ 恢复已中断，已安全回滚\n'
      printf '中断阶段：%s\n' "${stage:-未知阶段}"
      printf '新服务器：原来的服务和数据已还原\n'
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
  print_decision_summary "${DM_RESTORE_DECISIONS:-}"
  if [[ "$status" != "SUCCESS" ]]; then
    print_warning_summary
    print_failure_details
  fi
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
      print_stage_timings
      print_warning_summary
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
  print_warning_summary
  print_failure_details
  result_end_rule
}

# 下载失败最常见的原因是端口没放行。只给出提示与命令，不擅自修改防火墙。
print_firewall_hint() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  printf '新服务器下载失败时，请确认旧服务器防火墙和云厂商安全组已放行 TCP %s 端口' "$port"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    printf '（检测到 ufw：ufw allow %s/tcp）' "$port"
  elif command -v firewall-cmd >/dev/null 2>&1 &&
    [[ "$(firewall-cmd --state 2>/dev/null || true)" == "running" ]]; then
    printf '（检测到 firewalld：firewall-cmd --add-port=%s/tcp）' "$port"
  fi
  printf '。\n'
}

print_transfer_instructions() {
  local url="$1" mode="${2:-interactive}" source_pid="${3:-}" port
  port="${url#*://}"
  port="${port%%/*}"
  port="${port##*:}"
  printf '\n%s\n' '━━━━━━━━━━ 迁移包已就绪 ━━━━━━━━━━'
  printf '下载链接（请完整复制）：\n%s\n\n' "$url"
  printf '使用方法：在新服务器运行同一脚本 → 选择「2) 下载备份并恢复」→ 粘贴上面的完整链接。\n'
  print_firewall_hint "$port"
  if [[ "$mode" == "interactive" ]]; then
    printf '新服务器恢复成功后，回到这个窗口按回车，停止传输并清理临时文件。\n'
  else
    printf '传输服务会一直运行；新服务器恢复完成后执行：kill -TERM %s\n' "$source_pid"
  fi
  printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
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
  bash docker_migrate_perfect.sh [--backup] [--no-stop] [--include=name1,name2] [--verbose]
  bash docker_migrate_perfect.sh --restore[=URL] [--verbose]
  bash docker_migrate_perfect.sh --diagnose

  --verbose                 在屏幕上显示每一步的细节（默认只写进日志）
  --diagnose                收集系统、Docker 与最近日志，生成可附到 issue 的诊断文件
  --check=URL               只做迁移前预检（端口、磁盘、CPU 类型等），不下载也不修改任何东西

环境变量:
  PORT=8080                 HTTP 端口（被占用会自动递增）
  ADVERTISE_HOST=IP         下载链接中使用的主机名/IP
  RESTORE_EXISTING=replace  同名容器策略：replace、skip 或 fail
  RESTORE_KEEP=1            恢复后保留文件
  RESTORE_CLEAN_ALL=1       恢复失败也强制删除文件
  RESTORE_BASE=/path        自定义恢复目录
  DOCKER_MIGRATE_SNAPSHOT=auto
                            可写层快照：auto 仅在容器内有改动时快照（默认），
                            always 总是快照，never 不迁移容器内未挂载的改动
  STOP_SHARED_MOUNTS=1      非交互模式下允许临时停止共享挂载的其他容器
  DOCKER_MIGRATE_LOG_DIR    日志目录（默认 ~/docker_migrate_logs）；成功后日志自动删除，
                            失败时保留并在结果中给出路径
  DOCKER_MIGRATE_KEEP_LOG=1 成功后也保留日志
  RESTORE_AUTO_RESOLVE=1    非交互模式下，预检发现的问题自动采用推荐处理（如自动换端口）
  RESTORE_SKIP_PREFLIGHT=1  跳过迁移前预检

宿主机系统路径（如 /etc/localtime、/proc、/sys、/dev）只在新服务器重建挂载，不迁移内容。
不带参数运行时仍使用原有交互菜单。
HLP
}

# 系统工具：sudo、超时、包管理器、Docker 服务与磁盘空间。

asudo() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    sudo "$@"
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
      return 1
      ;;
  esac
}

# 安装软件包：输出写入日志、屏幕只显示进度。需要输入 sudo 密码时改为
# 前台运行，保证密码提示可见。
install_package() {
  local bin="$1" pkg="$2"
  if [[ ${EUID:-$(id -u)} -eq 0 ]] || sudo -n true 2>/dev/null; then
    DM_PROGRESS_HINT="正在通过系统包管理器安装，网络较慢时可能需要几分钟" \
      run_with_activity "安装 ${bin}" dm_quiet pm_install "$PKGMGR" "$pkg"
  else
    stage_hold
    printf '    需要安装 %s，请按提示输入 sudo 密码：\n' "$bin" >&2
    pm_install "$PKGMGR" "$pkg"
  fi
}

need_bin() {
  local bin="$1" pkg="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  if [[ "${PKGMGR:-none}" == "none" ]] || ! install_package "$bin" "$pkg" ||
    ! command -v "$bin" >/dev/null 2>&1; then
    error_user "缺少命令 ${bin}，自动安装失败" "请手动安装 ${pkg} 后重试"
    exit 1
  fi
}

try_optional_bin() {
  local bin="$1" pkg="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  [[ "${PKGMGR:-none}" != "none" ]] || return 0
  install_package "$bin" "$pkg" || detail "可选依赖 ${bin} 安装失败，继续运行"
}

ensure_docker_running() {
  local info_error
  if ! command -v docker >/dev/null 2>&1; then
    error_user "未检测到 Docker" "请先安装 Docker（https://docs.docker.com/engine/install/）再运行本脚本"
    exit 1
  fi

  if info_error="$(docker info 2>&1 >/dev/null)"; then
    return 0
  fi
  log_line "docker info 失败：${info_error}"
  if [[ "$info_error" == *"permission denied"* ]]; then
    error_user "当前用户没有访问 Docker 的权限" "请用 root 运行，或用 sudo 运行脚本"
    exit 1
  fi

  detail "Docker 未运行，尝试启动 Docker 服务"
  if command -v systemctl >/dev/null 2>&1; then
    run_with_activity "启动 Docker 服务" dm_quiet asudo systemctl enable --now docker || true
  fi
  if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    run_with_activity "启动 Docker 服务" dm_quiet asudo service docker start || true
  fi
  if ! docker info >/dev/null 2>&1; then
    detail "尝试后台直接启动 dockerd"
    if command -v dockerd >/dev/null 2>&1; then
      asudo nohup dockerd >/var/log/dockerd.migrate.log 2>&1 &
      sleep 3
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    error_user "Docker 服务无法启动" "执行 systemctl status docker 与 journalctl -u docker 查看原因"
    exit 1
  fi
}

# 目录所在文件系统的可用字节数；无法获取时输出空。
free_disk_bytes() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

# 可用空间不足 need 字节时返回 1 并打印提示；无法判断时放行。
ensure_free_space() {
  local dir="$1" need="$2" label="$3" free
  free="$(free_disk_bytes "$dir")"
  [[ "$free" =~ ^[0-9]+$ && "$need" =~ ^[0-9]+$ ]] || return 0
  ((free >= need)) && return 0
  error_user "磁盘空间不足：${label}需要约 $(human "$need")，${dir} 所在磁盘只剩 $(human "$free")" \
    "执行 df -h 查看并清理磁盘后重试"
  return 1
}

# 进度显示与耗时格式化：主脚本与生成的恢复脚本共用。
#
# 耗时操作统一通过 run_with_progress 执行，后台 watcher 每秒（非终端每 10 秒）
# 刷新一行：
#   知道总量时：[5/7] 保存镜像 ██████░░░░ 58% · 1.2GB/2.1GB · 45MB/s · 剩余约 20 秒
#   不知道总量：[4/7] 停机并打包数据 · 卷 mysql_data ⠹ 已处理 1.2GB · 45MB/s · 1 分 3 秒
#   没有字节数：[7/8] 启动服务 · nginx ⠹ 1 分 3 秒
# 长时间没有进展时追加说明（DM_PROGRESS_HINT），让用户知道程序仍在运行、在等什么。

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

# 1536 → 1.5KB；整数部分达到两位后不再保留小数。
human() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1 || b >= 10) printf "%d%s\n", b, u[i]
    else {
      s = sprintf("%.1f", b)
      sub(/\.0$/, "", s)
      printf "%s%s\n", s, u[i]
    }
  }'
}

progress_file_size() {
  local file="$1"
  stat -c %s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0
}

# 当前已处理字节数。spec 为空时没有字节数；"count:路径" 读取计数文件
# （由 progress_meter 写入）；其他情况视为正在增长的输出文件。
progress_current() {
  local spec="${1:-}" value
  case "$spec" in
    "") echo 0 ;;
    count:*)
      value="$(cat "${spec#count:}" 2>/dev/null || true)"
      [[ "$value" =~ ^[0-9]+$ ]] || value=0
      echo "$value"
      ;;
    *) progress_file_size "$spec" ;;
  esac
}

# 总字节数。可以是数字，也可以是 "header:路径"：从 curl -D 写出的响应头中
# 读取 Content-Length（下载开始前未知，开始后才能确定）。
progress_total() {
  local spec="${1:-0}" value
  case "$spec" in
    header:*)
      value="$(tr -d '\r' <"${spec#header:}" 2>/dev/null |
        awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }')"
      ;;
    *) value="$spec" ;;
  esac
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  echo "$value"
}

# 在管道中计数：原样转发标准输入到标准输出，并把累计字节数写入计数文件。
# 没有 python3 时退化为 cat（只是不显示字节数）。
progress_meter() {
  local count_file="${1:-}"
  if [[ -z "$count_file" || "$count_file" == /dev/null ]] || ! command -v python3 >/dev/null 2>&1; then
    cat
    return
  fi
  python3 -c '
import os, sys, time
path = sys.argv[1]
src, dst = sys.stdin.buffer, sys.stdout.buffer
total, last = 0, 0.0
def flush():
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(total))
    os.replace(tmp, path)
while True:
    chunk = src.read(1024 * 1024)
    if not chunk:
        break
    dst.write(chunk)
    total += len(chunk)
    now = time.monotonic()
    if now - last >= 0.5:
        flush()
        last = now
dst.flush()
flush()
' "$count_file"
}

progress_bar() {
  local percent="$1" width=20 filled bar empty
  filled=$((percent * width / 100))
  printf -v bar '%*s' "$filled" ''
  printf -v empty '%*s' "$((width - filled))" ''
  printf '%s%s' "${bar// /█}" "${empty// /░}"
}

# 生成一行进度文字（不含换行）。保持纯函数，便于单元测试。
#   label current total elapsed [rate 字节/秒] [spinner] [hint]
# 只在确实知道总量时显示百分比，避免用“假进度条”误导用户。
progress_render() {
  local label="$1" current="${2:-0}" total="${3:-0}" elapsed="${4:-0}"
  local rate="${5:-0}" spinner="${6:-}" hint="${7:-}"
  local percent line remaining
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0
  [[ "$rate" =~ ^[0-9]+$ ]] || rate=0
  if ((total > 0)); then
    ((current <= total)) || current=$total
    percent=$((current * 100 / total))
    # 总量是估算值时，在命令真正结束前不显示 100%。
    ((percent < 100)) || percent=99
    line="${label} $(progress_bar "$percent") ${percent}% · $(human "$current")/$(human "$total")"
    ((rate == 0)) || line+=" · $(human "$rate")/s"
    if ((rate > 0 && total > current)); then
      remaining=$(((total - current) / rate))
      if ((remaining > 0)); then
        line+=" · 剩余约 $(format_elapsed "$remaining")"
      else
        line+=" · 即将完成"
      fi
    else
      line+=" · $(format_elapsed "$elapsed")"
    fi
  elif ((current > 0)); then
    line="${label}${spinner:+ ${spinner}} 已处理 $(human "$current")"
    ((rate == 0)) || line+=" · $(human "$rate")/s"
    line+=" · $(format_elapsed "$elapsed")"
  else
    line="${label}${spinner:+ ${spinner}} $(format_elapsed "$elapsed")"
  fi
  [[ -z "$hint" ]] || line+=" · ${hint}"
  printf '%s' "$line"
}

progress_tty_draw() {
  # 用一次写入覆盖旧内容，再清除新内容右侧的残留；不要先输出一整行空格，
  # 否则 SSH 或刷新较慢的终端会把中间空帧显示成闪烁。
  printf '\r%s\033[K' "$1" >&2
}

progress_tty_clear() {
  printf '\r\033[K' >&2
}

# 命令失败只记日志：失败原因由阶段结果与最终结果统一说明，避免屏幕上重复报错。
progress_finish() {
  local label="$1" rc="$2" elapsed="$3" current="${4:-0}"
  ((rc != 0)) || return 0
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  log_line "失败：${label}（退出码 ${rc}，耗时 $(format_elapsed "$elapsed")$( ((current == 0)) || printf '，已处理 %s' "$(human "$current")")）"
}

# 逐个处理对象时（如扫描容器）在阶段行里显示“第几个/共几个”。
progress_count() {
  local label="$1" current="$2" total="$3" item="${4:-}"
  local line
  printf -v line '%s %d/%d%s' "$label" "$current" "$total" "${item:+（${item}）}"
  if [[ -t 2 ]]; then
    progress_tty_draw "$(stage_label "$line")"
  elif ((current == total || current % 20 == 0)); then
    printf '[进度] %s\n' "$(stage_label "$line")" >&2
  fi
}

# 不在 run_with_progress 中的等待循环（如健康检查）用它刷新阶段行。
# 非终端时每 10 秒最多输出一行，避免刷屏。
progress_note() {
  local text="$1" now=$SECONDS
  if [[ -t 2 ]]; then
    progress_tty_draw "$(stage_label "$text")"
  elif ((now - ${DM_LAST_NOTE_AT:--100} >= 10)); then
    DM_LAST_NOTE_AT=$now
    printf '[进度] %s\n' "$(stage_label "$text")" >&2
  fi
}

progress_watch() {
  local label="$1" spec="$2" total_spec="$3" started="$4" owner_pid="$5"
  local mode="${DOCKER_MIGRATE_PROGRESS_MODE:-auto}" interval current total elapsed line timer_pid=""
  local last_bytes=0 last_time=$SECONDS rate=0 sample changed_at=$SECONDS hint="" tick=0
  local stall="${DM_PROGRESS_STALL:-30}" spinner
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  [[ "$mode" != "plain" && "$mode" != "off" ]] || return 0
  if [[ -n "${DOCKER_MIGRATE_PROGRESS_INTERVAL:-}" ]]; then
    interval="$DOCKER_MIGRATE_PROGRESS_INTERVAL"
  elif [[ -t 2 ]]; then
    interval=1
  else
    interval=10
  fi
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=10
  [[ "$stall" =~ ^[1-9][0-9]*$ ]] || stall=30
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
    current="$(progress_current "$spec")"
    total="$(progress_total "$total_spec")"
    elapsed=$((SECONDS - started))
    # 速度取指数平滑，避免网络抖动时数字跳得太厉害。
    if ((SECONDS > last_time)); then
      sample=$(((current - last_bytes) / (SECONDS - last_time)))
      ((sample >= 0)) || sample=0
      if ((rate == 0)); then rate=$sample; else rate=$(((rate * 7 + sample * 3) / 10)); fi
    fi
    ((current == last_bytes)) || changed_at=$SECONDS
    last_bytes=$current
    last_time=$SECONDS
    hint=""
    if ((SECONDS - changed_at >= stall)); then
      hint="${DM_PROGRESS_HINT:-仍在进行，请耐心等待}"
    fi
    spinner="${frames[$((tick % 10))]}"
    tick=$((tick + 1))
    if [[ -t 2 ]]; then
      line="$(progress_render "$(stage_label "$label")" "$current" "$total" "$elapsed" "$rate" "$spinner" "$hint")"
      progress_tty_draw "$line"
    else
      printf '[进度] %s\n' "$(progress_render "$(stage_label "$label")" "$current" "$total" "$elapsed" "$rate" "" "$hint")" >&2
    fi
  done
  trap - TERM INT HUP
}

# 运行命令并显示进度。spec/total 的含义见 progress_current / progress_total。
run_with_progress() {
  local label="$1" spec="$2" total="$3"
  shift 3
  local started=$SECONDS watcher_pid rc current=0 restore_errexit=0
  log_line "开始：${label}"
  case $- in *e*) restore_errexit=1 ;; esac
  progress_watch "$label" "$spec" "$total" "$started" "$$" &
  watcher_pid=$!
  set +e
  "$@"
  rc=$?
  ((restore_errexit == 0)) || set -e
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  if [[ -t 2 ]]; then
    # 回到阶段行，不留下已完成子步骤的进度文字。
    if [[ -n "${DM_STAGE_TITLE:-}" ]]; then
      progress_tty_draw "$(stage_prefix) …"
    else
      progress_tty_clear
    fi
  fi
  current="$(progress_current "$spec")"
  progress_finish "$label" "$rc" "$((SECONDS - started))" "$current"
  ((rc != 0)) || log_line "完成：${label} · $(format_elapsed "$((SECONDS - started))")$( ((current == 0)) || printf ' · %s' "$(human "$current")")"
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

# 挂载路径判断：重叠检测、宿主机系统路径与软链接解析。主脚本与恢复脚本共用。

mount_paths_overlap() {
  local left="$1" right="$2"
  while [[ "$left" != "/" && "$left" == */ ]]; do left="${left%/}"; done
  while [[ "$right" != "/" && "$right" == */ ]]; do right="${right%/}"; done
  [[ "$left" != "/" && "$right" != "/" ]] || return 0
  [[ "$left" == "$right" || "$left" == "${right}/"* || "$right" == "${left}/"* ]]
}

# 宿主机系统路径只在目标端重建挂载关系，不迁移其内容：这些路径属于宿主机
# 本身（时区、DNS、内核模块、伪文件系统等），覆盖目标端会破坏新服务器。
# 第一组匹配自身及其子路径；第二组是只在完全相同时才算系统路径的大目录。
SYSTEM_BIND_PREFIXES=(
  /proc /sys /dev /run /var/run /boot /lib/modules /usr/lib/modules
  /var/lib/docker /var/lib/containerd /var/log /etc/docker /etc/systemd
  /lib/systemd /usr/lib/systemd /etc/localtime /etc/timezone /usr/share/zoneinfo
  /etc/hostname /etc/hosts /etc/resolv.conf /etc/machine-id /etc/os-release
  /usr/lib/os-release /etc/passwd /etc/group /etc/shadow /etc/gshadow
  /etc/ssl /etc/pki /etc/ca-certificates
)
SYSTEM_BIND_EXACT=(
  / /etc /usr /usr/lib /usr/bin /usr/local /var /var/lib /lib /lib64 /bin /sbin
  /opt /home /root /srv /mnt /media /tmp
)

bind_path_is_system() {
  local path="$1" prefix
  [[ "$path" == "/" ]] || path="${path%/}"
  for prefix in "${SYSTEM_BIND_EXACT[@]}"; do
    [[ "$path" != "$prefix" ]] || return 0
  done
  for prefix in "${SYSTEM_BIND_PREFIXES[@]}"; do
    [[ "$path" != "$prefix" && "$path" != "${prefix}/"* ]] || return 0
  done
  return 1
}

# bind 源本身是软链接时（如 /srv/app -> /data/app），Docker 挂载的是链接目标。
# 返回真实路径，供备份真实数据；无法解析时原样返回。
bind_resolve_source() {
  local path="$1" resolved=""
  if [[ -L "$path" ]]; then
    resolved="$(realpath "$path" 2>/dev/null || readlink -f "$path" 2>/dev/null || true)"
  fi
  printf '%s\n' "${resolved:-$path}"
}

# 容器改名与网络重连：单容器恢复脚本与恢复事务共用，供失败时还原旧容器。

rename_container_with_retry() {
  local old_name="$1" new_name="$2"
  for _ in {1..20}; do
    if dm_quiet docker rename "$old_name" "$new_name"; then
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
      dm_quiet docker network connect "$network" "$container" || return 1
      continue
    fi
    ip="$(jq -r '.value.IPAMConfig.IPv4Address // empty' <<<"$entry")"
    ip6="$(jq -r '.value.IPAMConfig.IPv6Address // empty' <<<"$entry")"
    [[ -z "$ip" ]] || connect_args+=(--ip "$ip")
    [[ -z "$ip6" ]] || connect_args+=(--ip6 "$ip6")
    while IFS= read -r alias; do
      [[ -z "$alias" ]] || connect_args+=(--alias "$alias")
    done < <(jq -r '.value.Aliases[]? // empty' <<<"$entry")
    dm_quiet docker network connect "${connect_args[@]}" "$network" "$container" || return 1
  done < <(jq -c 'to_entries[]?' "$metadata_file")
}

# Compose 在 com.docker.compose.project.config_files 标签里用逗号连接多个配置
# 文件（-f a.yml -f b.yml）。没有逗号时兼容按冒号分隔的旧写法（COMPOSE_FILE）。
compose_config_files_split() {
  local raw="$1" sep=","
  [[ -n "$raw" ]] || return 0
  [[ "$raw" == *,* ]] || sep=":"
  local -a parts=()
  IFS="$sep" read -r -a parts <<<"$raw"
  printf '%s\n' "${parts[@]}" | awk 'NF'
}

# 等待健康检查的最长时间：至少是 RESTORE_HEALTH_TIMEOUT（默认 60 秒），并且要
# 够容器自己的健康检查跑完第一次。有的镜像每 60 秒才检查一次（如 Vaultwarden），
# 固定等 60 秒会在第一次检查出结果之前就判定超时。
health_wait_seconds() {
  local base="${1:-60}" needed
  shift
  (($# > 0)) || {
    printf '%s\n' "$base"
    return 0
  }
  needed="$(docker inspect "$@" 2>/dev/null | jq '[.[] | .Config.Healthcheck // empty |
    select((.Test[0] // "") != "NONE") |
    ((.StartPeriod // 0) + (if (.Interval // 0) > 0 then .Interval else 30000000000 end) +
      (if (.Timeout // 0) > 0 then .Timeout else 30000000000 end)) / 1000000000 + 30 | floor] |
    max // 0' 2>/dev/null || echo 0)"
  [[ "$needed" =~ ^[0-9]+$ ]] || needed=0
  ((needed > base)) || needed="$base"
  ((needed <= 3600)) || needed=3600
  printf '%s\n' "$needed"
}

# 迁移包摘要、加密与解密。

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

bundle_pack_encrypt_directory() {
  local bundle_root="$1" member="$2" output="$3"
  local encryption_key="$4" mac_key="$5" iv="$6" count_file="${7:-}"
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
        progress_meter "$count_file" |
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
      progress_meter "$count_file" |
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

# 迁移包结构：校验清单、manifest 与归档安全检查、恢复结果统计。

json_array_from_lines() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
    return 0
  fi
  # 过滤空行，避免空数组被序列化成 [""]。
  printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -cs .
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
    all(.networks[]; type == "object" and (.name | type == "string")) and
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
      (.file | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*\\.tgz$")) and
      ((.link // null) == null or (.link | type == "string" and startswith("/") and . != "/" and
        (test("(^|/)\\.\\.(/|$)") | not) and
        all(explode[]; . >= 32 and . != 127)))
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

# 迁移计划（plan.json）：新服务器在下载迁移包之前用它做预检。
#
# 源端打包时根据迁移清单与容器配置生成，内容只有“迁移需要什么”：CPU 架构、
# 容器端口、网络网段、数据卷与目录大小等，没有任何业务数据。它既放进迁移包，
# 也单独加密后与迁移包一起提供下载；新服务器从同一个链接推算出它的地址，
# 用户只需要复制一个链接。

# 下载链接 → 迁移计划地址：同一随机路径下，把 .tar.gz.enc 换成 .plan。
plan_url_from_bundle_url() {
  local url="${1%%#*}"
  [[ "$url" == *.tar.gz.enc ]] || return 1
  printf '%s.plan\n' "${url%.tar.gz.enc}"
}

# 计划使用与迁移包不同的 IV：同一把 CTR 密钥绝不能重复使用同一个 IV。
plan_iv() {
  printf 'docker-migrate-plan:%s' "${1,,}" | openssl dgst -sha256 2>/dev/null | awk '{print substr($NF, 1, 32)}'
}

# 生成迁移计划（输出到标准输出）。
plan_build() {
  local bundle_dir="$1" images_bytes="${2:-0}" plain_bytes
  plain_bytes="$(path_size_bytes "$bundle_dir")"
  jq -n \
    --arg arch "$(docker info --format '{{.Architecture}}' 2>/dev/null || uname -m)" \
    --arg docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)" \
    --argjson images_bytes "${images_bytes:-0}" \
    --argjson plain_bytes "${plain_bytes:-0}" \
    --slurpfile manifest "${bundle_dir}/manifest.json" \
    --slurpfile metas <(cat "${bundle_dir}"/meta/*.inspect.json 2>/dev/null || true) '
    ($manifest[0]) as $m |
    ([$m.projects[]?.name]) as $projects |
    {
      version: 1,
      source: {arch: $arch, docker: $docker},
      sizes: {
        bundle: $plain_bytes,
        images: $images_bytes,
        volumes: ([$m.volumes[]?.bytes // 0] | add // 0),
        binds: ([$m.binds[]?.bytes // 0] | add // 0)
      },
      needs_compose: (($projects | length) > 0),
      projects: $projects,
      containers: [$metas[] | .[0] |
        (.Config.Labels["com.docker.compose.project"] // "") as $project |
        {
          name: (.Name | ltrimstr("/")),
          project: (if ($projects | index($project)) then $project else "" end),
          network_mode: (.HostConfig.NetworkMode // "default"),
          runtime: (.HostConfig.Runtime // ""),
          devices: [.HostConfig.Devices[]?.PathOnHost],
          memory: (.HostConfig.Memory // 0),
          ports: [(.HostConfig.PortBindings // {}) | to_entries[] | .key as $c | .value[]? |
            select((.HostPort // "") != "") |
            {host_ip: (.HostIp // ""), host_port: .HostPort,
             container_port: ($c | split("/")[0]), proto: ($c | split("/")[1] // "tcp")}],
          networks: [(.NetworkSettings.Networks // {}) | to_entries[] |
            {name: .key, ip: (.value.IPAMConfig.IPv4Address // "")}],
          volumes: [.Mounts[]? | select(.Type == "volume") | .Name],
          binds: [.Mounts[]? | select(.Type == "bind") | .Source]
        }],
      volumes: [$m.volumes[]? | {name, driver: (.driver // "local"), opts: (.opts // {}), bytes: (.bytes // 0)}],
      binds: [$m.binds[]? | {host, link: (.link // ""), bytes: (.bytes // 0)}],
      networks: [$m.networks[]? | {name, driver: (.driver // "bridge"),
        subnets: [.ipam.config[]?.Subnet // empty],
        compose: ((.labels // {})["com.docker.compose.network"] != null)}]
    }'
}

# 加密迁移计划：输出文件第一行是签名（HMAC），其后是密文。
plan_encrypt() {
  local input="$1" output="$2" encryption_key="$3" mac_key="$4" iv="$5" piv tmp mac
  piv="$(plan_iv "$iv")"
  valid_hex_length "$piv" 32 || return 1
  tmp="${output}.cipher.$$"
  openssl enc -aes-256-ctr -nosalt -K "$encryption_key" -iv "$piv" -in "$input" -out "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mac="$(bundle_hmac_sha256_file "$tmp" "$mac_key" "$piv")" || {
    rm -f "$tmp"
    return 1
  }
  {
    printf '%s\n' "$mac"
    cat "$tmp"
  } >"$output"
  rm -f "$tmp"
}

# 验证签名并解密迁移计划。签名不符时返回 2（文件被篡改或链接不完整）。
plan_decrypt() {
  local input="$1" output="$2" encryption_key="$3" mac_key="$4" iv="$5" piv tmp mac
  piv="$(plan_iv "$iv")"
  valid_hex_length "$piv" 32 || return 1
  mac="$(head -n1 "$input" 2>/dev/null || true)"
  valid_sha256 "$mac" || return 2
  tmp="${output}.cipher.$$"
  tail -c +66 "$input" >"$tmp" || return 1
  if [[ "$(bundle_hmac_sha256_file "$tmp" "$mac_key" "$piv" 2>/dev/null || true)" != "${mac,,}" ]]; then
    rm -f "$tmp"
    return 2
  fi
  openssl enc -d -aes-256-ctr -nosalt -K "$encryption_key" -iv "$piv" -in "$tmp" -out "$output" ||
    {
      rm -f "$tmp"
      return 1
    }
  rm -f "$tmp"
  jq -e '.version == 1' "$output" >/dev/null 2>&1 || return 1
}

# 迁移前预检：在下载迁移包、改动新服务器之前，根据迁移计划找出会让迁移失败的问题。
#
# 问题分三级：
#   info  只提示，不停下（如 Docker 版本较旧）
#   ask   会导致迁移失败但可以处理，停下来让用户针对性地选择（如端口被占用）
#   stop  无法继续（如 CPU 架构不同）
# 用户的选择写进“恢复决定”文件（JSON），恢复脚本按它执行：换端口、跳过项目、
# 改为自动分配 IP 等。检查逻辑用 python3 实现（新服务器恢复时本来就需要它）。

# 输出检查结果 JSON：{"issues": [...], "summary": {...}}。
preflight_collect() {
  local plan="$1" decisions="$2" base_dir="$3"
  python3 - "$plan" "$decisions" "$base_dir" <<'PREFLIGHT_PY'
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys

plan_path, decisions_path, base_dir = sys.argv[1:4]
plan = json.load(open(plan_path))
try:
    decisions = json.load(open(decisions_path))
except (OSError, ValueError):
    decisions = {}
issues = []


def run(cmd):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def human(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            if unit == "B" or n >= 10:
                return "%d%s" % (n, unit)
            return ("%.1f" % n).rstrip("0").rstrip(".") + unit
        n /= 1024


def cjk_spaced(text):
    """中文排版：与英文或数字相邻时加一个空格，与中文或全角符号相邻时不加。"""
    if not text:
        return text
    left = " " if ord(text[0]) < 128 and text[0].isalnum() else ""
    right = " " if ord(text[-1]) < 128 and text[-1].isalnum() else ""
    return left + text + right


def add(level, kind, title, hint="", **data):
    item = {"level": level, "type": kind, "title": title, "hint": hint}
    item.update(data)
    issues.append(item)


def free_bytes(path):
    path = os.path.abspath(path or "/")
    while not os.path.exists(path) and path != "/":
        path = os.path.dirname(path)
    try:
        st = os.statvfs(path)
        return st.f_bavail * st.f_frsize, os.stat(path).st_dev
    except OSError:
        return None, None


skip_projects = set(decisions.get("skip_projects", []))
skip_containers = set(decisions.get("skip_containers", []))
replace_containers = set(decisions.get("replace_containers", []))
replace_projects = set(decisions.get("replace_projects", []))
keep_volumes = set(decisions.get("keep_volumes", []))
auto_subnet = set(decisions.get("auto_subnet", []))
reuse_network = set(decisions.get("reuse_network", []))
auto_ip = {(x.get("container"), x.get("network")) for x in decisions.get("auto_ip", [])}
port_map = {}
for item in decisions.get("port_map", []):
    key = (item.get("container"), item.get("host_ip", ""), str(item.get("host_port")),
           str(item.get("container_port")), item.get("proto", "tcp"))
    port_map[key] = str(item.get("new_port", ""))

containers = [c for c in plan.get("containers", [])
              if c.get("project", "") not in skip_projects and c["name"] not in skip_containers]
plan_names = {c["name"] for c in containers}
used_volumes = {v for c in containers for v in c.get("volumes", [])}
used_binds = {b for c in containers for b in c.get("binds", [])}

# ---------- Docker 环境 ----------
rc, out = run(["docker", "info", "--format", "{{json .}}"])
try:
    info = json.loads(out) if rc == 0 else {}
except ValueError:
    info = {}

arch_alias = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64",
              "armv7l": "arm", "armhf": "arm", "arm": "arm"}
src_arch = plan.get("source", {}).get("arch", "")
dst_arch = info.get("Architecture", "") or os.uname().machine
if src_arch and dst_arch and arch_alias.get(src_arch, src_arch) != arch_alias.get(dst_arch, dst_arch):
    add("stop", "arch",
        "两台服务器的 CPU 类型不同：旧服务器是 %s，新服务器是 %s" % (src_arch, dst_arch),
        "容器镜像只能在相同 CPU 类型的服务器上运行，请换一台和旧服务器相同类型的服务器")


def version_tuple(v):
    nums = re.findall(r"\d+", v or "")
    return tuple(int(x) for x in nums[:2]) if len(nums) >= 2 else None


src_ver = plan.get("source", {}).get("docker", "")
dst_ver = info.get("ServerVersion", "")
if version_tuple(src_ver) and version_tuple(dst_ver) and version_tuple(dst_ver) < version_tuple(src_ver):
    add("info", "docker_version",
        "新服务器的 Docker（%s）比旧服务器（%s）旧，一般不影响迁移" % (dst_ver, src_ver))

if any(c.get("project") for c in containers):
    has_plugin = run(["docker", "compose", "version"])[0] == 0
    if not has_plugin and not shutil.which("docker-compose"):
        add("stop", "compose",
            "要迁移 Compose 项目，但新服务器没有安装 Docker Compose",
            "先安装 Docker Compose（例如 apt install docker-compose-plugin）再重试")

runtimes = set((info.get("Runtimes") or {}).keys())
for c in containers:
    rt = c.get("runtime", "")
    if rt and rt != "runc" and runtimes and rt not in runtimes:
        add("stop", "runtime", "容器 %s 需要 %s 运行环境，新服务器没有安装" % (c["name"], rt),
            "先在新服务器安装它（例如 NVIDIA 显卡需要安装 NVIDIA Container Toolkit）再重试")
    for dev in c.get("devices", []):
        if dev and not os.path.exists(dev):
            add("stop", "device", "容器 %s 需要设备 %s，新服务器上没有" % (c["name"], dev),
                "确认新服务器有这个硬件并已安装驱动")

volume_plugins = set((info.get("Plugins") or {}).get("Volume") or [])
for v in plan.get("volumes", []):
    if v["name"] not in used_volumes:
        continue
    driver = v.get("driver", "local")
    if driver != "local" and volume_plugins and driver not in volume_plugins:
        add("stop", "volume_plugin", "数据卷 %s 使用 %s 插件存储，新服务器没有安装这个插件" % (v["name"], driver),
            "先在新服务器安装 %s 卷插件再重试" % driver)

mem_total = info.get("MemTotal") or 0
mem_need = sum(int(c.get("memory") or 0) for c in containers)
if mem_total and mem_need > mem_total:
    add("info", "memory", "容器设置的内存上限合计 %s，超过新服务器的内存 %s，内存紧张时容器可能被系统结束"
        % (human(mem_need), human(mem_total)))

# ---------- 磁盘空间 ----------
sizes = plan.get("sizes", {})
bundle = int(sizes.get("bundle") or 0)
kept_volume_bytes = sum(int(v.get("bytes") or 0) for v in plan.get("volumes", [])
                        if v["name"] in keep_volumes or v["name"] not in used_volumes)
docker_need = int(sizes.get("images") or 0) + int(sizes.get("volumes") or 0) - kept_volume_bytes
# 在已解压的迁移包里手动恢复时，下载和解压所需空间已经用掉了，不再计算。
skip_base = os.environ.get("PREFLIGHT_SKIP_BASE_DISK") == "1"
if skip_base:
    bundle = 0
base_need = 2 * bundle
base_free, base_dev = free_bytes(base_dir)
root_free, root_dev = free_bytes(info.get("DockerRootDir") or "/var/lib/docker")
if base_free is not None and root_free is not None and base_dev == root_dev:
    # 同一块磁盘：解压出的迁移包与加载后的镜像、数据卷会同时存在。
    total = max(base_need, bundle + docker_need)
    if base_free < total:
        add("ask", "disk_base",
            "磁盘空间不够：迁移需要约 %s，%s 所在磁盘只剩 %s" % (human(total), base_dir, human(base_free)),
            "清理磁盘后重新检查，或换一个空间更大的磁盘存放下载文件",
            need=total, free=base_free)
    elif base_free < total * 1.2:
        add("info", "disk_tight", "磁盘空间偏紧：迁移需要约 %s，剩余 %s" % (human(total), human(base_free)))
else:
    if base_free is not None and base_free < base_need:
        add("ask", "disk_base",
            "磁盘空间不够：下载和解压需要约 %s，%s 所在磁盘只剩 %s" % (human(base_need), base_dir, human(base_free)),
            "清理磁盘后重新检查，或换一个空间更大的磁盘存放下载文件",
            need=base_need, free=base_free)
    root = info.get("DockerRootDir") or "/var/lib/docker"
    if root_free is not None and root_free < docker_need:
        add("ask", "disk_docker",
            "磁盘空间不够：Docker 存放镜像和数据卷需要约 %s，%s 所在磁盘只剩 %s" % (human(docker_need), root, human(root_free)),
            "清理磁盘后重新检查（docker system prune 可以清理不用的镜像和容器）",
            need=docker_need, free=root_free)

for b in plan.get("binds", []):
    if b["host"] not in used_binds and (not b.get("link") or b["link"] not in used_binds):
        continue
    need = int(b.get("bytes") or 0)
    free, _ = free_bytes(b["host"])
    if free is not None and need and free < need:
        add("ask", "disk_bind",
            "磁盘空间不够：目录 %s 需要约 %s，所在磁盘只剩 %s" % (b["host"], human(need), human(free)),
            "清理这块磁盘后重新检查", need=need, free=free)

# ---------- 已有的同名容器、Compose 项目、数据卷 ----------
rc, out = run(["docker", "ps", "-a", "--format",
               '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Ports}}'])
existing = {}
for line in out.splitlines():
    parts = line.split("\t")
    if len(parts) >= 3:
        existing[parts[0]] = {"project": parts[1], "ports": parts[2]}
existing_projects = {e["project"] for e in existing.values() if e["project"]}
policy = os.environ.get("RESTORE_EXISTING", "")

for c in containers:
    if c.get("project") or c["name"] not in existing or c["name"] in replace_containers:
        continue
    if policy == "fail":
        add("stop", "existing_container", "新服务器上已经有同名容器 %s（RESTORE_EXISTING=fail 不允许替换）" % c["name"],
            "删除这个容器，或改用 RESTORE_EXISTING=replace")
    elif policy not in ("replace", "skip"):
        add("ask", "existing_container", "新服务器上已经有同名容器 %s" % c["name"], container=c["name"])
for project in sorted({c["project"] for c in containers if c.get("project")}):
    if project not in existing_projects or project in replace_projects:
        continue
    if policy == "fail":
        add("stop", "existing_project", "新服务器上已经有同名的 Compose 项目 %s（RESTORE_EXISTING=fail 不允许替换）" % project,
            "删除这个项目的容器，或改用 RESTORE_EXISTING=replace")
    elif policy not in ("replace", "skip"):
        add("ask", "existing_project", "新服务器上已经有同名的 Compose 项目 %s" % project, project=project)

for v in plan.get("volumes", []):
    if v["name"] not in used_volumes or v["name"] in keep_volumes:
        continue
    rc, out = run(["docker", "volume", "inspect", v["name"]])
    if rc != 0:
        continue
    try:
        cur = json.loads(out)[0]
    except (ValueError, IndexError):
        continue
    if (cur.get("Driver") or "local") != v.get("driver", "local") or (cur.get("Options") or {}) != (v.get("opts") or {}):
        add("ask", "volume_mismatch",
            "新服务器已有同名数据卷 %s，但它的存储方式和旧服务器不同" % v["name"], volume=v["name"])
    else:
        add("info", "volume_replace", "数据卷 %s 已存在，迁移的数据会替换它（失败时自动还原）" % v["name"])

# ---------- 网络 ----------
target_nets = {}
rc, out = run(["docker", "network", "ls", "-q"])
ids = out.split()
if ids:
    rc, out = run(["docker", "network", "inspect"] + ids)
    try:
        for n in json.loads(out) if rc == 0 else []:
            target_nets[n["Name"]] = {
                "driver": n.get("Driver", ""),
                "subnets": [c.get("Subnet") for c in (n.get("IPAM") or {}).get("Config") or [] if c.get("Subnet")],
                "ips": {(v.get("IPv4Address") or "").split("/")[0]: v.get("Name", "")
                        for v in (n.get("Containers") or {}).values()},
            }
    except ValueError:
        pass

plan_nets = {n["name"]: n for n in plan.get("networks", [])}
used_nets = {net["name"] for c in containers for net in c.get("networks", [])}
for name, net in plan_nets.items():
    if name not in used_nets or name in ("bridge", "host", "none") or net.get("compose"):
        continue
    if net.get("driver") in ("macvlan", "ipvlan"):
        add("info", "macvlan", "网络 %s 使用 %s，需要新服务器的网卡名称和旧服务器一致" % (name, net["driver"]))
    if name in reuse_network or name in auto_subnet:
        continue
    wanted = [s for s in net.get("subnets", []) if s]
    if name in target_nets:
        have = target_nets[name]
        if sorted(have["subnets"]) != sorted(wanted) or have["driver"] != net.get("driver", "bridge"):
            add("ask", "network_mismatch",
                "新服务器已有同名网络 %s，但网段不同（旧服务器 %s，新服务器 %s）"
                % (name, "、".join(wanted) or "自动", "、".join(have["subnets"]) or "自动"), network=name)
        continue
    for subnet in wanted:
        try:
            mine = ipaddress.ip_network(subnet, strict=False)
        except ValueError:
            continue
        clash = None
        for other, have in target_nets.items():
            for s in have["subnets"]:
                try:
                    if mine.overlaps(ipaddress.ip_network(s, strict=False)):
                        clash = (other, s)
                except (ValueError, TypeError):
                    pass
        if clash:
            add("ask", "subnet_conflict",
                "网络 %s 要用的网段 %s 和新服务器上的网络 %s（%s）重叠" % (name, subnet, clash[0], clash[1]),
                network=name)
            break

for c in containers:
    for net in c.get("networks", []):
        ip = net.get("ip", "")
        name = net["name"]
        if not ip or name in reuse_network or name in auto_subnet or (c["name"], name) in auto_ip:
            continue
        holder = target_nets.get(name, {}).get("ips", {}).get(ip)
        if holder and holder != c["name"] and holder not in plan_names:
            add("ask", "ip_conflict", "网络 %s 中的 IP %s 已被容器 %s 使用，容器 %s 需要它" % (name, ip, holder, c["name"]),
                container=c["name"], network=name)

# ---------- 端口 ----------
WILD = {"", "0.0.0.0", "::", "*", "[::]"}


def parse_listeners():
    found = []
    tool = None
    for proto, flag in (("tcp", "-Hltnp"), ("udp", "-Hlunp")):
        rc, out = run(["ss", flag])
        if rc != 0:
            rc, out = run(["ss", flag.replace("p", "")])
        if rc != 0:
            continue
        tool = "ss"
        for line in out.splitlines():
            cols = line.split()
            if len(cols) < 5:
                continue
            local = cols[3]
            host, _, port = local.rpartition(":")
            host = host.strip("[]").split("%")[0]
            proc = ""
            m = re.search(r'users:\(\("([^"]+)",pid=(\d+)', line)
            if m:
                proc = "%s（进程 %s）" % (m.group(1), m.group(2))
            if port.isdigit():
                found.append((proto, host, port, proc))
    return tool, found


tool, listeners = parse_listeners()
docker_ports = {}
for cname, e in existing.items():
    for m in re.finditer(r"([0-9a-fA-F:.\[\]]*):(\d+)->\d+/(tcp|udp)", e["ports"]):
        docker_ports.setdefault((m.group(3), m.group(2)), cname)


def port_holder(proto, host_ip, port):
    owner = docker_ports.get((proto, port))
    if owner:
        return "容器 %s" % owner, owner
    for p, host, lport, proc in listeners:
        if p == proto and lport == port and (host_ip in WILD or host in WILD or host == host_ip):
            if "docker-proxy" in proc:
                continue
            return proc or "其他程序", None
    return None, None


requested = set()
for c in containers:
    if c.get("network_mode", "") == "host" or c.get("network_mode", "").startswith("container:"):
        continue
    for p in c.get("ports", []):
        key = (c["name"], p.get("host_ip", ""), str(p["host_port"]), str(p["container_port"]), p.get("proto", "tcp"))
        port = port_map.get(key, str(p["host_port"]))
        if not port:
            continue
        requested.add((p.get("proto", "tcp"), port))
        holder, owner = port_holder(p.get("proto", "tcp"), p.get("host_ip", ""), port)
        if not holder:
            continue
        # 占用端口的正是将被替换的同名容器：恢复时它会先停止，不算冲突。
        if owner and owner in plan_names:
            continue
        busy = {(pr, po) for pr, _, po, _ in listeners} | set(docker_ports.keys()) | requested
        suggest = next((str(x) for x in range(int(port) + 1, min(int(port) + 200, 65536))
                        if (p.get("proto", "tcp"), str(x)) not in busy), "")
        add("ask", "port",
            "端口 %s 已被%s占用，%s需要使用它" % (port, cjk_spaced(holder),
                ("Compose 项目 %s 的容器 %s " % (c["project"], c["name"])) if c.get("project") else ("容器 %s " % c["name"])),
            container=c["name"], project=c.get("project", ""), host_ip=p.get("host_ip", ""),
            host_port=str(p["host_port"]), current_port=port, container_port=str(p["container_port"]),
            proto=p.get("proto", "tcp"), holder=holder, suggest=suggest)
if tool is None and any(c.get("ports") for c in containers):
    add("info", "port_unchecked", "新服务器没有 ss 命令，无法提前检查端口是否被占用")

need = max(base_need, bundle + docker_need)
json.dump({"issues": issues, "summary": {"containers": len(containers), "need_bytes": need}},
          sys.stdout, ensure_ascii=False)
PREFLIGHT_PY
}

# ---------- 恢复决定文件 ----------

preflight_decide() {
  local file="$1" filter="$2"
  shift 2
  local tmp="${file}.tmp.$$"
  [[ -s "$file" ]] || printf '{}\n' >"$file"
  jq "$@" "$filter" "$file" >"$tmp" && mv "$tmp" "$file"
}

# 读取一个选项编号；回车选默认值。非交互时直接使用默认值。
preflight_choose() {
  local max="$1" default="$2" answer
  while :; do
    printf '请选择 [%s]：' "$default" >&2
    read -r answer </dev/tty || answer=""
    answer="${answer:-$default}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= max)); then
      printf '%s\n' "$answer"
      return 0
    fi
    printf '请输入 1 到 %s 之间的数字。\n' "$max" >&2
  done
}

preflight_option() {
  printf '  %s) %s\n' "$1" "$2" >&2
}

# 处理一个“需要用户选择”的问题。返回 0 表示已处理（或选择了重新检查），
# 返回 1 表示用户选择取消。auto=1 时自动采用推荐做法，无法自动处理时返回 1。
preflight_resolve() {
  local issue="$1" decisions="$2" index="$3" total="$4" auto="$5"
  local kind title choice container project port new_port network volume
  kind="$(jq -r '.type' <<<"$issue")"
  title="$(jq -r '.title' <<<"$issue")"
  container="$(jq -r '.container // ""' <<<"$issue")"
  project="$(jq -r '.project // ""' <<<"$issue")"
  network="$(jq -r '.network // ""' <<<"$issue")"
  volume="$(jq -r '.volume // ""' <<<"$issue")"

  if [[ "$auto" != "1" ]]; then
    printf '\n问题 %s/%s：' "$index" "$total" >&2
  fi
  case "$kind" in
    port)
      port="$(jq -r '.current_port' <<<"$issue")"
      new_port="$(jq -r '.suggest // ""' <<<"$issue")"
      if [[ -n "$project" ]]; then
        if [[ "$auto" == "1" ]]; then
          log_line "无法自动处理：${title}"
          return 1
        fi
        printf '%s\n' "$(screen_color '1;33' "⚠️  端口被占用，Compose 项目 ${project} 无法启动")" >&2
        printf '  %s\n' "$title" >&2
        printf '  请自行停止占用端口的程序，或修改 %s 的 compose 文件中的端口后再继续。\n' "$project" >&2
        preflight_option 1 "我已处理好，重新检查（推荐）"
        preflight_option 2 "暂时跳过 ${project} 项目，继续迁移其他容器"
        preflight_option 3 "取消恢复"
        choice="$(preflight_choose 3 1)"
        case "$choice" in
          2) preflight_decide "$decisions" '.skip_projects = ((.skip_projects // []) + [$p] | unique) |
               .skipped_reasons = ((.skipped_reasons // []) + [{project: $p, reason: $r}])' \
            --arg p "$project" --arg r "端口 ${port} 被占用" ;;
          3) return 1 ;;
        esac
        return 0
      fi
      if [[ "$auto" == "1" ]]; then
        [[ -n "$new_port" ]] || return 1
        choice=1
      else
        printf '%s\n' "$title" >&2
        if [[ -n "$new_port" ]]; then
          preflight_option 1 "改用空闲端口 ${new_port}（推荐）"
        else
          preflight_option 1 "改用其他端口（附近没有找到空闲端口，需要手动输入）"
        fi
        preflight_option 2 "输入其他端口"
        preflight_option 3 "我先停掉占用端口的程序，然后重新检查"
        preflight_option 4 "不对外开放这个端口"
        preflight_option 5 "取消恢复"
        choice="$(preflight_choose 5 1)"
      fi
      if [[ "$choice" == 1 && -z "$new_port" ]] || [[ "$choice" == 2 ]]; then
        while :; do
          printf '新端口：' >&2
          read -r new_port </dev/tty || new_port=""
          [[ "$new_port" =~ ^[0-9]+$ ]] && ((new_port >= 1 && new_port <= 65535)) && break
          printf '请输入 1 到 65535 之间的端口号。\n' >&2
        done
        choice=1
      fi
      case "$choice" in
        1 | 4)
          [[ "$choice" == 1 ]] || new_port=""
          preflight_decide "$decisions" '
            .port_map = ([(.port_map // [])[] | select((.container == $c and .host_ip == $ip and
              .host_port == $hp and .container_port == $cp and .proto == $proto) | not)] +
              [{container: $c, host_ip: $ip, host_port: $hp, container_port: $cp, proto: $proto, new_port: $np}])' \
            --arg c "$container" --arg ip "$(jq -r '.host_ip' <<<"$issue")" \
            --arg hp "$(jq -r '.host_port' <<<"$issue")" --arg cp "$(jq -r '.container_port' <<<"$issue")" \
            --arg proto "$(jq -r '.proto' <<<"$issue")" --arg np "$new_port"
          ;;
        5) return 1 ;;
      esac
      ;;
    existing_container | existing_project)
      if [[ "$auto" == "1" ]]; then
        choice=1
      else
        printf '%s\n' "$title" >&2
        preflight_option 1 "替换它（推荐，迁移失败时会自动还原）"
        if [[ "$kind" == existing_project ]]; then
          preflight_option 2 "保留已有的，跳过这个项目"
        else
          preflight_option 2 "保留已有的，跳过这个容器"
        fi
        preflight_option 3 "取消恢复"
        choice="$(preflight_choose 3 1)"
      fi
      case "$kind:$choice" in
        existing_container:1) preflight_decide "$decisions" '.replace_containers = ((.replace_containers // []) + [$c] | unique)' --arg c "$container" ;;
        existing_container:2) preflight_decide "$decisions" '.skip_containers = ((.skip_containers // []) + [$c] | unique) |
          .skipped_reasons = ((.skipped_reasons // []) + [{container: $c, reason: "保留新服务器上已有的容器"}])' --arg c "$container" ;;
        existing_project:1) preflight_decide "$decisions" '.replace_projects = ((.replace_projects // []) + [$p] | unique)' --arg p "$project" ;;
        existing_project:2) preflight_decide "$decisions" '.skip_projects = ((.skip_projects // []) + [$p] | unique) |
          .skipped_reasons = ((.skipped_reasons // []) + [{project: $p, reason: "保留新服务器上已有的项目"}])' --arg p "$project" ;;
        *:3) return 1 ;;
      esac
      ;;
    ip_conflict | subnet_conflict | network_mismatch)
      if [[ "$auto" == "1" ]]; then
        choice=1
      else
        printf '%s\n' "$title" >&2
        case "$kind" in
          ip_conflict) preflight_option 1 "改为由 Docker 自动分配 IP（推荐）" ;;
          subnet_conflict) preflight_option 1 "让 Docker 自动选择一个不冲突的网段，网络里的容器改为自动分配 IP（推荐）" ;;
          network_mismatch) preflight_option 1 "继续使用新服务器上已有的这个网络，容器改为自动分配 IP（推荐）" ;;
        esac
        preflight_option 2 "取消恢复"
        choice="$(preflight_choose 2 1)"
      fi
      [[ "$choice" == 1 ]] || return 1
      case "$kind" in
        ip_conflict) preflight_decide "$decisions" '.auto_ip = ((.auto_ip // []) + [{container: $c, network: $n}] | unique)' \
          --arg c "$container" --arg n "$network" ;;
        subnet_conflict) preflight_decide "$decisions" '.auto_subnet = ((.auto_subnet // []) + [$n] | unique)' --arg n "$network" ;;
        network_mismatch) preflight_decide "$decisions" '.reuse_network = ((.reuse_network // []) + [$n] | unique)' --arg n "$network" ;;
      esac
      ;;
    volume_mismatch)
      [[ "$auto" != "1" ]] || return 1
      printf '%s\n' "$title" >&2
      preflight_option 1 "取消恢复，我先处理这个数据卷（推荐）"
      preflight_option 2 "保留已有的数据卷，不写入迁移过来的数据"
      choice="$(preflight_choose 2 1)"
      [[ "$choice" == 2 ]] || return 1
      preflight_decide "$decisions" '.keep_volumes = ((.keep_volumes // []) + [$v] | unique)' --arg v "$volume"
      ;;
    disk_base)
      [[ "$auto" != "1" ]] || return 1
      printf '%s\n' "$title" >&2
      preflight_option 1 "我先清理磁盘，然后重新检查（推荐）"
      preflight_option 2 "换一个目录存放下载文件"
      preflight_option 3 "取消恢复"
      choice="$(preflight_choose 3 1)"
      case "$choice" in
        2)
          local dir
          printf '目录（例如 /data/restore）：' >&2
          read -r dir </dev/tty || dir=""
          [[ "$dir" == /* ]] && preflight_decide "$decisions" '.restore_base = $d' --arg d "$dir"
          ;;
        3) return 1 ;;
      esac
      ;;
    disk_docker | disk_bind | *)
      [[ "$auto" != "1" ]] || return 1
      printf '%s\n' "$title" >&2
      preflight_option 1 "我先清理磁盘，然后重新检查（推荐）"
      preflight_option 2 "取消恢复"
      choice="$(preflight_choose 2 1)"
      [[ "$choice" == 1 ]] || return 1
      ;;
  esac
  return 0
}

# 运行预检，交互地处理问题，直到没有需要处理的问题。
# 返回 0 可以继续；返回 1 不能继续（失败原因已记录）。
# PREFLIGHT_NEED_BYTES、PREFLIGHT_CONTAINERS 会被设置，供阶段结果显示。
preflight_run() {
  local plan="$1" decisions="$2" base_dir="$3"
  local result asks stops i total row interactive=0 auto="${RESTORE_AUTO_RESOLVE:-0}" round=0
  local -A shown_infos=()
  [[ -s "$decisions" ]] || printf '{}\n' >"$decisions"
  if [[ -t 0 || -r /dev/tty ]] && [[ -t 2 ]]; then
    interactive=1
  fi
  while :; do
    round=$((round + 1))
    base_dir="$(jq -r --arg d "$base_dir" '.restore_base // $d' "$decisions")"
    if ! result="$(preflight_collect "$plan" "$decisions" "$base_dir" 2>>"${DM_LOG_FILE:-/dev/null}")"; then
      log_line "预检脚本运行失败，跳过预检"
      warn_user "预检没能完成，直接开始迁移（问题会在迁移过程中发现并自动回滚）"
      return 0
    fi
    log_line "预检结果（第 ${round} 轮）：${result}"
    # 供调用方在阶段结果中显示。
    export PREFLIGHT_NEED_BYTES PREFLIGHT_CONTAINERS
    PREFLIGHT_NEED_BYTES="$(jq -r '.summary.need_bytes // 0' <<<"$result")"
    PREFLIGHT_CONTAINERS="$(jq -r '.summary.containers // 0' <<<"$result")"
    while IFS= read -r row; do
      [[ -n "$row" && -z "${shown_infos[$row]:-}" ]] || continue
      shown_infos["$row"]=1
      warn_user "$row"
    done < <(jq -r '.issues[] | select(.level == "info") | .title' <<<"$result")

    stops="$(jq -c '[.issues[] | select(.level == "stop")]' <<<"$result")"
    if [[ "$(jq 'length' <<<"$stops")" -gt 0 ]]; then
      stage_hold
      printf '%s\n' "$(screen_color '1;31' '发现无法继续的问题，尚未下载或修改任何内容：')" >&2
      while IFS=$'\t' read -r row hint; do
        printf '  ✗ %s\n' "$row" >&2
        [[ -z "$hint" ]] || printf '    建议：%s\n' "$hint" >&2
      done < <(jq -r '.[] | [.title, .hint] | @tsv' <<<"$stops")
      fail_reason "$(jq -r '.[0].title' <<<"$stops")" "$(jq -r '.[0].hint' <<<"$stops")"
      return 1
    fi

    asks="$(jq -c '[.issues[] | select(.level == "ask")]' <<<"$result")"
    total="$(jq 'length' <<<"$asks")"
    ((total > 0)) || return 0

    if ((interactive == 0)) && [[ "$auto" != "1" ]]; then
      stage_hold
      printf '%s\n' "$(screen_color '1;33' "发现 ${total} 个需要处理的问题，尚未下载或修改任何内容：")" >&2
      while IFS=$'\t' read -r row hint; do
        printf '  ! %s\n' "$row" >&2
        [[ -z "$hint" ]] || printf '    建议：%s\n' "$hint" >&2
      done < <(jq -r '.[] | [.title, .hint] | @tsv' <<<"$asks")
      printf '处理后重新运行即可；也可以设置 RESTORE_AUTO_RESOLVE=1，自动采用推荐的处理方式（例如自动换一个空闲端口）。\n' >&2
      fail_reason "$(jq -r '.[0].title' <<<"$asks")" \
        "处理后重新运行；或设置 RESTORE_AUTO_RESOLVE=1 自动采用推荐做法（如自动换端口）"
      return 1
    fi

    if ((interactive == 1)) && [[ "$auto" != "1" ]]; then
      stage_hold
      printf '%s\n' "$(screen_color '1;33' "发现 ${total} 个需要处理的问题（尚未下载或修改任何内容）")" >&2
    fi
    for ((i = 0; i < total; i++)); do
      if ! preflight_resolve "$(jq -c ".[$i]" <<<"$asks")" "$decisions" "$((i + 1))" "$total" \
        "$([[ "$auto" == "1" ]] && echo 1 || echo 0)"; then
        fail_reason "$(jq -r ".[$i].title" <<<"$asks")" \
          "$([[ "$auto" == "1" ]] && echo "这个问题无法自动处理，请手动处理后重新运行" || echo "处理后重新粘贴同一个链接即可继续")"
        return 1
      fi
    done
    # 自动处理只做一轮：再次检查仍有问题时交给用户。
    if [[ "$auto" == "1" ]] && ((round >= 2)); then
      auto=0
      ((interactive == 1)) || {
        fail_reason "自动处理后仍有问题没有解决" "查看日志了解详情"
        return 1
      }
    fi
    printf '\n重新检查……\n' >&2
  done
}

# 恢复结果中列出预检时做的调整，让用户知道哪些地方和旧服务器不同。
print_decision_summary() {
  local decisions="${1:-}"
  [[ -n "$decisions" && -s "$decisions" ]] || return 0
  jq -r '
    ([.port_map[]? | if .new_port == "" then
        "不再对外开放：\(.container) 的端口 \(.host_port)"
      else "端口变更：\(.container) \(.host_port) → \(.new_port)" end]) +
    ([.skipped_reasons[]? | if .project then "⚠️ 未迁移：Compose 项目 \(.project)（\(.reason)）"
      else "⚠️ 未迁移：容器 \(.container)（\(.reason)）" end]) +
    ([.auto_ip[]? | "自动分配 IP：\(.container) 在网络 \(.network) 中"]) +
    ([.auto_subnet[]? | "自动选择网段：网络 \(.)"]) +
    ([.reuse_network[]? | "沿用新服务器已有网络：\(.)"]) +
    ([.keep_volumes[]? | "保留已有数据卷、未写入迁移数据：\(.)"]) | .[]' "$decisions" 2>/dev/null
  if jq -e '(.skipped_reasons // []) | any(.project)' "$decisions" >/dev/null 2>&1; then
    printf '   处理好之后，在新服务器重新粘贴同一个链接即可补上（旧服务器的传输服务需要仍在运行）。\n'
  fi
}

# 恢复决定：迁移前预检中用户（或 RESTORE_AUTO_RESOLVE）做出的选择，由
# DM_RESTORE_DECISIONS 指向的 JSON 文件传给恢复脚本与单容器恢复脚本。
# 没有这个文件时所有查询都返回“没有特别决定”，恢复按原配置进行。

decisions_present() {
  [[ -n "${DM_RESTORE_DECISIONS:-}" && -s "${DM_RESTORE_DECISIONS}" ]]
}

# decision_listed 列表名 值：值是否在决定文件的某个列表里（如 skip_projects）。
decision_listed() {
  decisions_present || return 1
  jq -e --arg k "$1" --arg v "$2" '(.[$k] // []) | index($v) != null' \
    "$DM_RESTORE_DECISIONS" >/dev/null 2>&1
}

# 容器在某个网络中是否改为自动分配 IP（单独选择、网段改为自动或沿用已有网络时都是）。
decision_auto_ip() {
  local container="$1" network="$2"
  decisions_present || return 1
  jq -e --arg c "$container" --arg n "$network" '(.auto_ip // []) | any(.container == $c and .network == $n)' \
    "$DM_RESTORE_DECISIONS" >/dev/null 2>&1 ||
    decision_listed auto_subnet "$network" || decision_listed reuse_network "$network"
}

# 端口映射的新宿主机端口；输出为空表示不再对外开放；没有调整时返回 1。
decision_port() {
  local container="$1" host_ip="$2" host_port="$3" container_port="$4" proto="$5"
  decisions_present || return 1
  jq -er --arg c "$container" --arg ip "$host_ip" --arg hp "$host_port" \
    --arg cp "$container_port" --arg proto "$proto" '
    [(.port_map // [])[] | select(.container == $c and .host_ip == $ip and .host_port == $hp and
      .container_port == $cp and .proto == $proto) | .new_port] | first // empty | tostring' \
    "$DM_RESTORE_DECISIONS" 2>/dev/null || {
    jq -e --arg c "$container" --arg ip "$host_ip" --arg hp "$host_port" \
      --arg cp "$container_port" --arg proto "$proto" '
      (.port_map // []) | any(.container == $c and .host_ip == $ip and .host_port == $hp and
        .container_port == $cp and .proto == $proto and .new_port == "")' \
      "$DM_RESTORE_DECISIONS" >/dev/null 2>&1 || return 1
    printf '\n'
  }
}

# 源端 HTTP 下载服务与对外地址探测。

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

get_public_ipv6() {
  local ip
  ip="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  if [[ "$ip" == *:* && "$ip" != fe80:* && "$ip" != fd* && "$ip" != fc* && "$ip" != ::1 ]]; then
    echo "$ip"
    return 0
  fi
  ip="$(curl -6 -fsS --max-time 2 https://api64.ipify.org 2>/dev/null | tr -d '\r\n' || true)"
  if [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:* ]]; then
    echo "$ip"
    return 0
  fi
  return 1
}

# URL 中的 IPv6 地址必须加方括号，否则端口会被当成地址的一部分。
url_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[* ]]; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
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
    # 纯 IPv6 服务器没有可用的 IPv4 地址。
    [[ -z "$host" ]] && host="$(get_public_ipv6 || true)"
    [[ -z "$host" ]] && host="$(ip -4 -o addr show 2>/dev/null | awk '!/ lo| docker| veth| br-| kube/ {print $4}' | cut -d/ -f1 | head -n1 || true)"
    if [[ -z "$host" ]]; then
      host="127.0.0.1"
      YEL "[WARN] 无法探测本机对外地址，链接暂用 127.0.0.1，新服务器无法访问；请用 ADVERTISE_HOST=公网IP或域名 重新运行。" >&2
    fi
  fi
  echo "http://$(url_host "$host"):${port}"
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

# 源端数据采集：共享挂载检测、卷与目录归档、停机与可写层快照。

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
      # 系统路径不迁移数据，共享它们的容器（如都挂载 /etc/localtime）无需停机。
      if [[ -n "$source" ]] && ! bind_path_is_system "$source"; then
        selected_binds+=("$(bind_resolve_source "$source")")
      fi
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
          bind_path_is_system "$source" && continue
          source="$(bind_resolve_source "$source")"
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

# 估算数据卷大小（字节），用于显示进度百分比；无法读取挂载点时输出 0。
volume_size_bytes() {
  local mountpoint
  mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$1" 2>/dev/null || true)"
  [[ -n "$mountpoint" && -d "$mountpoint" ]] || {
    echo 0
    return 0
  }
  path_size_bytes "$mountpoint"
}

path_size_bytes() {
  du -sk "$1" 2>/dev/null | awk '{ printf "%.0f\n", $1 * 1024 } END { if (NR == 0) print 0 }'
}

# count_file 非空时统计打包的原始字节数，供进度显示使用。
archive_volume_to_gzip() {
  local volume="$1" output="$2" count_file="${3:-/dev/null}" rc=0
  rm -f -- "$output"
  if docker run --rm -v "${volume}:/from:ro" alpine:3.20 \
    tar -C /from -cf - . 2>>"${DM_LOG_FILE:-/dev/null}" |
    progress_meter "$count_file" | gzip_compress_stream >"$output"; then
    return 0
  else
    rc=$?
  fi
  rm -f -- "$output"
  return "$rc"
}

archive_bind_to_gzip() {
  local source="$1" output="$2" count_file="${3:-/dev/null}" rc=0
  rm -f -- "$output"
  if tar -C / -cf - "${source#/}" 2>>"${DM_LOG_FILE:-/dev/null}" |
    progress_meter "$count_file" | gzip_compress_stream >"$output"; then
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

  DM_PROGRESS_HINT="容器正在处理退出信号，最长等待约 10 秒后会被强制停止" \
    run_with_activity "$label" dm_quiet docker stop "$@" || stop_rc=$?
  # Docker CLI 的聚合退出码无法指出具体失败项；以 daemon 的最终状态为准，
  # 同时逐个确认，避免部分停止后误以为已经取得一致性快照。
  for name in "$@"; do
    if ! running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)"; then
      log_line "停机后无法确认容器状态：$name"
      verify_rc=1
    elif [[ "$running" != "false" ]]; then
      log_line "容器仍在运行：$name"
      verify_rc=1
    fi
  done
  ((verify_rc == 0)) || return 1
  if ((stop_rc != 0)); then
    log_line "docker stop 返回异常，但已逐个确认所有目标容器停止"
  fi
  return 0
}

# 保存镜像到 images.tar，按镜像层总大小显示进度。
progress_docker_save() {
  local outfile="$1" total="$2"
  shift 2
  DM_PROGRESS_HINT="镜像较大时需要几分钟，请耐心等待" \
    run_with_progress "保存镜像" "$outfile" "$total" \
    progress_capture_stdout "$outfile" dm_logged "$@"
}

# 镜像大小之和，作为 docker save 输出大小的估算值。
images_total_bytes() {
  (($# > 0)) || {
    echo 0
    return 0
  }
  docker image inspect -f '{{.Size}}' "$@" 2>/dev/null | awk '{ s += $1 } END { printf "%.0f\n", s }'
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
  if ! dm_quiet "${commit_args[@]}" "$container_id" "$snapshot_image"; then
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

# docker diff 中是否有值得迁移的可写层改动。只列出因子项变化而被标记为
# C 的父目录、以及运行时临时目录，都不算改动。无法判断时保守地返回“有改动”。
container_writable_layer_changed() {
  local container_id="$1" diff_output
  diff_output="$(docker diff "$container_id" 2>/dev/null)" || return 0
  awk '
    NF >= 2 {
      kind[NR] = $1
      path = substr($0, index($0, " ") + 1)
      paths[NR] = path
      parent = path
      while (sub(/\/[^\/]*$/, "", parent) && parent != "") parents[parent] = 1
    }
    END {
      for (i in paths) {
        p = paths[i]
        if (kind[i] == "C" && (p in parents)) continue
        if (p ~ /^\/(tmp|var\/tmp|run|var\/run|var\/cache|root\/\.cache|dev|proc|sys)(\/|$)/) continue
        found = 1
        exit
      }
      exit found ? 0 : 1
    }
  ' <<<"$diff_output"
}

# 输出需要为容器创建可写层快照的原因；无需快照时输出为空。默认只在可写层
# 确有改动、或原镜像标签已指向别的版本时快照，其余容器保留原镜像名，便于
# 之后用 docker pull / compose pull / watchtower 正常升级。
# DOCKER_MIGRATE_SNAPSHOT=always 恢复旧行为；never 放弃可写层改动。
container_snapshot_reason() {
  local container_id="$1" metadata_file="$2" mode="${DOCKER_MIGRATE_SNAPSHOT:-auto}"
  local original_image container_image_id tag_id
  original_image="$(jq -r '.[0].Config.Image' "$metadata_file")"
  container_image_id="$(jq -r '.[0].Image // empty' "$metadata_file")"
  tag_id="$(docker image inspect -f '{{.Id}}' "$original_image" 2>/dev/null || true)"
  if [[ -z "$tag_id" || "$tag_id" != "$container_image_id" ]]; then
    printf '原镜像标签已不存在或指向其他版本\n'
    return 0
  fi
  case "$mode" in
    always)
      printf 'DOCKER_MIGRATE_SNAPSHOT=always\n'
      return 0
      ;;
    never) return 0 ;;
  esac
  if container_writable_layer_changed "$container_id"; then
    printf '可写层有改动\n'
  fi
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
    if dm_quiet docker image rm "$image"; then
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

# 运行日志：主脚本与生成的恢复脚本共用。
#
# 屏幕只显示阶段、进度、警告和最终结果；每一步的细节、执行的命令及其完整
# 输出都写进日志文件。成功后日志自动删除，失败时保留并在结果中给出路径，
# 方便用户反馈。子脚本（restore.sh、单容器恢复脚本）通过环境变量沿用父进程
# 的日志文件，由创建日志的进程负责收尾。
#
# DOCKER_MIGRATE_VERBOSE=1（或 --verbose）时，细节同时显示在屏幕上。
# DOCKER_MIGRATE_LOG_DIR 可指定日志目录，默认 ~/docker_migrate_logs。

# 写入日志前隐藏敏感信息：迁移链接中的密钥，以及 -e/--env 传入或形如
# *PASSWORD=*、*TOKEN=* 的环境变量值（容器配置里常有数据库密码）。
log_redact() {
  sed -E \
    -e 's/((secret|iv|mac)=)[0-9A-Fa-f]+/\1***/g' \
    -e 's/((^|[[:space:]])(-e|--env)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=)[^[:space:]]*/\1***/g' \
    -e 's/(--env=[A-Za-z_][A-Za-z0-9_]*=)[^[:space:]]*/\1***/g' \
    -e 's/([A-Za-z0-9_]*(PASS|PASSWD|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|pass|password|secret|token)[A-Za-z0-9_]*=)[^[:space:]"&]*/\1***/g'
}

log_timestamp() {
  date '+%H:%M:%S'
}

# 追加一行到日志（不显示在屏幕上）。
log_line() {
  [[ -n "${DM_LOG_FILE:-}" ]] || return 0
  printf '[%s] %s\n' "$(log_timestamp)" "$*" | log_redact >>"$DM_LOG_FILE" 2>/dev/null || true
}

# 细节信息：总是写入日志，--verbose 时也显示在屏幕上。
detail() {
  log_line "$*"
  if [[ "${DOCKER_MIGRATE_VERBOSE:-0}" == "1" ]]; then
    screen_clear_line
    printf '    %s\n' "$*" >&2
  fi
}

# 运行命令，把标准输出与错误输出都记进日志而不是丢弃；没有日志时保持静默。
# 命令失败时记录退出码，失败原因因此有据可查。
dm_quiet() {
  local rc=0
  if [[ -z "${DM_LOG_FILE:-}" ]]; then
    "$@" >/dev/null 2>&1 || rc=$?
    return "$rc"
  fi
  log_line "\$ $*"
  "$@" >>"$DM_LOG_FILE" 2>&1 || rc=$?
  ((rc == 0)) || log_line "  → 退出码 ${rc}"
  return "$rc"
}

# 只把错误输出记进日志，标准输出照常返回给调用方（用于需要捕获输出的命令）。
dm_logged() {
  local rc=0
  if [[ -z "${DM_LOG_FILE:-}" ]]; then
    "$@" 2>/dev/null || rc=$?
    return "$rc"
  fi
  log_line "\$ $*"
  "$@" 2>>"$DM_LOG_FILE" || rc=$?
  ((rc == 0)) || log_line "  → 退出码 ${rc}"
  return "$rc"
}

# 日志开头的环境信息：反馈问题时最常需要的版本与资源情况。
log_environment() {
  local kind="$1"
  shift
  printf '===== Docker Migrate %s · %s · %s =====\n' "${SCRIPT_VERSION:-unknown}" "$kind" "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf '参数：%s\n' "$*"
  printf '系统：%s\n' "$(uname -srm 2>/dev/null || echo unknown)"
  if [[ -r /etc/os-release ]]; then
    printf '发行版：%s\n' "$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}")"
  fi
  printf 'bash：%s\n' "${BASH_VERSION:-unknown}"
  printf '用户：uid=%s\n' "$(id -u 2>/dev/null || echo unknown)"
  printf 'Docker：%s\n' "$(docker version --format 'client {{.Client.Version}} / server {{.Server.Version}}' 2>&1 | head -n1)"
  printf 'Docker 存储：%s\n' "$(docker info --format '{{.Driver}} · {{.DockerRootDir}} · cgroup {{.CgroupVersion}}' 2>&1 | head -n1)"
  printf 'Compose：%s\n' "$({ docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null || echo '未安装'; } | head -n1)"
  printf '工具：jq %s · python3 %s · openssl %s\n' \
    "$(jq --version 2>/dev/null || echo '未安装')" \
    "$(python3 --version 2>/dev/null | awk '{print $2}' || true)" \
    "$(openssl version 2>/dev/null | awk '{print $2}' || true)"
  printf '磁盘：\n'
  df -h "$PWD" "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | sed 's/^/  /' || true
  printf '%s\n' '=================================================='
}

# 创建日志文件；子进程已从父进程继承日志时直接沿用。
log_init() {
  local kind="$1" dir
  shift
  if [[ -n "${DM_LOG_FILE:-}" && -f "${DM_LOG_FILE}" ]]; then
    return 0
  fi
  dir="${DOCKER_MIGRATE_LOG_DIR:-${HOME:-/tmp}/docker_migrate_logs}"
  if ! mkdir -p "$dir" 2>/dev/null; then
    dir="${TMPDIR:-/tmp}"
  fi
  chmod 700 "$dir" 2>/dev/null || true
  DM_LOG_FILE="${dir}/${kind}-$(date +%Y%m%d-%H%M%S)-$$.log"
  if ! : >"$DM_LOG_FILE" 2>/dev/null; then
    DM_LOG_FILE=""
    return 0
  fi
  chmod 600 "$DM_LOG_FILE" 2>/dev/null || true
  DM_LOG_OWNER="$$"
  DM_REASON_FILE="${DM_LOG_FILE%.log}.reason"
  DM_WARN_FILE="${DM_LOG_FILE%.log}.warnings"
  DM_TIMING_FILE="${DM_LOG_FILE%.log}.timings"
  : >"$DM_REASON_FILE" 2>/dev/null || true
  : >"$DM_WARN_FILE" 2>/dev/null || true
  : >"$DM_TIMING_FILE" 2>/dev/null || true
  export DM_LOG_FILE DM_LOG_OWNER DM_REASON_FILE DM_WARN_FILE DM_TIMING_FILE
  log_environment "$kind" "$@" 2>&1 | log_redact >>"$DM_LOG_FILE" 2>/dev/null || true
}

# 创建日志的进程在结束时调用：成功则删除日志及附属文件，失败则保留。
log_finish() {
  local success="$1"
  [[ -n "${DM_LOG_FILE:-}" && "${DM_LOG_OWNER:-}" == "$$" ]] || return 0
  # DOCKER_MIGRATE_KEEP_LOG=1 时成功也保留日志，便于排查或测试。
  [[ "${DOCKER_MIGRATE_KEEP_LOG:-0}" != "1" ]] || success=0
  if [[ "$success" == "1" ]]; then
    rm -f "$DM_LOG_FILE" "${DM_REASON_FILE:-}" "${DM_WARN_FILE:-}" "${DM_TIMING_FILE:-}" 2>/dev/null || true
    rmdir "$(dirname "$DM_LOG_FILE")" 2>/dev/null || true
  else
    rm -f "${DM_WARN_FILE:-}" "${DM_TIMING_FILE:-}" 2>/dev/null || true
  fi
}

# 记录本次失败的原因与建议；只保留第一条，它通常就是根因。
fail_reason() {
  local reason="$1" hint="${2:-}"
  log_line "失败原因：${reason}${hint:+（建议：${hint}）}"
  [[ -n "${DM_REASON_FILE:-}" ]] || return 0
  if [[ ! -s "$DM_REASON_FILE" ]]; then
    printf '%s\t%s\n' "$reason" "$hint" >"$DM_REASON_FILE" 2>/dev/null || true
  fi
}

# 读取已记录的失败原因，输出“原因<TAB>建议”。
fail_reason_read() {
  [[ -n "${DM_REASON_FILE:-}" && -s "$DM_REASON_FILE" ]] || return 1
  head -n1 "$DM_REASON_FILE"
}

# 屏幕输出：分阶段显示整体进度。主脚本与生成的恢复脚本共用。
#
# 每个阶段在屏幕上只占一行：进行中时由进度显示原地刷新这一行，完成后
# 替换为“✓ 结果 · 耗时”。警告单独占一行并汇总到最终结果；细节只写日志。
# 阶段信息通过环境变量传给子脚本，让它们的进度行带上同一个阶段前缀。

screen_is_tty() {
  [[ -t 2 ]]
}

screen_clear_line() {
  screen_is_tty || return 0
  printf '\r\033[K' >&2
}

screen_color() {
  local code="$1"
  shift
  if screen_is_tty; then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}

# 当前阶段的前缀，例如“[5/7] 保存镜像”；不在任何阶段内时为空。
stage_prefix() {
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  printf '[%s/%s] %s' "${DM_STAGE_NUM:-?}" "${DM_STAGE_TOTAL:-?}" "$DM_STAGE_TITLE"
}

# 进度行开头：阶段前缀加上正在处理的对象。
stage_label() {
  local label="${1:-}" prefix
  prefix="$(stage_prefix)"
  # 子步骤与阶段同名时不重复显示。
  [[ "$label" != "${DM_STAGE_TITLE:-}" ]] || label=""
  if [[ -n "$prefix" && -n "$label" ]]; then
    printf '%s · %s' "$prefix" "$label"
  else
    printf '%s' "${prefix}${label}"
  fi
}

stage_begin() {
  DM_STAGE_NUM="$1"
  DM_STAGE_TOTAL="$2"
  DM_STAGE_TITLE="$3"
  DM_STAGE_STARTED=$SECONDS
  export DM_STAGE_NUM DM_STAGE_TOTAL DM_STAGE_TITLE
  log_line "===== [${DM_STAGE_NUM}/${DM_STAGE_TOTAL}] ${DM_STAGE_TITLE} ====="
  if screen_is_tty; then
    printf '\r%s\033[K' "$(stage_prefix) …" >&2
  else
    printf '%s\n' "$(stage_prefix)" >&2
  fi
}

# 阶段内需要提问或列出菜单时，先把阶段标题固定成一整行。
stage_hold() {
  screen_is_tty || return 0
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  printf '\r%s\033[K\n' "$(stage_prefix)" >&2
}

stage_record_timing() {
  local elapsed="$1"
  [[ -n "${DM_TIMING_FILE:-}" && -n "${DM_STAGE_TITLE:-}" ]] || return 0
  printf '%s\t%s\n' "$DM_STAGE_TITLE" "$elapsed" >>"$DM_TIMING_FILE" 2>/dev/null || true
}

stage_end() {
  local summary="${1:-}" elapsed
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  elapsed=$((SECONDS - ${DM_STAGE_STARTED:-$SECONDS}))
  stage_record_timing "$elapsed"
  log_line "完成：$(stage_prefix)${summary:+ · ${summary}} · $(format_elapsed "$elapsed")"
  screen_clear_line
  printf '%s %s %s%s\n' "$(stage_prefix)" "$(screen_color '1;32' '✓')" \
    "${summary:+${summary} · }" "$(format_elapsed "$elapsed")" >&2
  DM_STAGE_TITLE=""
  export DM_STAGE_TITLE
}

stage_fail() {
  local elapsed
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  elapsed=$((SECONDS - ${DM_STAGE_STARTED:-$SECONDS}))
  stage_record_timing "$elapsed"
  log_line "失败：$(stage_prefix)"
  screen_clear_line
  printf '%s %s\n' "$(stage_prefix)" "$(screen_color '1;31' '✗')" >&2
  DM_FAILED_STAGE="$(stage_prefix)"
  export DM_FAILED_STAGE
  DM_STAGE_TITLE=""
  export DM_STAGE_TITLE
}

# 警告：屏幕上单独一行，写入日志，并在最终结果中汇总。
warn_user() {
  log_line "警告：$*"
  screen_clear_line
  printf '    %s %s\n' "$(screen_color '1;33' '!')" "$*" >&2
  if [[ -n "${DM_WARN_FILE:-}" ]]; then
    printf '%s\n' "$*" >>"$DM_WARN_FILE" 2>/dev/null || true
  fi
}

# 错误：写入日志并记录为失败原因；屏幕上的完整说明由最终结果统一给出。
error_user() {
  local reason="$1" hint="${2:-}"
  fail_reason "$reason" "$hint"
  if [[ "${DM_SUMMARY_ARMED:-0}" != "1" ]]; then
    screen_clear_line
    printf '%s %s\n' "$(screen_color '1;31' '✗')" "$reason" >&2
    [[ -z "$hint" ]] || printf '  建议：%s\n' "$hint" >&2
  fi
}

# 最终结果中的“阶段耗时”与“警告”部分。
print_stage_timings() {
  local title seconds line=""
  [[ -n "${DM_TIMING_FILE:-}" && -s "$DM_TIMING_FILE" ]] || return 0
  while IFS=$'\t' read -r title seconds; do
    [[ -n "$title" ]] || continue
    line+="${line:+ · }${title} $(format_elapsed "$seconds")"
  done <"$DM_TIMING_FILE"
  [[ -z "$line" ]] || printf '阶段耗时：%s\n' "$line"
}

print_warning_summary() {
  local warning count
  [[ -n "${DM_WARN_FILE:-}" && -s "$DM_WARN_FILE" ]] || return 0
  count="$(awk 'NF' "$DM_WARN_FILE" | wc -l | tr -d ' ')"
  printf '警告：%s 条\n' "$count"
  while IFS= read -r warning; do
    [[ -n "$warning" ]] || continue
    printf '  · %s\n' "$warning"
  done < <(awk 'NF && !seen[$0]++' "$DM_WARN_FILE" | head -n 10)
}

# 失败时的说明：原因、建议、日志位置与最近的日志内容。
print_failure_details() {
  local reason hint row
  if row="$(fail_reason_read)"; then
    IFS=$'\t' read -r reason hint <<<"$row"
    [[ -z "$reason" ]] || printf '原因：%s\n' "$reason"
    [[ -z "$hint" ]] || printf '建议：%s\n' "$hint"
  fi
  if [[ -n "${DM_LOG_FILE:-}" && -f "$DM_LOG_FILE" ]]; then
    printf '日志：%s\n' "$DM_LOG_FILE"
    printf '      反馈问题时请附上这个文件（密钥与密码已自动隐藏），或运行 --diagnose 生成诊断包。\n'
    printf '最近日志：\n'
    tail -n 15 "$DM_LOG_FILE" | sed 's/^/  /'
  fi
}

# 常见错误识别：把 Docker、curl 等工具的英文报错翻译成“原因 + 建议”。
# 主脚本与生成的恢复脚本共用。

# 根据错误文本输出“原因<TAB>建议”；无法识别时返回 1。
explain_error() {
  local text="$1" port
  shopt -s nocasematch
  case "$text" in
    *"port is already allocated"* | *"address already in use"* | *"failed to bind host port"* | *"Bind for "*" failed"*)
      port="$(grep -oE '(Bind for [^ ]*:|host port |0\.0\.0\.0:|\]:)[0-9]+' <<<"$text" | grep -oE '[0-9]+$' | head -n1 || true)"
      printf '宿主机端口%s已被其他程序占用\t执行 ss -lntp%s 查看占用的进程，停止它或修改端口后重试\n' \
        "${port:+ ${port} }" "${port:+ | grep \":${port} \"}"
      ;;
    *"no space left on device"*)
      printf '磁盘空间不足\t执行 df -h 查看剩余空间，清理后重试（docker system prune 可以清理无用的镜像和容器）\n'
      ;;
    *"permission denied while trying to connect to the docker"*)
      printf '当前用户没有访问 Docker 的权限\t请用 root 运行，或用 sudo 运行脚本\n'
      ;;
    *"cannot connect to the docker daemon"* | *"is the docker daemon running"*)
      printf 'Docker 服务没有运行\t执行 systemctl start docker 启动 Docker 后重试\n'
      ;;
    *"exec format error"* | *"does not match the detected host platform"* | *"no matching manifest for"*)
      printf '镜像的 CPU 架构与本机不一致\t请在相同 CPU 架构（如都是 x86_64 或都是 arm64）的服务器之间迁移\n'
      ;;
    *"pull access denied"* | *"repository does not exist"* | *"manifest unknown"* | *"not found: manifest"*)
      printf '镜像仓库中找不到该镜像，或需要登录才能拉取\t检查镜像名；私有镜像请先执行 docker login\n'
      ;;
    *"tls handshake timeout"* | *"i/o timeout"* | *"client.timeout exceeded"* | *"request canceled while waiting"*)
      printf '连接镜像仓库超时\t检查服务器网络，或为 Docker 配置可用的镜像加速地址后重试\n'
      ;;
    *"is already in use by container"*)
      printf '容器名称已被其他容器占用\t删除或重命名同名容器，或设置 RESTORE_EXISTING=replace\n'
      ;;
    *"bind source path does not exist"* | *"invalid mount config"*)
      printf '挂载的宿主机路径不存在\t确认该路径在本机存在后重试\n'
      ;;
    *"could not resolve host"*)
      printf '无法解析链接中的主机名\t检查链接是否完整、DNS 是否可用\n'
      ;;
    *"failed to connect"* | *"connection refused"* | *"couldn't connect to server"*)
      printf '无法连接旧服务器的下载服务\t确认旧服务器上的脚本仍在运行，并检查旧服务器防火墙和云厂商安全组是否放行了下载端口\n'
      ;;
    *"unhealthy"* | *"did not become healthy"* | *"healthcheck timed out"*)
      printf '容器启动后健康检查没有通过\t执行 docker logs <容器名> 查看应用日志；启动较慢的服务可以调大 RESTORE_HEALTH_TIMEOUT\n'
      ;;
    *"timed out"* | *"connection reset"*)
      printf '与旧服务器的连接超时或中断\t检查两台服务器之间的网络，以及旧服务器防火墙和安全组设置，然后重试\n'
      ;;
    *"returned error: 404"* | *"404 not found"*)
      printf '下载地址不存在\t旧服务器可能已经结束传输，或链接没有完整复制；请在旧服务器重新运行备份\n'
      ;;
    *"did not remain running"*)
      printf '容器启动后立即退出\t执行 docker logs <容器名> 查看应用日志\n'
      ;;
    *"operation not permitted"* | *"permission denied"*)
      printf '权限不足\t请用 root 或 sudo 运行脚本\n'
      ;;
    *)
      shopt -u nocasematch
      return 1
      ;;
  esac
  shopt -u nocasematch
}

# 记录失败原因：能识别的报错给出具体原因和建议，否则使用调用方给出的描述。
fail_with_output() {
  local fallback="$1" output="${2:-}" row reason hint
  if [[ -n "$output" ]] && row="$(explain_error "$output")"; then
    IFS=$'\t' read -r reason hint <<<"$row"
    error_user "${fallback}：${reason}" "$hint"
  else
    error_user "$fallback" "${3:-查看下方日志中的最后几行了解详情}"
  fi
}

# 日志末尾的报错文本，用于在命令失败后识别原因。
log_tail_text() {
  [[ -n "${DM_LOG_FILE:-}" && -f "$DM_LOG_FILE" ]] || return 0
  tail -n "${1:-30}" "$DM_LOG_FILE" 2>/dev/null || true
}

# 进度显示与耗时格式化：主脚本与生成的恢复脚本共用。
#
# 耗时操作统一通过 run_with_progress 执行，后台 watcher 每秒（非终端每 10 秒）
# 刷新一行：
#   知道总量时：[5/7] 保存镜像 ██████░░░░ 58% · 1.2GB/2.1GB · 45MB/s · 剩余约 20 秒
#   不知道总量：[4/7] 停机并打包数据 · 卷 mysql_data ⠹ 已处理 1.2GB · 45MB/s · 1 分 3 秒
#   没有字节数：[7/8] 启动服务 · nginx ⠹ 1 分 3 秒
# 长时间没有进展时追加说明（DM_PROGRESS_HINT），让用户知道程序仍在运行、在等什么。

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

# 1536 → 1.5KB；整数部分达到两位后不再保留小数。
human() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1 || b >= 10) printf "%d%s\n", b, u[i]
    else {
      s = sprintf("%.1f", b)
      sub(/\.0$/, "", s)
      printf "%s%s\n", s, u[i]
    }
  }'
}

progress_file_size() {
  local file="$1"
  stat -c %s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0
}

# 当前已处理字节数。spec 为空时没有字节数；"count:路径" 读取计数文件
# （由 progress_meter 写入）；其他情况视为正在增长的输出文件。
progress_current() {
  local spec="${1:-}" value
  case "$spec" in
    "") echo 0 ;;
    count:*)
      value="$(cat "${spec#count:}" 2>/dev/null || true)"
      [[ "$value" =~ ^[0-9]+$ ]] || value=0
      echo "$value"
      ;;
    *) progress_file_size "$spec" ;;
  esac
}

# 总字节数。可以是数字，也可以是 "header:路径"：从 curl -D 写出的响应头中
# 读取 Content-Length（下载开始前未知，开始后才能确定）。
progress_total() {
  local spec="${1:-0}" value
  case "$spec" in
    header:*)
      value="$(tr -d '\r' <"${spec#header:}" 2>/dev/null |
        awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }')"
      ;;
    *) value="$spec" ;;
  esac
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  echo "$value"
}

# 在管道中计数：原样转发标准输入到标准输出，并把累计字节数写入计数文件。
# 没有 python3 时退化为 cat（只是不显示字节数）。
progress_meter() {
  local count_file="${1:-}"
  if [[ -z "$count_file" || "$count_file" == /dev/null ]] || ! command -v python3 >/dev/null 2>&1; then
    cat
    return
  fi
  python3 -c '
import os, sys, time
path = sys.argv[1]
src, dst = sys.stdin.buffer, sys.stdout.buffer
total, last = 0, 0.0
def flush():
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(total))
    os.replace(tmp, path)
while True:
    chunk = src.read(1024 * 1024)
    if not chunk:
        break
    dst.write(chunk)
    total += len(chunk)
    now = time.monotonic()
    if now - last >= 0.5:
        flush()
        last = now
dst.flush()
flush()
' "$count_file"
}

progress_bar() {
  local percent="$1" width=20 filled bar empty
  filled=$((percent * width / 100))
  printf -v bar '%*s' "$filled" ''
  printf -v empty '%*s' "$((width - filled))" ''
  printf '%s%s' "${bar// /█}" "${empty// /░}"
}

# 生成一行进度文字（不含换行）。保持纯函数，便于单元测试。
#   label current total elapsed [rate 字节/秒] [spinner] [hint]
# 只在确实知道总量时显示百分比，避免用“假进度条”误导用户。
progress_render() {
  local label="$1" current="${2:-0}" total="${3:-0}" elapsed="${4:-0}"
  local rate="${5:-0}" spinner="${6:-}" hint="${7:-}"
  local percent line remaining
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0
  [[ "$rate" =~ ^[0-9]+$ ]] || rate=0
  if ((total > 0)); then
    ((current <= total)) || current=$total
    percent=$((current * 100 / total))
    # 总量是估算值时，在命令真正结束前不显示 100%。
    ((percent < 100)) || percent=99
    line="${label} $(progress_bar "$percent") ${percent}% · $(human "$current")/$(human "$total")"
    ((rate == 0)) || line+=" · $(human "$rate")/s"
    if ((rate > 0 && total > current)); then
      remaining=$(((total - current) / rate))
      if ((remaining > 0)); then
        line+=" · 剩余约 $(format_elapsed "$remaining")"
      else
        line+=" · 即将完成"
      fi
    else
      line+=" · $(format_elapsed "$elapsed")"
    fi
  elif ((current > 0)); then
    line="${label}${spinner:+ ${spinner}} 已处理 $(human "$current")"
    ((rate == 0)) || line+=" · $(human "$rate")/s"
    line+=" · $(format_elapsed "$elapsed")"
  else
    line="${label}${spinner:+ ${spinner}} $(format_elapsed "$elapsed")"
  fi
  [[ -z "$hint" ]] || line+=" · ${hint}"
  printf '%s' "$line"
}

progress_tty_draw() {
  # 用一次写入覆盖旧内容，再清除新内容右侧的残留；不要先输出一整行空格，
  # 否则 SSH 或刷新较慢的终端会把中间空帧显示成闪烁。
  printf '\r%s\033[K' "$1" >&2
}

progress_tty_clear() {
  printf '\r\033[K' >&2
}

# 命令失败只记日志：失败原因由阶段结果与最终结果统一说明，避免屏幕上重复报错。
progress_finish() {
  local label="$1" rc="$2" elapsed="$3" current="${4:-0}"
  ((rc != 0)) || return 0
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  log_line "失败：${label}（退出码 ${rc}，耗时 $(format_elapsed "$elapsed")$( ((current == 0)) || printf '，已处理 %s' "$(human "$current")")）"
}

# 逐个处理对象时（如扫描容器）在阶段行里显示“第几个/共几个”。
progress_count() {
  local label="$1" current="$2" total="$3" item="${4:-}"
  local line
  printf -v line '%s %d/%d%s' "$label" "$current" "$total" "${item:+（${item}）}"
  if [[ -t 2 ]]; then
    progress_tty_draw "$(stage_label "$line")"
  elif ((current == total || current % 20 == 0)); then
    printf '[进度] %s\n' "$(stage_label "$line")" >&2
  fi
}

# 不在 run_with_progress 中的等待循环（如健康检查）用它刷新阶段行。
# 非终端时每 10 秒最多输出一行，避免刷屏。
progress_note() {
  local text="$1" now=$SECONDS
  if [[ -t 2 ]]; then
    progress_tty_draw "$(stage_label "$text")"
  elif ((now - ${DM_LAST_NOTE_AT:--100} >= 10)); then
    DM_LAST_NOTE_AT=$now
    printf '[进度] %s\n' "$(stage_label "$text")" >&2
  fi
}

progress_watch() {
  local label="$1" spec="$2" total_spec="$3" started="$4" owner_pid="$5"
  local mode="${DOCKER_MIGRATE_PROGRESS_MODE:-auto}" interval current total elapsed line timer_pid=""
  local last_bytes=0 last_time=$SECONDS rate=0 sample changed_at=$SECONDS hint="" tick=0
  local stall="${DM_PROGRESS_STALL:-30}" spinner
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  [[ "$mode" != "plain" && "$mode" != "off" ]] || return 0
  if [[ -n "${DOCKER_MIGRATE_PROGRESS_INTERVAL:-}" ]]; then
    interval="$DOCKER_MIGRATE_PROGRESS_INTERVAL"
  elif [[ -t 2 ]]; then
    interval=1
  else
    interval=10
  fi
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=10
  [[ "$stall" =~ ^[1-9][0-9]*$ ]] || stall=30
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
    current="$(progress_current "$spec")"
    total="$(progress_total "$total_spec")"
    elapsed=$((SECONDS - started))
    # 速度取指数平滑，避免网络抖动时数字跳得太厉害。
    if ((SECONDS > last_time)); then
      sample=$(((current - last_bytes) / (SECONDS - last_time)))
      ((sample >= 0)) || sample=0
      if ((rate == 0)); then rate=$sample; else rate=$(((rate * 7 + sample * 3) / 10)); fi
    fi
    ((current == last_bytes)) || changed_at=$SECONDS
    last_bytes=$current
    last_time=$SECONDS
    hint=""
    if ((SECONDS - changed_at >= stall)); then
      hint="${DM_PROGRESS_HINT:-仍在进行，请耐心等待}"
    fi
    spinner="${frames[$((tick % 10))]}"
    tick=$((tick + 1))
    if [[ -t 2 ]]; then
      line="$(progress_render "$(stage_label "$label")" "$current" "$total" "$elapsed" "$rate" "$spinner" "$hint")"
      progress_tty_draw "$line"
    else
      printf '[进度] %s\n' "$(progress_render "$(stage_label "$label")" "$current" "$total" "$elapsed" "$rate" "" "$hint")" >&2
    fi
  done
  trap - TERM INT HUP
}

# 运行命令并显示进度。spec/total 的含义见 progress_current / progress_total。
run_with_progress() {
  local label="$1" spec="$2" total="$3"
  shift 3
  local started=$SECONDS watcher_pid rc current=0 restore_errexit=0
  log_line "开始：${label}"
  case $- in *e*) restore_errexit=1 ;; esac
  progress_watch "$label" "$spec" "$total" "$started" "$$" &
  watcher_pid=$!
  set +e
  "$@"
  rc=$?
  ((restore_errexit == 0)) || set -e
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  if [[ -t 2 ]]; then
    # 回到阶段行，不留下已完成子步骤的进度文字。
    if [[ -n "${DM_STAGE_TITLE:-}" ]]; then
      progress_tty_draw "$(stage_prefix) …"
    else
      progress_tty_clear
    fi
  fi
  current="$(progress_current "$spec")"
  progress_finish "$label" "$rc" "$((SECONDS - started))" "$current"
  ((rc != 0)) || log_line "完成：${label} · $(format_elapsed "$((SECONDS - started))")$( ((current == 0)) || printf ' · %s' "$(human "$current")")"
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

# 容器改名与网络重连：单容器恢复脚本与恢复事务共用，供失败时还原旧容器。

rename_container_with_retry() {
  local old_name="$1" new_name="$2"
  for _ in {1..20}; do
    if dm_quiet docker rename "$old_name" "$new_name"; then
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
      dm_quiet docker network connect "$network" "$container" || return 1
      continue
    fi
    ip="$(jq -r '.value.IPAMConfig.IPv4Address // empty' <<<"$entry")"
    ip6="$(jq -r '.value.IPAMConfig.IPv6Address // empty' <<<"$entry")"
    [[ -z "$ip" ]] || connect_args+=(--ip "$ip")
    [[ -z "$ip6" ]] || connect_args+=(--ip6 "$ip6")
    while IFS= read -r alias; do
      [[ -z "$alias" ]] || connect_args+=(--alias "$alias")
    done < <(jq -r '.value.Aliases[]? // empty' <<<"$entry")
    dm_quiet docker network connect "${connect_args[@]}" "$network" "$container" || return 1
  done < <(jq -c 'to_entries[]?' "$metadata_file")
}

# Compose 在 com.docker.compose.project.config_files 标签里用逗号连接多个配置
# 文件（-f a.yml -f b.yml）。没有逗号时兼容按冒号分隔的旧写法（COMPOSE_FILE）。
compose_config_files_split() {
  local raw="$1" sep=","
  [[ -n "$raw" ]] || return 0
  [[ "$raw" == *,* ]] || sep=":"
  local -a parts=()
  IFS="$sep" read -r -a parts <<<"$raw"
  printf '%s\n' "${parts[@]}" | awk 'NF'
}

# 等待健康检查的最长时间：至少是 RESTORE_HEALTH_TIMEOUT（默认 60 秒），并且要
# 够容器自己的健康检查跑完第一次。有的镜像每 60 秒才检查一次（如 Vaultwarden），
# 固定等 60 秒会在第一次检查出结果之前就判定超时。
health_wait_seconds() {
  local base="${1:-60}" needed
  shift
  (($# > 0)) || {
    printf '%s\n' "$base"
    return 0
  }
  needed="$(docker inspect "$@" 2>/dev/null | jq '[.[] | .Config.Healthcheck // empty |
    select((.Test[0] // "") != "NONE") |
    ((.StartPeriod // 0) + (if (.Interval // 0) > 0 then .Interval else 30000000000 end) +
      (if (.Timeout // 0) > 0 then .Timeout else 30000000000 end)) / 1000000000 + 30 | floor] |
    max // 0' 2>/dev/null || echo 0)"
  [[ "$needed" =~ ^[0-9]+$ ]] || needed=0
  ((needed > base)) || needed="$base"
  ((needed <= 3600)) || needed=3600
  printf '%s\n' "$needed"
}

# 恢复决定：迁移前预检中用户（或 RESTORE_AUTO_RESOLVE）做出的选择，由
# DM_RESTORE_DECISIONS 指向的 JSON 文件传给恢复脚本与单容器恢复脚本。
# 没有这个文件时所有查询都返回“没有特别决定”，恢复按原配置进行。

decisions_present() {
  [[ -n "${DM_RESTORE_DECISIONS:-}" && -s "${DM_RESTORE_DECISIONS}" ]]
}

# decision_listed 列表名 值：值是否在决定文件的某个列表里（如 skip_projects）。
decision_listed() {
  decisions_present || return 1
  jq -e --arg k "$1" --arg v "$2" '(.[$k] // []) | index($v) != null' \
    "$DM_RESTORE_DECISIONS" >/dev/null 2>&1
}

# 容器在某个网络中是否改为自动分配 IP（单独选择、网段改为自动或沿用已有网络时都是）。
decision_auto_ip() {
  local container="$1" network="$2"
  decisions_present || return 1
  jq -e --arg c "$container" --arg n "$network" '(.auto_ip // []) | any(.container == $c and .network == $n)' \
    "$DM_RESTORE_DECISIONS" >/dev/null 2>&1 ||
    decision_listed auto_subnet "$network" || decision_listed reuse_network "$network"
}

# 端口映射的新宿主机端口；输出为空表示不再对外开放；没有调整时返回 1。
decision_port() {
  local container="$1" host_ip="$2" host_port="$3" container_port="$4" proto="$5"
  decisions_present || return 1
  jq -er --arg c "$container" --arg ip "$host_ip" --arg hp "$host_port" \
    --arg cp "$container_port" --arg proto "$proto" '
    [(.port_map // [])[] | select(.container == $c and .host_ip == $ip and .host_port == $hp and
      .container_port == $cp and .proto == $proto) | .new_port] | first // empty | tostring' \
    "$DM_RESTORE_DECISIONS" 2>/dev/null || {
    jq -e --arg c "$container" --arg ip "$host_ip" --arg hp "$host_port" \
      --arg cp "$container_port" --arg proto "$proto" '
      (.port_map // []) | any(.container == $c and .host_ip == $ip and .host_port == $hp and
        .container_port == $cp and .proto == $proto and .new_port == "")' \
      "$DM_RESTORE_DECISIONS" >/dev/null 2>&1 || return 1
    printf '\n'
  }
}

dm_capture_command() {
  local output_file="$1"
  shift
  "$@" >"$output_file" 2>&1
}

if [[ ! -f "$META" ]]; then
  error_user "迁移包缺少容器 __NAME__ 的配置文件" "请在旧服务器重新运行备份"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  error_user "恢复容器 __NAME__ 需要 jq" "安装 jq 后重试"
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
  log_line "依附的容器 ${ref:0:12} 不在迁移包中"
  fail_reason "依附的容器 ${ref:0:12} 不在迁移包中" "请在旧服务器把它和依附它的容器一起迁移"
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
  error_user "容器 __NAME__ 的配置文件无效" "请在旧服务器重新运行备份"
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

disconnect_container_networks() {
  local container="$1" metadata_file="$2" network
  while IFS= read -r network; do
    case "$network" in "" | host | none) continue ;; esac
    dm_quiet docker network disconnect -f "$network" "$container" || return 1
  done < <(jq -r 'keys[]?' "$metadata_file")
}

restore_previous_container() {
  ((replacement_active == 1)) || return 0
  log_line "新容器 ${name} 未能通过验证，删除它并还原旧容器"
  dm_quiet docker rm -f "$name" || true
  if ((transaction_mode == 1)); then
    # 数据必须先由主恢复脚本回滚；旧容器在那之后才会改回原名并恢复状态。
    replacement_active=0
    return 0
  fi
  if ! rename_container_with_retry "$replacement_backup_name" "$name"; then
    warn_user "旧容器自动还原失败，它目前的名称是 ${replacement_backup_name}"
    return 1
  fi
  if ! restore_container_networks "$name" "$replacement_networks_file"; then
    warn_user "旧容器 ${name} 已改回原名，但网络没有完全重新连接"
    return 1
  fi
  case "$replacement_original_state" in
    running | restarting)
      dm_quiet docker start "$name" || return 1
      ;;
    paused)
      dm_quiet docker start "$name" || return 1
      dm_quiet docker pause "$name" || return 1
      ;;
  esac
  replacement_active=0
  log_line "旧容器已还原：${name}"
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
  detail "镜像 ${image} 不在本机，先在线拉取（此时还没有改动已有容器）"
  DM_PROGRESS_HINT="正在从镜像仓库下载，网络较慢时可能需要几分钟" \
    run_with_activity "拉取镜像 ${image}" dm_quiet docker pull "$image" || {
    fail_with_output "容器 ${name} 的镜像 ${image} 拉取失败（已有容器保持不变）" "$(log_tail_text 10)"
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
      detail "新服务器已有同名容器 ${name}，替换它以恢复完整配置（失败时会还原）"
      replacement_original_state="$existing_state"
      replacement_backup_name="${name}.docker-migrate-backup-$$"
      if docker container inspect "$replacement_backup_name" >/dev/null 2>&1; then
        error_user "回滚用的容器名 ${replacement_backup_name} 已被占用" "删除或重命名这个容器后重试"
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
        error_user "无法记录已有容器 ${name} 的网络配置（已有容器保持不变）"
        exit 1
      fi
      if ((transaction_mode == 1)); then
        # Write-ahead：旧容器 rename 前先登记回滚名称；登记失败时尚未改动目标。
        printf '%s\t%s\t%s\n' "$name" "$replacement_backup_name" "$replacement_original_state" \
          >>"${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv" || exit 1
      fi
      [[ "$existing_state" == "paused" ]] && dm_quiet docker unpause "$name" || true
      case "$existing_state" in
        running | restarting | paused)
          run_with_activity "停止已有容器 ${name}" dm_quiet docker stop "$name" || {
            fail_with_output "无法停止已有容器 ${name}（它保持不变）" "$(log_tail_text 10)"
            exit 1
          }
          ;;
      esac
      dm_quiet docker rename "$name" "$replacement_backup_name" || {
        fail_with_output "无法先备份已有容器 ${name}（它保持不变）" "$(log_tail_text 10)"
        exit 1
      }
      replacement_active=1
      if ! disconnect_container_networks "$replacement_backup_name" "$replacement_networks_file"; then
        fail_with_output "无法释放已有容器 ${name} 占用的网络地址" "$(log_tail_text 10)"
        exit 1
      fi
      ;;
    skip)
      warn_user "容器 ${name} 已存在，按 RESTORE_EXISTING=skip 保持不变"
      exit 0
      ;;
    fail)
      error_user "容器 ${name} 已存在（RESTORE_EXISTING=fail 不允许替换）" "删除这个容器，或改用 RESTORE_EXISTING=replace"
      exit 1
      ;;
    *)
      error_user "RESTORE_EXISTING 的值无效：${RESTORE_EXISTING}" "可用的值是 replace、skip 或 fail"
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
# docker run --entrypoint 只能写一段：多段的入口（如 dumb-init -- entrypoint.sh）
# 会被拆进命令里，配置就和原来不一样了，镜像更新后命令也会被固定住。
# 和镜像默认值相同的部分不传，由镜像自己提供。
image_entry_cmd="$(docker image inspect "$image" 2>/dev/null |
  jq -c '.[0].Config | [.Entrypoint // [], .Cmd // []]' 2>/dev/null || echo null)"
container_entry_cmd="$(jq -c '.[0].Config | [.Entrypoint // [], .Cmd // []]' "$META")"
if [[ "$image_entry_cmd" != "null" ]] &&
  [[ "$(jq -c '.[0]' <<<"$image_entry_cmd")" == "$(jq -c '.[0]' <<<"$container_entry_cmd")" ]]; then
  entrypoint=()
  if [[ "$(jq -c '.[1]' <<<"$image_entry_cmd")" == "$(jq -c '.[1]' <<<"$container_entry_cmd")" ]]; then
    cmd=()
  fi
fi
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

# 共享 host 或其他容器的网络命名空间时，hostname、DNS、hosts 与端口都继承自
# 宿主机/被依附容器：inspect 里记录的是对方的值，再传给 docker run 会被拒绝
# （conflicting options: hostname and the network mode）或在新服务器上失真。
raw_network_mode="$(jq -r '.[0].HostConfig.NetworkMode // empty' "$META")"
netns_shared=""
case "$raw_network_mode" in
  host) netns_shared="host" ;;
  container:*) netns_shared="container" ;;
esac

cid="$(jq -r '.[0].Id' "$META")"
default_host="${cid:0:12}"
hostname="$(jq -r '.[0].Config.Hostname // empty' "$META")"
if [[ -z "$netns_shared" && -n "$hostname" && "$hostname" != "$default_host" ]]; then
  args+=(--hostname "$hostname")
fi

domainname="$(jq -r '.[0].Config.Domainname // empty' "$META")"
[[ -n "$netns_shared" || -z "$domainname" ]] || args+=(--domainname "$domainname")

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
# 镜像（含 docker commit 生成的快照镜像）已带有相同的健康检查时不再传参：
# docker run 只能表达 CMD-SHELL，把 exec 形式的 CMD 改写成 shell 形式会让
# 没有 /bin/sh 的镜像（如 distroless）健康检查永远失败。
hc_kind="$(jq -r '.[0].Config.Healthcheck.Test[0] // empty' "$META" 2>/dev/null || true)"
meta_hc="$(jq -cS '.[0].Config.Healthcheck // null' "$META" 2>/dev/null || echo null)"
image_hc="$(docker image inspect "$image" 2>/dev/null | jq -cS '.[0].Config.Healthcheck // null' 2>/dev/null || echo null)"
if [[ "$meta_hc" == "$image_hc" ]]; then
  :
elif [[ "$hc_kind" == "NONE" ]]; then
  args+=(--no-healthcheck)
elif [[ "$hc_kind" == "CMD" || "$hc_kind" == "CMD-SHELL" ]]; then
  if [[ "$hc_kind" == "CMD-SHELL" ]]; then
    hc_test="$(jq -r '.[0].Config.Healthcheck.Test[1] // empty' "$META")"
  else
    hc_test="$(jq -r '.[0].Config.Healthcheck.Test[1:] | map(@sh) | join(" ")' "$META")"
    warn_user "容器 ${name} 的健康检查改写为 shell 形式（镜像需要包含 /bin/sh）：${hc_test}"
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

if [[ "$netns_shared" != "container" ]]; then
  mapfile -t extra_hosts < <(jq -r '.[0].HostConfig.ExtraHosts[]?' "$META")
  for h in "${extra_hosts[@]}"; do args+=(--add-host "$h"); done

  mapfile -t dns_list < <(jq -r '.[0].HostConfig.Dns[]?' "$META")
  for d in "${dns_list[@]}"; do args+=(--dns "$d"); done
  mapfile -t dns_search < <(jq -r '.[0].HostConfig.DnsSearch[]?' "$META")
  for d in "${dns_search[@]}"; do args+=(--dns-search "$d"); done
  mapfile -t dns_opts < <(jq -r '.[0].HostConfig.DnsOptions[]?' "$META")
  for d in "${dns_opts[@]}"; do args+=(--dns-option "$d"); done
fi

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
if [[ "$publish_all" == "true" && -z "$netns_shared" ]]; then
  args+=(-P)
fi

# 关键修复：稳健还原 PortBindings。
# 旧脚本在 HostPort 为空或 IPv6 HostIp 场景下容易生成无效 -p；这里跳过空 HostPort，并给 IPv6 加 []。
port_bindings=()
# host 网络下端口直接暴露在宿主机，container 网络下端口属于被依附容器；
# 两种模式都不能（也无需）再 -p 发布。
if [[ -z "$netns_shared" ]]; then
  mapfile -t port_bindings < <(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[]? | .key as $c | .value[]? | "\(.HostIp // "")|\(.HostPort // "")|\($c)"' "$META")
fi
published_ports=()
for p in "${port_bindings[@]}"; do
  host_ip="${p%%|*}"
  rest="${p#*|}"
  host_port="${rest%%|*}"
  cont_port="${rest#*|}"

  # 空 HostPort 是 Docker 随机端口分配（如 -p 80 或 -p 0.0.0.0::80），保留空 HostPort 让 Docker 重新随机分配
  [[ -z "$cont_port" ]] && continue

  # 迁移前预检中选择了换端口或不对外开放时，按选择调整。
  if [[ -n "$host_port" ]] &&
    decided_port="$(decision_port "$name" "$host_ip" "$host_port" "${cont_port%%/*}" "$([[ "$cont_port" == */* ]] && echo "${cont_port#*/}" || echo tcp)")"; then
    if [[ -z "$decided_port" ]]; then
      detail "端口 ${host_port} 按预检时的选择不再对外开放"
      continue
    fi
    detail "端口按预检时的选择改为：${host_port} -> ${decided_port}"
    host_port="$decided_port"
  fi

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
  detail "端口映射：${host_ip:-0.0.0.0}:${host_port} -> ${cont_port}"
done

mapfile -t mounts < <(jq -r '.[0].Mounts[]? | @base64' "$META")
for m in "${mounts[@]}"; do
  _jq() { echo "$m" | decode_base64 | jq -r "$1"; }
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
    # Mode 里的 ro/rw 与 RW 字段重复；读写属性统一由 RW 决定，否则会生成
    # Docker 拒绝的 ro,ro。
    for part in "${mode_parts[@]}"; do
      case "$part" in "" | ro | rw) ;; *) opts+=("$part") ;; esac
    done
  fi
  [[ "$rw" != "true" ]] && opts+=(ro)
  if ((${#opts[@]})); then
    optstr="$(
      IFS=,
      echo "${opts[*]}"
    )"
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
  # 只还原用户显式指定的静态 IP（IPAMConfig）。Docker 动态分配的地址若被
  # 固定下来，会与目标端同网络的其他容器冲突，也改变了原有配置。
  primary_ip="$(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].IPAMConfig.IPv4Address // empty' "$META")"
  primary_ip6="$(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].IPAMConfig.IPv6Address // empty' "$META")"
  if decision_auto_ip "$name" "$primary_net"; then
    detail "网络 ${primary_net} 中按预检时的选择改为自动分配 IP"
    primary_ip=""
    primary_ip6=""
  fi
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
log_line "\$ ${args[*]}"
run_with_activity "${name}" dm_capture_command "$run_log" "${args[@]}"
run_rc=$?
set -e
run_output="$(cat "$run_log")"
rm -f "$run_log"

if [[ $run_rc -ne 0 ]]; then
  log_line "容器 ${name} 创建失败（退出码 ${run_rc}）：${run_output}"
  ((${#published_ports[@]} == 0)) || log_line "本次尝试绑定的端口：${published_ports[*]}"
  fail_with_output "容器 ${name} 创建失败" "$run_output"
  exit "$run_rc"
fi

# 连接额外网络。
network_restore_failed=0
if [[ "$network_mode" != "host" && "$network_mode" != "none" && "$network_mode" != container:* ]]; then
  mapfile -t net_entries < <(jq -r '.[0].NetworkSettings.Networks | to_entries[]? | @base64' "$META")
  for entry in "${net_entries[@]}"; do
    _net() { echo "$entry" | decode_base64 | jq -r "$1"; }
    net_name="$(_net '.key')"
    [[ -z "$net_name" || "$net_name" == "$primary_net" || "$net_name" == "bridge" ]] && continue
    ip="$(_net '.value.IPAMConfig.IPv4Address // empty')"
    ip6="$(_net '.value.IPAMConfig.IPv6Address // empty')"
    aliases_raw="$(_net '.value.Aliases // empty | join(" ")')"
    conn_args=()
    if decision_auto_ip "$name" "$net_name"; then
      ip=""
      ip6=""
    fi
    [[ -n "$ip" && "$ip" != "null" ]] && conn_args+=(--ip "$ip")
    [[ -n "$ip6" && "$ip6" != "null" ]] && conn_args+=(--ip6 "$ip6")
    if [[ -n "$aliases_raw" && "$aliases_raw" != "null" ]]; then
      for a in $aliases_raw; do conn_args+=(--alias "$a"); done
    fi
    dm_quiet docker network connect "${conn_args[@]}" "$net_name" "$name" || {
      network_restore_failed=1
      fail_with_output "容器 ${name} 无法连接网络 ${net_name}" "$(log_tail_text 10)" \
        "macvlan、ipvlan、overlay 网络需要先在新服务器手动创建"
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
    error_user "RESTORE_HEALTH_TIMEOUT 的值无效：$health_timeout" "请设置为 1 到 3600 之间的秒数"
    exit 1
  fi
  health_timeout="$(health_wait_seconds "$health_timeout" "$name")"
  health_deadline=$((SECONDS + health_timeout))
  health_started=$SECONDS
  health_next_report=0
  health_last_status=""
  while ((SECONDS < health_deadline)); do
    health_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)"
    health_elapsed=$((SECONDS - health_started))
    case "$health_status" in
      healthy)
        log_line "[完成] 容器健康检查：$name · ${health_elapsed}秒"
        break
        ;;
      unhealthy | exited | dead)
        error_user "容器 ${name} 健康检查没有通过（${health_status}）" "执行 docker logs ${name} 查看应用日志"
        exit 1
        ;;
    esac
    if [[ "$health_status" != "$health_last_status" ]] || ((health_elapsed >= health_next_report)); then
      log_line "[进度] 容器健康检查：$name · ${health_status:-未知} · ${health_elapsed}/${health_timeout}秒"
      health_last_status="$health_status"
      health_next_report=$((health_elapsed + 5))
    fi
    progress_note "${name} 健康检查 · ${health_status:-starting} · ${health_elapsed}/${health_timeout} 秒"
    sleep 1
  done
  if [[ "${health_status:-}" != "healthy" ]]; then
    error_user "容器 ${name} 健康检查超时（${health_timeout} 秒）" \
      "执行 docker logs ${name} 查看应用日志；启动较慢的服务可以调大 RESTORE_HEALTH_TIMEOUT"
    exit 1
  fi
elif [[ "$original_running" == "true" ]]; then
  startup_grace="${RESTORE_STARTUP_GRACE:-3}"
  if ! [[ "$startup_grace" =~ ^[1-9][0-9]*$ ]] || ((startup_grace > 300)); then
    error_user "RESTORE_STARTUP_GRACE 的值无效：$startup_grace" "请设置为 1 到 300 之间的秒数"
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
        error_user "容器 ${name} 启动后立即退出（${startup_status:-missing}）" "执行 docker logs ${name} 查看应用日志"
        exit 1
        ;;
    esac
    startup_elapsed=$((SECONDS - startup_started))
    if ((startup_elapsed >= startup_next_report)); then
      log_line "[进度] 容器启动验证：$name · running · ${startup_elapsed}/${startup_grace}秒"
      startup_next_report=$((startup_elapsed + 5))
    fi
    ((SECONDS >= startup_deadline)) && break
    sleep 1
  done
  log_line "[完成] 容器启动验证：$name · $((SECONDS - startup_started))秒"
fi

snapshot_original="$(jq -r '.[0].DockerMigrate.original_image // empty' "$META")"
if [[ -n "$snapshot_original" ]]; then
  warn_user "${name} 使用快照镜像保留了容器内的改动，以后升级请用原镜像 ${snapshot_original} 重建"
fi

if [[ "$original_paused" == "true" ]]; then
  dm_quiet docker pause "$name" || {
    error_user "无法把容器 ${name} 恢复为暂停状态"
    exit 1
  }
fi

if ((replacement_active == 1)); then
  if ((transaction_mode == 1)); then
    # 由全局事务在全部项目、数据和健康检查通过后统一删除回滚容器。
    replacement_active=0
    log_line "替换已验证，回滚容器 ${replacement_backup_name} 保留到事务提交"
  elif dm_quiet docker rm -f "$replacement_backup_name"; then
    replacement_active=0
    log_line "替换已验证，已删除回滚容器 ${replacement_backup_name}"
  else
    warn_user "新容器已运行，但回滚容器 ${replacement_backup_name} 没能删除，可以手动执行 docker rm -f ${replacement_backup_name}"
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

# 彩色输出：主脚本与生成的恢复脚本共用。
BLUE() { echo -e "\033[1;34m$*\033[0m"; }
YEL() { echo -e "\033[1;33m$*\033[0m"; }
RED() { echo -e "\033[1;31m$*\033[0m"; }
OK() { echo -e "\033[1;32m$*\033[0m"; }

# 通用工具：主脚本与生成的恢复脚本共用。

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

# 运行日志：主脚本与生成的恢复脚本共用。
#
# 屏幕只显示阶段、进度、警告和最终结果；每一步的细节、执行的命令及其完整
# 输出都写进日志文件。成功后日志自动删除，失败时保留并在结果中给出路径，
# 方便用户反馈。子脚本（restore.sh、单容器恢复脚本）通过环境变量沿用父进程
# 的日志文件，由创建日志的进程负责收尾。
#
# DOCKER_MIGRATE_VERBOSE=1（或 --verbose）时，细节同时显示在屏幕上。
# DOCKER_MIGRATE_LOG_DIR 可指定日志目录，默认 ~/docker_migrate_logs。

# 写入日志前隐藏敏感信息：迁移链接中的密钥，以及 -e/--env 传入或形如
# *PASSWORD=*、*TOKEN=* 的环境变量值（容器配置里常有数据库密码）。
log_redact() {
  sed -E \
    -e 's/((secret|iv|mac)=)[0-9A-Fa-f]+/\1***/g' \
    -e 's/((^|[[:space:]])(-e|--env)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=)[^[:space:]]*/\1***/g' \
    -e 's/(--env=[A-Za-z_][A-Za-z0-9_]*=)[^[:space:]]*/\1***/g' \
    -e 's/([A-Za-z0-9_]*(PASS|PASSWD|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|pass|password|secret|token)[A-Za-z0-9_]*=)[^[:space:]"&]*/\1***/g'
}

log_timestamp() {
  date '+%H:%M:%S'
}

# 追加一行到日志（不显示在屏幕上）。
log_line() {
  [[ -n "${DM_LOG_FILE:-}" ]] || return 0
  printf '[%s] %s\n' "$(log_timestamp)" "$*" | log_redact >>"$DM_LOG_FILE" 2>/dev/null || true
}

# 细节信息：总是写入日志，--verbose 时也显示在屏幕上。
detail() {
  log_line "$*"
  if [[ "${DOCKER_MIGRATE_VERBOSE:-0}" == "1" ]]; then
    screen_clear_line
    printf '    %s\n' "$*" >&2
  fi
}

# 运行命令，把标准输出与错误输出都记进日志而不是丢弃；没有日志时保持静默。
# 命令失败时记录退出码，失败原因因此有据可查。
dm_quiet() {
  local rc=0
  if [[ -z "${DM_LOG_FILE:-}" ]]; then
    "$@" >/dev/null 2>&1 || rc=$?
    return "$rc"
  fi
  log_line "\$ $*"
  "$@" >>"$DM_LOG_FILE" 2>&1 || rc=$?
  ((rc == 0)) || log_line "  → 退出码 ${rc}"
  return "$rc"
}

# 只把错误输出记进日志，标准输出照常返回给调用方（用于需要捕获输出的命令）。
dm_logged() {
  local rc=0
  if [[ -z "${DM_LOG_FILE:-}" ]]; then
    "$@" 2>/dev/null || rc=$?
    return "$rc"
  fi
  log_line "\$ $*"
  "$@" 2>>"$DM_LOG_FILE" || rc=$?
  ((rc == 0)) || log_line "  → 退出码 ${rc}"
  return "$rc"
}

# 日志开头的环境信息：反馈问题时最常需要的版本与资源情况。
log_environment() {
  local kind="$1"
  shift
  printf '===== Docker Migrate %s · %s · %s =====\n' "${SCRIPT_VERSION:-unknown}" "$kind" "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf '参数：%s\n' "$*"
  printf '系统：%s\n' "$(uname -srm 2>/dev/null || echo unknown)"
  if [[ -r /etc/os-release ]]; then
    printf '发行版：%s\n' "$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}")"
  fi
  printf 'bash：%s\n' "${BASH_VERSION:-unknown}"
  printf '用户：uid=%s\n' "$(id -u 2>/dev/null || echo unknown)"
  printf 'Docker：%s\n' "$(docker version --format 'client {{.Client.Version}} / server {{.Server.Version}}' 2>&1 | head -n1)"
  printf 'Docker 存储：%s\n' "$(docker info --format '{{.Driver}} · {{.DockerRootDir}} · cgroup {{.CgroupVersion}}' 2>&1 | head -n1)"
  printf 'Compose：%s\n' "$({ docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null || echo '未安装'; } | head -n1)"
  printf '工具：jq %s · python3 %s · openssl %s\n' \
    "$(jq --version 2>/dev/null || echo '未安装')" \
    "$(python3 --version 2>/dev/null | awk '{print $2}' || true)" \
    "$(openssl version 2>/dev/null | awk '{print $2}' || true)"
  printf '磁盘：\n'
  df -h "$PWD" "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | sed 's/^/  /' || true
  printf '%s\n' '=================================================='
}

# 创建日志文件；子进程已从父进程继承日志时直接沿用。
log_init() {
  local kind="$1" dir
  shift
  if [[ -n "${DM_LOG_FILE:-}" && -f "${DM_LOG_FILE}" ]]; then
    return 0
  fi
  dir="${DOCKER_MIGRATE_LOG_DIR:-${HOME:-/tmp}/docker_migrate_logs}"
  if ! mkdir -p "$dir" 2>/dev/null; then
    dir="${TMPDIR:-/tmp}"
  fi
  chmod 700 "$dir" 2>/dev/null || true
  DM_LOG_FILE="${dir}/${kind}-$(date +%Y%m%d-%H%M%S)-$$.log"
  if ! : >"$DM_LOG_FILE" 2>/dev/null; then
    DM_LOG_FILE=""
    return 0
  fi
  chmod 600 "$DM_LOG_FILE" 2>/dev/null || true
  DM_LOG_OWNER="$$"
  DM_REASON_FILE="${DM_LOG_FILE%.log}.reason"
  DM_WARN_FILE="${DM_LOG_FILE%.log}.warnings"
  DM_TIMING_FILE="${DM_LOG_FILE%.log}.timings"
  : >"$DM_REASON_FILE" 2>/dev/null || true
  : >"$DM_WARN_FILE" 2>/dev/null || true
  : >"$DM_TIMING_FILE" 2>/dev/null || true
  export DM_LOG_FILE DM_LOG_OWNER DM_REASON_FILE DM_WARN_FILE DM_TIMING_FILE
  log_environment "$kind" "$@" 2>&1 | log_redact >>"$DM_LOG_FILE" 2>/dev/null || true
}

# 创建日志的进程在结束时调用：成功则删除日志及附属文件，失败则保留。
log_finish() {
  local success="$1"
  [[ -n "${DM_LOG_FILE:-}" && "${DM_LOG_OWNER:-}" == "$$" ]] || return 0
  # DOCKER_MIGRATE_KEEP_LOG=1 时成功也保留日志，便于排查或测试。
  [[ "${DOCKER_MIGRATE_KEEP_LOG:-0}" != "1" ]] || success=0
  if [[ "$success" == "1" ]]; then
    rm -f "$DM_LOG_FILE" "${DM_REASON_FILE:-}" "${DM_WARN_FILE:-}" "${DM_TIMING_FILE:-}" 2>/dev/null || true
    rmdir "$(dirname "$DM_LOG_FILE")" 2>/dev/null || true
  else
    rm -f "${DM_WARN_FILE:-}" "${DM_TIMING_FILE:-}" 2>/dev/null || true
  fi
}

# 记录本次失败的原因与建议；只保留第一条，它通常就是根因。
fail_reason() {
  local reason="$1" hint="${2:-}"
  log_line "失败原因：${reason}${hint:+（建议：${hint}）}"
  [[ -n "${DM_REASON_FILE:-}" ]] || return 0
  if [[ ! -s "$DM_REASON_FILE" ]]; then
    printf '%s\t%s\n' "$reason" "$hint" >"$DM_REASON_FILE" 2>/dev/null || true
  fi
}

# 读取已记录的失败原因，输出“原因<TAB>建议”。
fail_reason_read() {
  [[ -n "${DM_REASON_FILE:-}" && -s "$DM_REASON_FILE" ]] || return 1
  head -n1 "$DM_REASON_FILE"
}

# 屏幕输出：分阶段显示整体进度。主脚本与生成的恢复脚本共用。
#
# 每个阶段在屏幕上只占一行：进行中时由进度显示原地刷新这一行，完成后
# 替换为“✓ 结果 · 耗时”。警告单独占一行并汇总到最终结果；细节只写日志。
# 阶段信息通过环境变量传给子脚本，让它们的进度行带上同一个阶段前缀。

screen_is_tty() {
  [[ -t 2 ]]
}

screen_clear_line() {
  screen_is_tty || return 0
  printf '\r\033[K' >&2
}

screen_color() {
  local code="$1"
  shift
  if screen_is_tty; then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}

# 当前阶段的前缀，例如“[5/7] 保存镜像”；不在任何阶段内时为空。
stage_prefix() {
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  printf '[%s/%s] %s' "${DM_STAGE_NUM:-?}" "${DM_STAGE_TOTAL:-?}" "$DM_STAGE_TITLE"
}

# 进度行开头：阶段前缀加上正在处理的对象。
stage_label() {
  local label="${1:-}" prefix
  prefix="$(stage_prefix)"
  # 子步骤与阶段同名时不重复显示。
  [[ "$label" != "${DM_STAGE_TITLE:-}" ]] || label=""
  if [[ -n "$prefix" && -n "$label" ]]; then
    printf '%s · %s' "$prefix" "$label"
  else
    printf '%s' "${prefix}${label}"
  fi
}

stage_begin() {
  DM_STAGE_NUM="$1"
  DM_STAGE_TOTAL="$2"
  DM_STAGE_TITLE="$3"
  DM_STAGE_STARTED=$SECONDS
  export DM_STAGE_NUM DM_STAGE_TOTAL DM_STAGE_TITLE
  log_line "===== [${DM_STAGE_NUM}/${DM_STAGE_TOTAL}] ${DM_STAGE_TITLE} ====="
  if screen_is_tty; then
    printf '\r%s\033[K' "$(stage_prefix) …" >&2
  else
    printf '%s\n' "$(stage_prefix)" >&2
  fi
}

# 阶段内需要提问或列出菜单时，先把阶段标题固定成一整行。
stage_hold() {
  screen_is_tty || return 0
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  printf '\r%s\033[K\n' "$(stage_prefix)" >&2
}

stage_record_timing() {
  local elapsed="$1"
  [[ -n "${DM_TIMING_FILE:-}" && -n "${DM_STAGE_TITLE:-}" ]] || return 0
  printf '%s\t%s\n' "$DM_STAGE_TITLE" "$elapsed" >>"$DM_TIMING_FILE" 2>/dev/null || true
}

stage_end() {
  local summary="${1:-}" elapsed
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  elapsed=$((SECONDS - ${DM_STAGE_STARTED:-$SECONDS}))
  stage_record_timing "$elapsed"
  log_line "完成：$(stage_prefix)${summary:+ · ${summary}} · $(format_elapsed "$elapsed")"
  screen_clear_line
  printf '%s %s %s%s\n' "$(stage_prefix)" "$(screen_color '1;32' '✓')" \
    "${summary:+${summary} · }" "$(format_elapsed "$elapsed")" >&2
  DM_STAGE_TITLE=""
  export DM_STAGE_TITLE
}

stage_fail() {
  local elapsed
  [[ -n "${DM_STAGE_TITLE:-}" ]] || return 0
  elapsed=$((SECONDS - ${DM_STAGE_STARTED:-$SECONDS}))
  stage_record_timing "$elapsed"
  log_line "失败：$(stage_prefix)"
  screen_clear_line
  printf '%s %s\n' "$(stage_prefix)" "$(screen_color '1;31' '✗')" >&2
  DM_FAILED_STAGE="$(stage_prefix)"
  export DM_FAILED_STAGE
  DM_STAGE_TITLE=""
  export DM_STAGE_TITLE
}

# 警告：屏幕上单独一行，写入日志，并在最终结果中汇总。
warn_user() {
  log_line "警告：$*"
  screen_clear_line
  printf '    %s %s\n' "$(screen_color '1;33' '!')" "$*" >&2
  if [[ -n "${DM_WARN_FILE:-}" ]]; then
    printf '%s\n' "$*" >>"$DM_WARN_FILE" 2>/dev/null || true
  fi
}

# 错误：写入日志并记录为失败原因；屏幕上的完整说明由最终结果统一给出。
error_user() {
  local reason="$1" hint="${2:-}"
  fail_reason "$reason" "$hint"
  if [[ "${DM_SUMMARY_ARMED:-0}" != "1" ]]; then
    screen_clear_line
    printf '%s %s\n' "$(screen_color '1;31' '✗')" "$reason" >&2
    [[ -z "$hint" ]] || printf '  建议：%s\n' "$hint" >&2
  fi
}

# 最终结果中的“阶段耗时”与“警告”部分。
print_stage_timings() {
  local title seconds line=""
  [[ -n "${DM_TIMING_FILE:-}" && -s "$DM_TIMING_FILE" ]] || return 0
  while IFS=$'\t' read -r title seconds; do
    [[ -n "$title" ]] || continue
    line+="${line:+ · }${title} $(format_elapsed "$seconds")"
  done <"$DM_TIMING_FILE"
  [[ -z "$line" ]] || printf '阶段耗时：%s\n' "$line"
}

print_warning_summary() {
  local warning count
  [[ -n "${DM_WARN_FILE:-}" && -s "$DM_WARN_FILE" ]] || return 0
  count="$(awk 'NF' "$DM_WARN_FILE" | wc -l | tr -d ' ')"
  printf '警告：%s 条\n' "$count"
  while IFS= read -r warning; do
    [[ -n "$warning" ]] || continue
    printf '  · %s\n' "$warning"
  done < <(awk 'NF && !seen[$0]++' "$DM_WARN_FILE" | head -n 10)
}

# 失败时的说明：原因、建议、日志位置与最近的日志内容。
print_failure_details() {
  local reason hint row
  if row="$(fail_reason_read)"; then
    IFS=$'\t' read -r reason hint <<<"$row"
    [[ -z "$reason" ]] || printf '原因：%s\n' "$reason"
    [[ -z "$hint" ]] || printf '建议：%s\n' "$hint"
  fi
  if [[ -n "${DM_LOG_FILE:-}" && -f "$DM_LOG_FILE" ]]; then
    printf '日志：%s\n' "$DM_LOG_FILE"
    printf '      反馈问题时请附上这个文件（密钥与密码已自动隐藏），或运行 --diagnose 生成诊断包。\n'
    printf '最近日志：\n'
    tail -n 15 "$DM_LOG_FILE" | sed 's/^/  /'
  fi
}

# 常见错误识别：把 Docker、curl 等工具的英文报错翻译成“原因 + 建议”。
# 主脚本与生成的恢复脚本共用。

# 根据错误文本输出“原因<TAB>建议”；无法识别时返回 1。
explain_error() {
  local text="$1" port
  shopt -s nocasematch
  case "$text" in
    *"port is already allocated"* | *"address already in use"* | *"failed to bind host port"* | *"Bind for "*" failed"*)
      port="$(grep -oE '(Bind for [^ ]*:|host port |0\.0\.0\.0:|\]:)[0-9]+' <<<"$text" | grep -oE '[0-9]+$' | head -n1 || true)"
      printf '宿主机端口%s已被其他程序占用\t执行 ss -lntp%s 查看占用的进程，停止它或修改端口后重试\n' \
        "${port:+ ${port} }" "${port:+ | grep \":${port} \"}"
      ;;
    *"no space left on device"*)
      printf '磁盘空间不足\t执行 df -h 查看剩余空间，清理后重试（docker system prune 可以清理无用的镜像和容器）\n'
      ;;
    *"permission denied while trying to connect to the docker"*)
      printf '当前用户没有访问 Docker 的权限\t请用 root 运行，或用 sudo 运行脚本\n'
      ;;
    *"cannot connect to the docker daemon"* | *"is the docker daemon running"*)
      printf 'Docker 服务没有运行\t执行 systemctl start docker 启动 Docker 后重试\n'
      ;;
    *"exec format error"* | *"does not match the detected host platform"* | *"no matching manifest for"*)
      printf '镜像的 CPU 架构与本机不一致\t请在相同 CPU 架构（如都是 x86_64 或都是 arm64）的服务器之间迁移\n'
      ;;
    *"pull access denied"* | *"repository does not exist"* | *"manifest unknown"* | *"not found: manifest"*)
      printf '镜像仓库中找不到该镜像，或需要登录才能拉取\t检查镜像名；私有镜像请先执行 docker login\n'
      ;;
    *"tls handshake timeout"* | *"i/o timeout"* | *"client.timeout exceeded"* | *"request canceled while waiting"*)
      printf '连接镜像仓库超时\t检查服务器网络，或为 Docker 配置可用的镜像加速地址后重试\n'
      ;;
    *"is already in use by container"*)
      printf '容器名称已被其他容器占用\t删除或重命名同名容器，或设置 RESTORE_EXISTING=replace\n'
      ;;
    *"bind source path does not exist"* | *"invalid mount config"*)
      printf '挂载的宿主机路径不存在\t确认该路径在本机存在后重试\n'
      ;;
    *"could not resolve host"*)
      printf '无法解析链接中的主机名\t检查链接是否完整、DNS 是否可用\n'
      ;;
    *"failed to connect"* | *"connection refused"* | *"couldn't connect to server"*)
      printf '无法连接旧服务器的下载服务\t确认旧服务器上的脚本仍在运行，并检查旧服务器防火墙和云厂商安全组是否放行了下载端口\n'
      ;;
    *"unhealthy"* | *"did not become healthy"* | *"healthcheck timed out"*)
      printf '容器启动后健康检查没有通过\t执行 docker logs <容器名> 查看应用日志；启动较慢的服务可以调大 RESTORE_HEALTH_TIMEOUT\n'
      ;;
    *"timed out"* | *"connection reset"*)
      printf '与旧服务器的连接超时或中断\t检查两台服务器之间的网络，以及旧服务器防火墙和安全组设置，然后重试\n'
      ;;
    *"returned error: 404"* | *"404 not found"*)
      printf '下载地址不存在\t旧服务器可能已经结束传输，或链接没有完整复制；请在旧服务器重新运行备份\n'
      ;;
    *"did not remain running"*)
      printf '容器启动后立即退出\t执行 docker logs <容器名> 查看应用日志\n'
      ;;
    *"operation not permitted"* | *"permission denied"*)
      printf '权限不足\t请用 root 或 sudo 运行脚本\n'
      ;;
    *)
      shopt -u nocasematch
      return 1
      ;;
  esac
  shopt -u nocasematch
}

# 记录失败原因：能识别的报错给出具体原因和建议，否则使用调用方给出的描述。
fail_with_output() {
  local fallback="$1" output="${2:-}" row reason hint
  if [[ -n "$output" ]] && row="$(explain_error "$output")"; then
    IFS=$'\t' read -r reason hint <<<"$row"
    error_user "${fallback}：${reason}" "$hint"
  else
    error_user "$fallback" "${3:-查看下方日志中的最后几行了解详情}"
  fi
}

# 日志末尾的报错文本，用于在命令失败后识别原因。
log_tail_text() {
  [[ -n "${DM_LOG_FILE:-}" && -f "$DM_LOG_FILE" ]] || return 0
  tail -n "${1:-30}" "$DM_LOG_FILE" 2>/dev/null || true
}

# 进度显示与耗时格式化：主脚本与生成的恢复脚本共用。
#
# 耗时操作统一通过 run_with_progress 执行，后台 watcher 每秒（非终端每 10 秒）
# 刷新一行：
#   知道总量时：[5/7] 保存镜像 ██████░░░░ 58% · 1.2GB/2.1GB · 45MB/s · 剩余约 20 秒
#   不知道总量：[4/7] 停机并打包数据 · 卷 mysql_data ⠹ 已处理 1.2GB · 45MB/s · 1 分 3 秒
#   没有字节数：[7/8] 启动服务 · nginx ⠹ 1 分 3 秒
# 长时间没有进展时追加说明（DM_PROGRESS_HINT），让用户知道程序仍在运行、在等什么。

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

# 1536 → 1.5KB；整数部分达到两位后不再保留小数。
human() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1 || b >= 10) printf "%d%s\n", b, u[i]
    else {
      s = sprintf("%.1f", b)
      sub(/\.0$/, "", s)
      printf "%s%s\n", s, u[i]
    }
  }'
}

progress_file_size() {
  local file="$1"
  stat -c %s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0
}

# 当前已处理字节数。spec 为空时没有字节数；"count:路径" 读取计数文件
# （由 progress_meter 写入）；其他情况视为正在增长的输出文件。
progress_current() {
  local spec="${1:-}" value
  case "$spec" in
    "") echo 0 ;;
    count:*)
      value="$(cat "${spec#count:}" 2>/dev/null || true)"
      [[ "$value" =~ ^[0-9]+$ ]] || value=0
      echo "$value"
      ;;
    *) progress_file_size "$spec" ;;
  esac
}

# 总字节数。可以是数字，也可以是 "header:路径"：从 curl -D 写出的响应头中
# 读取 Content-Length（下载开始前未知，开始后才能确定）。
progress_total() {
  local spec="${1:-0}" value
  case "$spec" in
    header:*)
      value="$(tr -d '\r' <"${spec#header:}" 2>/dev/null |
        awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }')"
      ;;
    *) value="$spec" ;;
  esac
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  echo "$value"
}

# 在管道中计数：原样转发标准输入到标准输出，并把累计字节数写入计数文件。
# 没有 python3 时退化为 cat（只是不显示字节数）。
progress_meter() {
  local count_file="${1:-}"
  if [[ -z "$count_file" || "$count_file" == /dev/null ]] || ! command -v python3 >/dev/null 2>&1; then
    cat
    return
  fi
  python3 -c '
import os, sys, time
path = sys.argv[1]
src, dst = sys.stdin.buffer, sys.stdout.buffer
total, last = 0, 0.0
def flush():
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(total))
    os.replace(tmp, path)
while True:
    chunk = src.read(1024 * 1024)
    if not chunk:
        break
    dst.write(chunk)
    total += len(chunk)
    now = time.monotonic()
    if now - last >= 0.5:
        flush()
        last = now
dst.flush()
flush()
' "$count_file"
}

progress_bar() {
  local percent="$1" width=20 filled bar empty
  filled=$((percent * width / 100))
  printf -v bar '%*s' "$filled" ''
  printf -v empty '%*s' "$((width - filled))" ''
  printf '%s%s' "${bar// /█}" "${empty// /░}"
}

# 生成一行进度文字（不含换行）。保持纯函数，便于单元测试。
#   label current total elapsed [rate 字节/秒] [spinner] [hint]
# 只在确实知道总量时显示百分比，避免用“假进度条”误导用户。
progress_render() {
  local label="$1" current="${2:-0}" total="${3:-0}" elapsed="${4:-0}"
  local rate="${5:-0}" spinner="${6:-}" hint="${7:-}"
  local percent line remaining
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0
  [[ "$rate" =~ ^[0-9]+$ ]] || rate=0
  if ((total > 0)); then
    ((current <= total)) || current=$total
    percent=$((current * 100 / total))
    # 总量是估算值时，在命令真正结束前不显示 100%。
    ((percent < 100)) || percent=99
    line="${label} $(progress_bar "$percent") ${percent}% · $(human "$current")/$(human "$total")"
    ((rate == 0)) || line+=" · $(human "$rate")/s"
    if ((rate > 0 && total > current)); then
      remaining=$(((total - current) / rate))
      if ((remaining > 0)); then
        line+=" · 剩余约 $(format_elapsed "$remaining")"
      else
        line+=" · 即将完成"
      fi
    else
      line+=" · $(format_elapsed "$elapsed")"
    fi
  elif ((current > 0)); then
    line="${label}${spinner:+ ${spinner}} 已处理 $(human "$current")"
    ((rate == 0)) || line+=" · $(human "$rate")/s"
    line+=" · $(format_elapsed "$elapsed")"
  else
    line="${label}${spinner:+ ${spinner}} $(format_elapsed "$elapsed")"
  fi
  [[ -z "$hint" ]] || line+=" · ${hint}"
  printf '%s' "$line"
}

progress_tty_draw() {
  # 用一次写入覆盖旧内容，再清除新内容右侧的残留；不要先输出一整行空格，
  # 否则 SSH 或刷新较慢的终端会把中间空帧显示成闪烁。
  printf '\r%s\033[K' "$1" >&2
}

progress_tty_clear() {
  printf '\r\033[K' >&2
}

# 命令失败只记日志：失败原因由阶段结果与最终结果统一说明，避免屏幕上重复报错。
progress_finish() {
  local label="$1" rc="$2" elapsed="$3" current="${4:-0}"
  ((rc != 0)) || return 0
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  log_line "失败：${label}（退出码 ${rc}，耗时 $(format_elapsed "$elapsed")$( ((current == 0)) || printf '，已处理 %s' "$(human "$current")")）"
}

# 逐个处理对象时（如扫描容器）在阶段行里显示“第几个/共几个”。
progress_count() {
  local label="$1" current="$2" total="$3" item="${4:-}"
  local line
  printf -v line '%s %d/%d%s' "$label" "$current" "$total" "${item:+（${item}）}"
  if [[ -t 2 ]]; then
    progress_tty_draw "$(stage_label "$line")"
  elif ((current == total || current % 20 == 0)); then
    printf '[进度] %s\n' "$(stage_label "$line")" >&2
  fi
}

# 不在 run_with_progress 中的等待循环（如健康检查）用它刷新阶段行。
# 非终端时每 10 秒最多输出一行，避免刷屏。
progress_note() {
  local text="$1" now=$SECONDS
  if [[ -t 2 ]]; then
    progress_tty_draw "$(stage_label "$text")"
  elif ((now - ${DM_LAST_NOTE_AT:--100} >= 10)); then
    DM_LAST_NOTE_AT=$now
    printf '[进度] %s\n' "$(stage_label "$text")" >&2
  fi
}

progress_watch() {
  local label="$1" spec="$2" total_spec="$3" started="$4" owner_pid="$5"
  local mode="${DOCKER_MIGRATE_PROGRESS_MODE:-auto}" interval current total elapsed line timer_pid=""
  local last_bytes=0 last_time=$SECONDS rate=0 sample changed_at=$SECONDS hint="" tick=0
  local stall="${DM_PROGRESS_STALL:-30}" spinner
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  [[ "$mode" != "plain" && "$mode" != "off" ]] || return 0
  if [[ -n "${DOCKER_MIGRATE_PROGRESS_INTERVAL:-}" ]]; then
    interval="$DOCKER_MIGRATE_PROGRESS_INTERVAL"
  elif [[ -t 2 ]]; then
    interval=1
  else
    interval=10
  fi
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=10
  [[ "$stall" =~ ^[1-9][0-9]*$ ]] || stall=30
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
    current="$(progress_current "$spec")"
    total="$(progress_total "$total_spec")"
    elapsed=$((SECONDS - started))
    # 速度取指数平滑，避免网络抖动时数字跳得太厉害。
    if ((SECONDS > last_time)); then
      sample=$(((current - last_bytes) / (SECONDS - last_time)))
      ((sample >= 0)) || sample=0
      if ((rate == 0)); then rate=$sample; else rate=$(((rate * 7 + sample * 3) / 10)); fi
    fi
    ((current == last_bytes)) || changed_at=$SECONDS
    last_bytes=$current
    last_time=$SECONDS
    hint=""
    if ((SECONDS - changed_at >= stall)); then
      hint="${DM_PROGRESS_HINT:-仍在进行，请耐心等待}"
    fi
    spinner="${frames[$((tick % 10))]}"
    tick=$((tick + 1))
    if [[ -t 2 ]]; then
      line="$(progress_render "$(stage_label "$label")" "$current" "$total" "$elapsed" "$rate" "$spinner" "$hint")"
      progress_tty_draw "$line"
    else
      printf '[进度] %s\n' "$(progress_render "$(stage_label "$label")" "$current" "$total" "$elapsed" "$rate" "" "$hint")" >&2
    fi
  done
  trap - TERM INT HUP
}

# 运行命令并显示进度。spec/total 的含义见 progress_current / progress_total。
run_with_progress() {
  local label="$1" spec="$2" total="$3"
  shift 3
  local started=$SECONDS watcher_pid rc current=0 restore_errexit=0
  log_line "开始：${label}"
  case $- in *e*) restore_errexit=1 ;; esac
  progress_watch "$label" "$spec" "$total" "$started" "$$" &
  watcher_pid=$!
  set +e
  "$@"
  rc=$?
  ((restore_errexit == 0)) || set -e
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  if [[ -t 2 ]]; then
    # 回到阶段行，不留下已完成子步骤的进度文字。
    if [[ -n "${DM_STAGE_TITLE:-}" ]]; then
      progress_tty_draw "$(stage_prefix) …"
    else
      progress_tty_clear
    fi
  fi
  current="$(progress_current "$spec")"
  progress_finish "$label" "$rc" "$((SECONDS - started))" "$current"
  ((rc != 0)) || log_line "完成：${label} · $(format_elapsed "$((SECONDS - started))")$( ((current == 0)) || printf ' · %s' "$(human "$current")")"
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

# 挂载路径判断：重叠检测、宿主机系统路径与软链接解析。主脚本与恢复脚本共用。

mount_paths_overlap() {
  local left="$1" right="$2"
  while [[ "$left" != "/" && "$left" == */ ]]; do left="${left%/}"; done
  while [[ "$right" != "/" && "$right" == */ ]]; do right="${right%/}"; done
  [[ "$left" != "/" && "$right" != "/" ]] || return 0
  [[ "$left" == "$right" || "$left" == "${right}/"* || "$right" == "${left}/"* ]]
}

# 宿主机系统路径只在目标端重建挂载关系，不迁移其内容：这些路径属于宿主机
# 本身（时区、DNS、内核模块、伪文件系统等），覆盖目标端会破坏新服务器。
# 第一组匹配自身及其子路径；第二组是只在完全相同时才算系统路径的大目录。
SYSTEM_BIND_PREFIXES=(
  /proc /sys /dev /run /var/run /boot /lib/modules /usr/lib/modules
  /var/lib/docker /var/lib/containerd /var/log /etc/docker /etc/systemd
  /lib/systemd /usr/lib/systemd /etc/localtime /etc/timezone /usr/share/zoneinfo
  /etc/hostname /etc/hosts /etc/resolv.conf /etc/machine-id /etc/os-release
  /usr/lib/os-release /etc/passwd /etc/group /etc/shadow /etc/gshadow
  /etc/ssl /etc/pki /etc/ca-certificates
)
SYSTEM_BIND_EXACT=(
  / /etc /usr /usr/lib /usr/bin /usr/local /var /var/lib /lib /lib64 /bin /sbin
  /opt /home /root /srv /mnt /media /tmp
)

bind_path_is_system() {
  local path="$1" prefix
  [[ "$path" == "/" ]] || path="${path%/}"
  for prefix in "${SYSTEM_BIND_EXACT[@]}"; do
    [[ "$path" != "$prefix" ]] || return 0
  done
  for prefix in "${SYSTEM_BIND_PREFIXES[@]}"; do
    [[ "$path" != "$prefix" && "$path" != "${prefix}/"* ]] || return 0
  done
  return 1
}

# bind 源本身是软链接时（如 /srv/app -> /data/app），Docker 挂载的是链接目标。
# 返回真实路径，供备份真实数据；无法解析时原样返回。
bind_resolve_source() {
  local path="$1" resolved=""
  if [[ -L "$path" ]]; then
    resolved="$(realpath "$path" 2>/dev/null || readlink -f "$path" 2>/dev/null || true)"
  fi
  printf '%s\n' "${resolved:-$path}"
}

# 迁移包结构：校验清单、manifest 与归档安全检查、恢复结果统计。

json_array_from_lines() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
    return 0
  fi
  # 过滤空行，避免空数组被序列化成 [""]。
  printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -cs .
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
    all(.networks[]; type == "object" and (.name | type == "string")) and
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
      (.file | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*\\.tgz$")) and
      ((.link // null) == null or (.link | type == "string" and startswith("/") and . != "/" and
        (test("(^|/)\\.\\.(/|$)") | not) and
        all(explode[]; . >= 32 and . != 127)))
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

# 容器改名与网络重连：单容器恢复脚本与恢复事务共用，供失败时还原旧容器。

rename_container_with_retry() {
  local old_name="$1" new_name="$2"
  for _ in {1..20}; do
    if dm_quiet docker rename "$old_name" "$new_name"; then
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
      dm_quiet docker network connect "$network" "$container" || return 1
      continue
    fi
    ip="$(jq -r '.value.IPAMConfig.IPv4Address // empty' <<<"$entry")"
    ip6="$(jq -r '.value.IPAMConfig.IPv6Address // empty' <<<"$entry")"
    [[ -z "$ip" ]] || connect_args+=(--ip "$ip")
    [[ -z "$ip6" ]] || connect_args+=(--ip6 "$ip6")
    while IFS= read -r alias; do
      [[ -z "$alias" ]] || connect_args+=(--alias "$alias")
    done < <(jq -r '.value.Aliases[]? // empty' <<<"$entry")
    dm_quiet docker network connect "${connect_args[@]}" "$network" "$container" || return 1
  done < <(jq -c 'to_entries[]?' "$metadata_file")
}

# Compose 在 com.docker.compose.project.config_files 标签里用逗号连接多个配置
# 文件（-f a.yml -f b.yml）。没有逗号时兼容按冒号分隔的旧写法（COMPOSE_FILE）。
compose_config_files_split() {
  local raw="$1" sep=","
  [[ -n "$raw" ]] || return 0
  [[ "$raw" == *,* ]] || sep=":"
  local -a parts=()
  IFS="$sep" read -r -a parts <<<"$raw"
  printf '%s\n' "${parts[@]}" | awk 'NF'
}

# 等待健康检查的最长时间：至少是 RESTORE_HEALTH_TIMEOUT（默认 60 秒），并且要
# 够容器自己的健康检查跑完第一次。有的镜像每 60 秒才检查一次（如 Vaultwarden），
# 固定等 60 秒会在第一次检查出结果之前就判定超时。
health_wait_seconds() {
  local base="${1:-60}" needed
  shift
  (($# > 0)) || {
    printf '%s\n' "$base"
    return 0
  }
  needed="$(docker inspect "$@" 2>/dev/null | jq '[.[] | .Config.Healthcheck // empty |
    select((.Test[0] // "") != "NONE") |
    ((.StartPeriod // 0) + (if (.Interval // 0) > 0 then .Interval else 30000000000 end) +
      (if (.Timeout // 0) > 0 then .Timeout else 30000000000 end)) / 1000000000 + 30 | floor] |
    max // 0' 2>/dev/null || echo 0)"
  [[ "$needed" =~ ^[0-9]+$ ]] || needed=0
  ((needed > base)) || needed="$base"
  ((needed <= 3600)) || needed=3600
  printf '%s\n' "$needed"
}

# 迁移前预检：在下载迁移包、改动新服务器之前，根据迁移计划找出会让迁移失败的问题。
#
# 问题分三级：
#   info  只提示，不停下（如 Docker 版本较旧）
#   ask   会导致迁移失败但可以处理，停下来让用户针对性地选择（如端口被占用）
#   stop  无法继续（如 CPU 架构不同）
# 用户的选择写进“恢复决定”文件（JSON），恢复脚本按它执行：换端口、跳过项目、
# 改为自动分配 IP 等。检查逻辑用 python3 实现（新服务器恢复时本来就需要它）。

# 输出检查结果 JSON：{"issues": [...], "summary": {...}}。
preflight_collect() {
  local plan="$1" decisions="$2" base_dir="$3"
  python3 - "$plan" "$decisions" "$base_dir" <<'PREFLIGHT_PY'
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys

plan_path, decisions_path, base_dir = sys.argv[1:4]
plan = json.load(open(plan_path))
try:
    decisions = json.load(open(decisions_path))
except (OSError, ValueError):
    decisions = {}
issues = []


def run(cmd):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def human(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            if unit == "B" or n >= 10:
                return "%d%s" % (n, unit)
            return ("%.1f" % n).rstrip("0").rstrip(".") + unit
        n /= 1024


def cjk_spaced(text):
    """中文排版：与英文或数字相邻时加一个空格，与中文或全角符号相邻时不加。"""
    if not text:
        return text
    left = " " if ord(text[0]) < 128 and text[0].isalnum() else ""
    right = " " if ord(text[-1]) < 128 and text[-1].isalnum() else ""
    return left + text + right


def add(level, kind, title, hint="", **data):
    item = {"level": level, "type": kind, "title": title, "hint": hint}
    item.update(data)
    issues.append(item)


def free_bytes(path):
    path = os.path.abspath(path or "/")
    while not os.path.exists(path) and path != "/":
        path = os.path.dirname(path)
    try:
        st = os.statvfs(path)
        return st.f_bavail * st.f_frsize, os.stat(path).st_dev
    except OSError:
        return None, None


skip_projects = set(decisions.get("skip_projects", []))
skip_containers = set(decisions.get("skip_containers", []))
replace_containers = set(decisions.get("replace_containers", []))
replace_projects = set(decisions.get("replace_projects", []))
keep_volumes = set(decisions.get("keep_volumes", []))
auto_subnet = set(decisions.get("auto_subnet", []))
reuse_network = set(decisions.get("reuse_network", []))
auto_ip = {(x.get("container"), x.get("network")) for x in decisions.get("auto_ip", [])}
port_map = {}
for item in decisions.get("port_map", []):
    key = (item.get("container"), item.get("host_ip", ""), str(item.get("host_port")),
           str(item.get("container_port")), item.get("proto", "tcp"))
    port_map[key] = str(item.get("new_port", ""))

containers = [c for c in plan.get("containers", [])
              if c.get("project", "") not in skip_projects and c["name"] not in skip_containers]
plan_names = {c["name"] for c in containers}
used_volumes = {v for c in containers for v in c.get("volumes", [])}
used_binds = {b for c in containers for b in c.get("binds", [])}

# ---------- Docker 环境 ----------
rc, out = run(["docker", "info", "--format", "{{json .}}"])
try:
    info = json.loads(out) if rc == 0 else {}
except ValueError:
    info = {}

arch_alias = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64",
              "armv7l": "arm", "armhf": "arm", "arm": "arm"}
src_arch = plan.get("source", {}).get("arch", "")
dst_arch = info.get("Architecture", "") or os.uname().machine
if src_arch and dst_arch and arch_alias.get(src_arch, src_arch) != arch_alias.get(dst_arch, dst_arch):
    add("stop", "arch",
        "两台服务器的 CPU 类型不同：旧服务器是 %s，新服务器是 %s" % (src_arch, dst_arch),
        "容器镜像只能在相同 CPU 类型的服务器上运行，请换一台和旧服务器相同类型的服务器")


def version_tuple(v):
    nums = re.findall(r"\d+", v or "")
    return tuple(int(x) for x in nums[:2]) if len(nums) >= 2 else None


src_ver = plan.get("source", {}).get("docker", "")
dst_ver = info.get("ServerVersion", "")
if version_tuple(src_ver) and version_tuple(dst_ver) and version_tuple(dst_ver) < version_tuple(src_ver):
    add("info", "docker_version",
        "新服务器的 Docker（%s）比旧服务器（%s）旧，一般不影响迁移" % (dst_ver, src_ver))

if any(c.get("project") for c in containers):
    has_plugin = run(["docker", "compose", "version"])[0] == 0
    if not has_plugin and not shutil.which("docker-compose"):
        add("stop", "compose",
            "要迁移 Compose 项目，但新服务器没有安装 Docker Compose",
            "先安装 Docker Compose（例如 apt install docker-compose-plugin）再重试")

runtimes = set((info.get("Runtimes") or {}).keys())
for c in containers:
    rt = c.get("runtime", "")
    if rt and rt != "runc" and runtimes and rt not in runtimes:
        add("stop", "runtime", "容器 %s 需要 %s 运行环境，新服务器没有安装" % (c["name"], rt),
            "先在新服务器安装它（例如 NVIDIA 显卡需要安装 NVIDIA Container Toolkit）再重试")
    for dev in c.get("devices", []):
        if dev and not os.path.exists(dev):
            add("stop", "device", "容器 %s 需要设备 %s，新服务器上没有" % (c["name"], dev),
                "确认新服务器有这个硬件并已安装驱动")

volume_plugins = set((info.get("Plugins") or {}).get("Volume") or [])
for v in plan.get("volumes", []):
    if v["name"] not in used_volumes:
        continue
    driver = v.get("driver", "local")
    if driver != "local" and volume_plugins and driver not in volume_plugins:
        add("stop", "volume_plugin", "数据卷 %s 使用 %s 插件存储，新服务器没有安装这个插件" % (v["name"], driver),
            "先在新服务器安装 %s 卷插件再重试" % driver)

mem_total = info.get("MemTotal") or 0
mem_need = sum(int(c.get("memory") or 0) for c in containers)
if mem_total and mem_need > mem_total:
    add("info", "memory", "容器设置的内存上限合计 %s，超过新服务器的内存 %s，内存紧张时容器可能被系统结束"
        % (human(mem_need), human(mem_total)))

# ---------- 磁盘空间 ----------
sizes = plan.get("sizes", {})
bundle = int(sizes.get("bundle") or 0)
kept_volume_bytes = sum(int(v.get("bytes") or 0) for v in plan.get("volumes", [])
                        if v["name"] in keep_volumes or v["name"] not in used_volumes)
docker_need = int(sizes.get("images") or 0) + int(sizes.get("volumes") or 0) - kept_volume_bytes
# 在已解压的迁移包里手动恢复时，下载和解压所需空间已经用掉了，不再计算。
skip_base = os.environ.get("PREFLIGHT_SKIP_BASE_DISK") == "1"
if skip_base:
    bundle = 0
base_need = 2 * bundle
base_free, base_dev = free_bytes(base_dir)
root_free, root_dev = free_bytes(info.get("DockerRootDir") or "/var/lib/docker")
if base_free is not None and root_free is not None and base_dev == root_dev:
    # 同一块磁盘：解压出的迁移包与加载后的镜像、数据卷会同时存在。
    total = max(base_need, bundle + docker_need)
    if base_free < total:
        add("ask", "disk_base",
            "磁盘空间不够：迁移需要约 %s，%s 所在磁盘只剩 %s" % (human(total), base_dir, human(base_free)),
            "清理磁盘后重新检查，或换一个空间更大的磁盘存放下载文件",
            need=total, free=base_free)
    elif base_free < total * 1.2:
        add("info", "disk_tight", "磁盘空间偏紧：迁移需要约 %s，剩余 %s" % (human(total), human(base_free)))
else:
    if base_free is not None and base_free < base_need:
        add("ask", "disk_base",
            "磁盘空间不够：下载和解压需要约 %s，%s 所在磁盘只剩 %s" % (human(base_need), base_dir, human(base_free)),
            "清理磁盘后重新检查，或换一个空间更大的磁盘存放下载文件",
            need=base_need, free=base_free)
    root = info.get("DockerRootDir") or "/var/lib/docker"
    if root_free is not None and root_free < docker_need:
        add("ask", "disk_docker",
            "磁盘空间不够：Docker 存放镜像和数据卷需要约 %s，%s 所在磁盘只剩 %s" % (human(docker_need), root, human(root_free)),
            "清理磁盘后重新检查（docker system prune 可以清理不用的镜像和容器）",
            need=docker_need, free=root_free)

for b in plan.get("binds", []):
    if b["host"] not in used_binds and (not b.get("link") or b["link"] not in used_binds):
        continue
    need = int(b.get("bytes") or 0)
    free, _ = free_bytes(b["host"])
    if free is not None and need and free < need:
        add("ask", "disk_bind",
            "磁盘空间不够：目录 %s 需要约 %s，所在磁盘只剩 %s" % (b["host"], human(need), human(free)),
            "清理这块磁盘后重新检查", need=need, free=free)

# ---------- 已有的同名容器、Compose 项目、数据卷 ----------
rc, out = run(["docker", "ps", "-a", "--format",
               '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Ports}}'])
existing = {}
for line in out.splitlines():
    parts = line.split("\t")
    if len(parts) >= 3:
        existing[parts[0]] = {"project": parts[1], "ports": parts[2]}
existing_projects = {e["project"] for e in existing.values() if e["project"]}
policy = os.environ.get("RESTORE_EXISTING", "")

for c in containers:
    if c.get("project") or c["name"] not in existing or c["name"] in replace_containers:
        continue
    if policy == "fail":
        add("stop", "existing_container", "新服务器上已经有同名容器 %s（RESTORE_EXISTING=fail 不允许替换）" % c["name"],
            "删除这个容器，或改用 RESTORE_EXISTING=replace")
    elif policy not in ("replace", "skip"):
        add("ask", "existing_container", "新服务器上已经有同名容器 %s" % c["name"], container=c["name"])
for project in sorted({c["project"] for c in containers if c.get("project")}):
    if project not in existing_projects or project in replace_projects:
        continue
    if policy == "fail":
        add("stop", "existing_project", "新服务器上已经有同名的 Compose 项目 %s（RESTORE_EXISTING=fail 不允许替换）" % project,
            "删除这个项目的容器，或改用 RESTORE_EXISTING=replace")
    elif policy not in ("replace", "skip"):
        add("ask", "existing_project", "新服务器上已经有同名的 Compose 项目 %s" % project, project=project)

for v in plan.get("volumes", []):
    if v["name"] not in used_volumes or v["name"] in keep_volumes:
        continue
    rc, out = run(["docker", "volume", "inspect", v["name"]])
    if rc != 0:
        continue
    try:
        cur = json.loads(out)[0]
    except (ValueError, IndexError):
        continue
    if (cur.get("Driver") or "local") != v.get("driver", "local") or (cur.get("Options") or {}) != (v.get("opts") or {}):
        add("ask", "volume_mismatch",
            "新服务器已有同名数据卷 %s，但它的存储方式和旧服务器不同" % v["name"], volume=v["name"])
    else:
        add("info", "volume_replace", "数据卷 %s 已存在，迁移的数据会替换它（失败时自动还原）" % v["name"])

# ---------- 网络 ----------
target_nets = {}
rc, out = run(["docker", "network", "ls", "-q"])
ids = out.split()
if ids:
    rc, out = run(["docker", "network", "inspect"] + ids)
    try:
        for n in json.loads(out) if rc == 0 else []:
            target_nets[n["Name"]] = {
                "driver": n.get("Driver", ""),
                "subnets": [c.get("Subnet") for c in (n.get("IPAM") or {}).get("Config") or [] if c.get("Subnet")],
                "ips": {(v.get("IPv4Address") or "").split("/")[0]: v.get("Name", "")
                        for v in (n.get("Containers") or {}).values()},
            }
    except ValueError:
        pass

plan_nets = {n["name"]: n for n in plan.get("networks", [])}
used_nets = {net["name"] for c in containers for net in c.get("networks", [])}
for name, net in plan_nets.items():
    if name not in used_nets or name in ("bridge", "host", "none") or net.get("compose"):
        continue
    if net.get("driver") in ("macvlan", "ipvlan"):
        add("info", "macvlan", "网络 %s 使用 %s，需要新服务器的网卡名称和旧服务器一致" % (name, net["driver"]))
    if name in reuse_network or name in auto_subnet:
        continue
    wanted = [s for s in net.get("subnets", []) if s]
    if name in target_nets:
        have = target_nets[name]
        if sorted(have["subnets"]) != sorted(wanted) or have["driver"] != net.get("driver", "bridge"):
            add("ask", "network_mismatch",
                "新服务器已有同名网络 %s，但网段不同（旧服务器 %s，新服务器 %s）"
                % (name, "、".join(wanted) or "自动", "、".join(have["subnets"]) or "自动"), network=name)
        continue
    for subnet in wanted:
        try:
            mine = ipaddress.ip_network(subnet, strict=False)
        except ValueError:
            continue
        clash = None
        for other, have in target_nets.items():
            for s in have["subnets"]:
                try:
                    if mine.overlaps(ipaddress.ip_network(s, strict=False)):
                        clash = (other, s)
                except (ValueError, TypeError):
                    pass
        if clash:
            add("ask", "subnet_conflict",
                "网络 %s 要用的网段 %s 和新服务器上的网络 %s（%s）重叠" % (name, subnet, clash[0], clash[1]),
                network=name)
            break

for c in containers:
    for net in c.get("networks", []):
        ip = net.get("ip", "")
        name = net["name"]
        if not ip or name in reuse_network or name in auto_subnet or (c["name"], name) in auto_ip:
            continue
        holder = target_nets.get(name, {}).get("ips", {}).get(ip)
        if holder and holder != c["name"] and holder not in plan_names:
            add("ask", "ip_conflict", "网络 %s 中的 IP %s 已被容器 %s 使用，容器 %s 需要它" % (name, ip, holder, c["name"]),
                container=c["name"], network=name)

# ---------- 端口 ----------
WILD = {"", "0.0.0.0", "::", "*", "[::]"}


def parse_listeners():
    found = []
    tool = None
    for proto, flag in (("tcp", "-Hltnp"), ("udp", "-Hlunp")):
        rc, out = run(["ss", flag])
        if rc != 0:
            rc, out = run(["ss", flag.replace("p", "")])
        if rc != 0:
            continue
        tool = "ss"
        for line in out.splitlines():
            cols = line.split()
            if len(cols) < 5:
                continue
            local = cols[3]
            host, _, port = local.rpartition(":")
            host = host.strip("[]").split("%")[0]
            proc = ""
            m = re.search(r'users:\(\("([^"]+)",pid=(\d+)', line)
            if m:
                proc = "%s（进程 %s）" % (m.group(1), m.group(2))
            if port.isdigit():
                found.append((proto, host, port, proc))
    return tool, found


tool, listeners = parse_listeners()
docker_ports = {}
for cname, e in existing.items():
    for m in re.finditer(r"([0-9a-fA-F:.\[\]]*):(\d+)->\d+/(tcp|udp)", e["ports"]):
        docker_ports.setdefault((m.group(3), m.group(2)), cname)


def port_holder(proto, host_ip, port):
    owner = docker_ports.get((proto, port))
    if owner:
        return "容器 %s" % owner, owner
    for p, host, lport, proc in listeners:
        if p == proto and lport == port and (host_ip in WILD or host in WILD or host == host_ip):
            if "docker-proxy" in proc:
                continue
            return proc or "其他程序", None
    return None, None


requested = set()
for c in containers:
    if c.get("network_mode", "") == "host" or c.get("network_mode", "").startswith("container:"):
        continue
    for p in c.get("ports", []):
        key = (c["name"], p.get("host_ip", ""), str(p["host_port"]), str(p["container_port"]), p.get("proto", "tcp"))
        port = port_map.get(key, str(p["host_port"]))
        if not port:
            continue
        requested.add((p.get("proto", "tcp"), port))
        holder, owner = port_holder(p.get("proto", "tcp"), p.get("host_ip", ""), port)
        if not holder:
            continue
        # 占用端口的正是将被替换的同名容器：恢复时它会先停止，不算冲突。
        if owner and owner in plan_names:
            continue
        busy = {(pr, po) for pr, _, po, _ in listeners} | set(docker_ports.keys()) | requested
        suggest = next((str(x) for x in range(int(port) + 1, min(int(port) + 200, 65536))
                        if (p.get("proto", "tcp"), str(x)) not in busy), "")
        add("ask", "port",
            "端口 %s 已被%s占用，%s需要使用它" % (port, cjk_spaced(holder),
                ("Compose 项目 %s 的容器 %s " % (c["project"], c["name"])) if c.get("project") else ("容器 %s " % c["name"])),
            container=c["name"], project=c.get("project", ""), host_ip=p.get("host_ip", ""),
            host_port=str(p["host_port"]), current_port=port, container_port=str(p["container_port"]),
            proto=p.get("proto", "tcp"), holder=holder, suggest=suggest)
if tool is None and any(c.get("ports") for c in containers):
    add("info", "port_unchecked", "新服务器没有 ss 命令，无法提前检查端口是否被占用")

need = max(base_need, bundle + docker_need)
json.dump({"issues": issues, "summary": {"containers": len(containers), "need_bytes": need}},
          sys.stdout, ensure_ascii=False)
PREFLIGHT_PY
}

# ---------- 恢复决定文件 ----------

preflight_decide() {
  local file="$1" filter="$2"
  shift 2
  local tmp="${file}.tmp.$$"
  [[ -s "$file" ]] || printf '{}\n' >"$file"
  jq "$@" "$filter" "$file" >"$tmp" && mv "$tmp" "$file"
}

# 读取一个选项编号；回车选默认值。非交互时直接使用默认值。
preflight_choose() {
  local max="$1" default="$2" answer
  while :; do
    printf '请选择 [%s]：' "$default" >&2
    read -r answer </dev/tty || answer=""
    answer="${answer:-$default}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= max)); then
      printf '%s\n' "$answer"
      return 0
    fi
    printf '请输入 1 到 %s 之间的数字。\n' "$max" >&2
  done
}

preflight_option() {
  printf '  %s) %s\n' "$1" "$2" >&2
}

# 处理一个“需要用户选择”的问题。返回 0 表示已处理（或选择了重新检查），
# 返回 1 表示用户选择取消。auto=1 时自动采用推荐做法，无法自动处理时返回 1。
preflight_resolve() {
  local issue="$1" decisions="$2" index="$3" total="$4" auto="$5"
  local kind title choice container project port new_port network volume
  kind="$(jq -r '.type' <<<"$issue")"
  title="$(jq -r '.title' <<<"$issue")"
  container="$(jq -r '.container // ""' <<<"$issue")"
  project="$(jq -r '.project // ""' <<<"$issue")"
  network="$(jq -r '.network // ""' <<<"$issue")"
  volume="$(jq -r '.volume // ""' <<<"$issue")"

  if [[ "$auto" != "1" ]]; then
    printf '\n问题 %s/%s：' "$index" "$total" >&2
  fi
  case "$kind" in
    port)
      port="$(jq -r '.current_port' <<<"$issue")"
      new_port="$(jq -r '.suggest // ""' <<<"$issue")"
      if [[ -n "$project" ]]; then
        if [[ "$auto" == "1" ]]; then
          log_line "无法自动处理：${title}"
          return 1
        fi
        printf '%s\n' "$(screen_color '1;33' "⚠️  端口被占用，Compose 项目 ${project} 无法启动")" >&2
        printf '  %s\n' "$title" >&2
        printf '  请自行停止占用端口的程序，或修改 %s 的 compose 文件中的端口后再继续。\n' "$project" >&2
        preflight_option 1 "我已处理好，重新检查（推荐）"
        preflight_option 2 "暂时跳过 ${project} 项目，继续迁移其他容器"
        preflight_option 3 "取消恢复"
        choice="$(preflight_choose 3 1)"
        case "$choice" in
          2) preflight_decide "$decisions" '.skip_projects = ((.skip_projects // []) + [$p] | unique) |
               .skipped_reasons = ((.skipped_reasons // []) + [{project: $p, reason: $r}])' \
            --arg p "$project" --arg r "端口 ${port} 被占用" ;;
          3) return 1 ;;
        esac
        return 0
      fi
      if [[ "$auto" == "1" ]]; then
        [[ -n "$new_port" ]] || return 1
        choice=1
      else
        printf '%s\n' "$title" >&2
        if [[ -n "$new_port" ]]; then
          preflight_option 1 "改用空闲端口 ${new_port}（推荐）"
        else
          preflight_option 1 "改用其他端口（附近没有找到空闲端口，需要手动输入）"
        fi
        preflight_option 2 "输入其他端口"
        preflight_option 3 "我先停掉占用端口的程序，然后重新检查"
        preflight_option 4 "不对外开放这个端口"
        preflight_option 5 "取消恢复"
        choice="$(preflight_choose 5 1)"
      fi
      if [[ "$choice" == 1 && -z "$new_port" ]] || [[ "$choice" == 2 ]]; then
        while :; do
          printf '新端口：' >&2
          read -r new_port </dev/tty || new_port=""
          [[ "$new_port" =~ ^[0-9]+$ ]] && ((new_port >= 1 && new_port <= 65535)) && break
          printf '请输入 1 到 65535 之间的端口号。\n' >&2
        done
        choice=1
      fi
      case "$choice" in
        1 | 4)
          [[ "$choice" == 1 ]] || new_port=""
          preflight_decide "$decisions" '
            .port_map = ([(.port_map // [])[] | select((.container == $c and .host_ip == $ip and
              .host_port == $hp and .container_port == $cp and .proto == $proto) | not)] +
              [{container: $c, host_ip: $ip, host_port: $hp, container_port: $cp, proto: $proto, new_port: $np}])' \
            --arg c "$container" --arg ip "$(jq -r '.host_ip' <<<"$issue")" \
            --arg hp "$(jq -r '.host_port' <<<"$issue")" --arg cp "$(jq -r '.container_port' <<<"$issue")" \
            --arg proto "$(jq -r '.proto' <<<"$issue")" --arg np "$new_port"
          ;;
        5) return 1 ;;
      esac
      ;;
    existing_container | existing_project)
      if [[ "$auto" == "1" ]]; then
        choice=1
      else
        printf '%s\n' "$title" >&2
        preflight_option 1 "替换它（推荐，迁移失败时会自动还原）"
        if [[ "$kind" == existing_project ]]; then
          preflight_option 2 "保留已有的，跳过这个项目"
        else
          preflight_option 2 "保留已有的，跳过这个容器"
        fi
        preflight_option 3 "取消恢复"
        choice="$(preflight_choose 3 1)"
      fi
      case "$kind:$choice" in
        existing_container:1) preflight_decide "$decisions" '.replace_containers = ((.replace_containers // []) + [$c] | unique)' --arg c "$container" ;;
        existing_container:2) preflight_decide "$decisions" '.skip_containers = ((.skip_containers // []) + [$c] | unique) |
          .skipped_reasons = ((.skipped_reasons // []) + [{container: $c, reason: "保留新服务器上已有的容器"}])' --arg c "$container" ;;
        existing_project:1) preflight_decide "$decisions" '.replace_projects = ((.replace_projects // []) + [$p] | unique)' --arg p "$project" ;;
        existing_project:2) preflight_decide "$decisions" '.skip_projects = ((.skip_projects // []) + [$p] | unique) |
          .skipped_reasons = ((.skipped_reasons // []) + [{project: $p, reason: "保留新服务器上已有的项目"}])' --arg p "$project" ;;
        *:3) return 1 ;;
      esac
      ;;
    ip_conflict | subnet_conflict | network_mismatch)
      if [[ "$auto" == "1" ]]; then
        choice=1
      else
        printf '%s\n' "$title" >&2
        case "$kind" in
          ip_conflict) preflight_option 1 "改为由 Docker 自动分配 IP（推荐）" ;;
          subnet_conflict) preflight_option 1 "让 Docker 自动选择一个不冲突的网段，网络里的容器改为自动分配 IP（推荐）" ;;
          network_mismatch) preflight_option 1 "继续使用新服务器上已有的这个网络，容器改为自动分配 IP（推荐）" ;;
        esac
        preflight_option 2 "取消恢复"
        choice="$(preflight_choose 2 1)"
      fi
      [[ "$choice" == 1 ]] || return 1
      case "$kind" in
        ip_conflict) preflight_decide "$decisions" '.auto_ip = ((.auto_ip // []) + [{container: $c, network: $n}] | unique)' \
          --arg c "$container" --arg n "$network" ;;
        subnet_conflict) preflight_decide "$decisions" '.auto_subnet = ((.auto_subnet // []) + [$n] | unique)' --arg n "$network" ;;
        network_mismatch) preflight_decide "$decisions" '.reuse_network = ((.reuse_network // []) + [$n] | unique)' --arg n "$network" ;;
      esac
      ;;
    volume_mismatch)
      [[ "$auto" != "1" ]] || return 1
      printf '%s\n' "$title" >&2
      preflight_option 1 "取消恢复，我先处理这个数据卷（推荐）"
      preflight_option 2 "保留已有的数据卷，不写入迁移过来的数据"
      choice="$(preflight_choose 2 1)"
      [[ "$choice" == 2 ]] || return 1
      preflight_decide "$decisions" '.keep_volumes = ((.keep_volumes // []) + [$v] | unique)' --arg v "$volume"
      ;;
    disk_base)
      [[ "$auto" != "1" ]] || return 1
      printf '%s\n' "$title" >&2
      preflight_option 1 "我先清理磁盘，然后重新检查（推荐）"
      preflight_option 2 "换一个目录存放下载文件"
      preflight_option 3 "取消恢复"
      choice="$(preflight_choose 3 1)"
      case "$choice" in
        2)
          local dir
          printf '目录（例如 /data/restore）：' >&2
          read -r dir </dev/tty || dir=""
          [[ "$dir" == /* ]] && preflight_decide "$decisions" '.restore_base = $d' --arg d "$dir"
          ;;
        3) return 1 ;;
      esac
      ;;
    disk_docker | disk_bind | *)
      [[ "$auto" != "1" ]] || return 1
      printf '%s\n' "$title" >&2
      preflight_option 1 "我先清理磁盘，然后重新检查（推荐）"
      preflight_option 2 "取消恢复"
      choice="$(preflight_choose 2 1)"
      [[ "$choice" == 1 ]] || return 1
      ;;
  esac
  return 0
}

# 运行预检，交互地处理问题，直到没有需要处理的问题。
# 返回 0 可以继续；返回 1 不能继续（失败原因已记录）。
# PREFLIGHT_NEED_BYTES、PREFLIGHT_CONTAINERS 会被设置，供阶段结果显示。
preflight_run() {
  local plan="$1" decisions="$2" base_dir="$3"
  local result asks stops i total row interactive=0 auto="${RESTORE_AUTO_RESOLVE:-0}" round=0
  local -A shown_infos=()
  [[ -s "$decisions" ]] || printf '{}\n' >"$decisions"
  if [[ -t 0 || -r /dev/tty ]] && [[ -t 2 ]]; then
    interactive=1
  fi
  while :; do
    round=$((round + 1))
    base_dir="$(jq -r --arg d "$base_dir" '.restore_base // $d' "$decisions")"
    if ! result="$(preflight_collect "$plan" "$decisions" "$base_dir" 2>>"${DM_LOG_FILE:-/dev/null}")"; then
      log_line "预检脚本运行失败，跳过预检"
      warn_user "预检没能完成，直接开始迁移（问题会在迁移过程中发现并自动回滚）"
      return 0
    fi
    log_line "预检结果（第 ${round} 轮）：${result}"
    # 供调用方在阶段结果中显示。
    export PREFLIGHT_NEED_BYTES PREFLIGHT_CONTAINERS
    PREFLIGHT_NEED_BYTES="$(jq -r '.summary.need_bytes // 0' <<<"$result")"
    PREFLIGHT_CONTAINERS="$(jq -r '.summary.containers // 0' <<<"$result")"
    while IFS= read -r row; do
      [[ -n "$row" && -z "${shown_infos[$row]:-}" ]] || continue
      shown_infos["$row"]=1
      warn_user "$row"
    done < <(jq -r '.issues[] | select(.level == "info") | .title' <<<"$result")

    stops="$(jq -c '[.issues[] | select(.level == "stop")]' <<<"$result")"
    if [[ "$(jq 'length' <<<"$stops")" -gt 0 ]]; then
      stage_hold
      printf '%s\n' "$(screen_color '1;31' '发现无法继续的问题，尚未下载或修改任何内容：')" >&2
      while IFS=$'\t' read -r row hint; do
        printf '  ✗ %s\n' "$row" >&2
        [[ -z "$hint" ]] || printf '    建议：%s\n' "$hint" >&2
      done < <(jq -r '.[] | [.title, .hint] | @tsv' <<<"$stops")
      fail_reason "$(jq -r '.[0].title' <<<"$stops")" "$(jq -r '.[0].hint' <<<"$stops")"
      return 1
    fi

    asks="$(jq -c '[.issues[] | select(.level == "ask")]' <<<"$result")"
    total="$(jq 'length' <<<"$asks")"
    ((total > 0)) || return 0

    if ((interactive == 0)) && [[ "$auto" != "1" ]]; then
      stage_hold
      printf '%s\n' "$(screen_color '1;33' "发现 ${total} 个需要处理的问题，尚未下载或修改任何内容：")" >&2
      while IFS=$'\t' read -r row hint; do
        printf '  ! %s\n' "$row" >&2
        [[ -z "$hint" ]] || printf '    建议：%s\n' "$hint" >&2
      done < <(jq -r '.[] | [.title, .hint] | @tsv' <<<"$asks")
      printf '处理后重新运行即可；也可以设置 RESTORE_AUTO_RESOLVE=1，自动采用推荐的处理方式（例如自动换一个空闲端口）。\n' >&2
      fail_reason "$(jq -r '.[0].title' <<<"$asks")" \
        "处理后重新运行；或设置 RESTORE_AUTO_RESOLVE=1 自动采用推荐做法（如自动换端口）"
      return 1
    fi

    if ((interactive == 1)) && [[ "$auto" != "1" ]]; then
      stage_hold
      printf '%s\n' "$(screen_color '1;33' "发现 ${total} 个需要处理的问题（尚未下载或修改任何内容）")" >&2
    fi
    for ((i = 0; i < total; i++)); do
      if ! preflight_resolve "$(jq -c ".[$i]" <<<"$asks")" "$decisions" "$((i + 1))" "$total" \
        "$([[ "$auto" == "1" ]] && echo 1 || echo 0)"; then
        fail_reason "$(jq -r ".[$i].title" <<<"$asks")" \
          "$([[ "$auto" == "1" ]] && echo "这个问题无法自动处理，请手动处理后重新运行" || echo "处理后重新粘贴同一个链接即可继续")"
        return 1
      fi
    done
    # 自动处理只做一轮：再次检查仍有问题时交给用户。
    if [[ "$auto" == "1" ]] && ((round >= 2)); then
      auto=0
      ((interactive == 1)) || {
        fail_reason "自动处理后仍有问题没有解决" "查看日志了解详情"
        return 1
      }
    fi
    printf '\n重新检查……\n' >&2
  done
}

# 恢复结果中列出预检时做的调整，让用户知道哪些地方和旧服务器不同。
print_decision_summary() {
  local decisions="${1:-}"
  [[ -n "$decisions" && -s "$decisions" ]] || return 0
  jq -r '
    ([.port_map[]? | if .new_port == "" then
        "不再对外开放：\(.container) 的端口 \(.host_port)"
      else "端口变更：\(.container) \(.host_port) → \(.new_port)" end]) +
    ([.skipped_reasons[]? | if .project then "⚠️ 未迁移：Compose 项目 \(.project)（\(.reason)）"
      else "⚠️ 未迁移：容器 \(.container)（\(.reason)）" end]) +
    ([.auto_ip[]? | "自动分配 IP：\(.container) 在网络 \(.network) 中"]) +
    ([.auto_subnet[]? | "自动选择网段：网络 \(.)"]) +
    ([.reuse_network[]? | "沿用新服务器已有网络：\(.)"]) +
    ([.keep_volumes[]? | "保留已有数据卷、未写入迁移数据：\(.)"]) | .[]' "$decisions" 2>/dev/null
  if jq -e '(.skipped_reasons // []) | any(.project)' "$decisions" >/dev/null 2>&1; then
    printf '   处理好之后，在新服务器重新粘贴同一个链接即可补上（旧服务器的传输服务需要仍在运行）。\n'
  fi
}

# 恢复决定：迁移前预检中用户（或 RESTORE_AUTO_RESOLVE）做出的选择，由
# DM_RESTORE_DECISIONS 指向的 JSON 文件传给恢复脚本与单容器恢复脚本。
# 没有这个文件时所有查询都返回“没有特别决定”，恢复按原配置进行。

decisions_present() {
  [[ -n "${DM_RESTORE_DECISIONS:-}" && -s "${DM_RESTORE_DECISIONS}" ]]
}

# decision_listed 列表名 值：值是否在决定文件的某个列表里（如 skip_projects）。
decision_listed() {
  decisions_present || return 1
  jq -e --arg k "$1" --arg v "$2" '(.[$k] // []) | index($v) != null' \
    "$DM_RESTORE_DECISIONS" >/dev/null 2>&1
}

# 容器在某个网络中是否改为自动分配 IP（单独选择、网段改为自动或沿用已有网络时都是）。
decision_auto_ip() {
  local container="$1" network="$2"
  decisions_present || return 1
  jq -e --arg c "$container" --arg n "$network" '(.auto_ip // []) | any(.container == $c and .network == $n)' \
    "$DM_RESTORE_DECISIONS" >/dev/null 2>&1 ||
    decision_listed auto_subnet "$network" || decision_listed reuse_network "$network"
}

# 端口映射的新宿主机端口；输出为空表示不再对外开放；没有调整时返回 1。
decision_port() {
  local container="$1" host_ip="$2" host_port="$3" container_port="$4" proto="$5"
  decisions_present || return 1
  jq -er --arg c "$container" --arg ip "$host_ip" --arg hp "$host_port" \
    --arg cp "$container_port" --arg proto "$proto" '
    [(.port_map // [])[] | select(.container == $c and .host_ip == $ip and .host_port == $hp and
      .container_port == $cp and .proto == $proto) | .new_port] | first // empty | tostring' \
    "$DM_RESTORE_DECISIONS" 2>/dev/null || {
    jq -e --arg c "$container" --arg ip "$host_ip" --arg hp "$host_port" \
      --arg cp "$container_port" --arg proto "$proto" '
      (.port_map // []) | any(.container == $c and .host_ip == $ip and .host_port == $hp and
        .container_port == $cp and .proto == $proto and .new_port == "")' \
      "$DM_RESTORE_DECISIONS" >/dev/null 2>&1 || return 1
    printf '\n'
  }
}

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
RESTORE_ACTIVE_DATA_LOG=""

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
  elapsed="$(format_elapsed "$((SECONDS - RESTORE_STARTED_AT))")"
  container_line=""
  data_line=""
  if [[ "$status" == "SUCCESS" ]]; then
    metrics="$(collect_restore_result_metrics "$BUNDLE_DIR")"
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
      print_stage_timings
      print_warning_summary
      ;;
    FAILED_ROLLED_BACK)
      printf '结果：❌ 恢复失败，已安全回滚\n失败阶段：%s\n' "$RESTORE_STAGE"
      printf '新服务器：原来的服务和数据已还原\n诊断目录：%s\n' "$BUNDLE_DIR"
      ;;
    INTERRUPTED_ROLLED_BACK)
      printf '结果：⚠️ 恢复已中断，已安全回滚\n中断阶段：%s\n' "$RESTORE_STAGE"
      printf '新服务器：原来的服务和数据已还原\n诊断目录：%s\n' "$BUNDLE_DIR"
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
  printf '耗时：%s\n' "$elapsed"
  print_decision_summary "${DM_RESTORE_DECISIONS:-}"
  if [[ "$status" != "SUCCESS" ]]; then
    print_warning_summary
    print_failure_details
  fi
  printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

restore_finish_result() {
  local status="$1" rollback_dir="${2:-}"
  restore_record_result "$status" "$rollback_dir" || true
  [[ "$status" == "SUCCESS" ]] || stage_fail
  if [[ "${RESTORE_DEFER_FINAL_SUMMARY:-0}" != "1" ]]; then
    restore_print_final_result "$status" "$rollback_dir"
  fi
  if [[ "$status" == "SUCCESS" ]]; then
    log_finish 1
  else
    log_finish 0
  fi
}

restore_nontransaction_exit_handler() {
  local rc=$? status="FAILED" rollback_dir="${RESTORE_TRANSACTION_DIR:-}"
  trap - EXIT INT TERM
  restore_diagnostic_output
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
  ((${#FAILED_VOLUMES[@]} > 0 || \
  ${#FAILED_BINDS[@]} > 0 || \
  ${#FAILED_NETWORKS[@]} > 0 || \
  ${#FAILED_PROJECTS[@]} > 0 || \
  ${#FAILED_CONTAINERS[@]} > 0))
}

# 失败项写入日志；没有更具体的原因时，用失败项本身作为失败原因。
print_failure_summary() {
  local items=""
  restore_has_failures || return 0
  ((${#FAILED_VOLUMES[@]} == 0)) || items+="数据卷 ${FAILED_VOLUMES[*]}；"
  ((${#FAILED_BINDS[@]} == 0)) || items+="挂载目录 ${FAILED_BINDS[*]}；"
  ((${#FAILED_NETWORKS[@]} == 0)) || items+="网络 ${FAILED_NETWORKS[*]}；"
  ((${#FAILED_PROJECTS[@]} == 0)) || items+="Compose 项目 ${FAILED_PROJECTS[*]}；"
  ((${#FAILED_CONTAINERS[@]} == 0)) || items+="容器 ${FAILED_CONTAINERS[*]}；"
  log_line "恢复失败的项目：${items%；}"
  fail_reason "恢复失败：${items%；}" "查看下方日志中的最后几行了解详情"
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
    dm_quiet docker image rm "$image" || true
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
        warn " · 新服务器上已有项目的 Compose 文件找不到（${file}），无法先备份它，已停止"
        return 1
      }
      config_args+=(-f "$file")
    done
  fi

  if [[ -n "$old_wdir" ]]; then
    if ! (cd "$old_wdir" && compose_run -p "$project" "${config_args[@]}" config) \
      >"${rollback_dir}/config.yml" 2>/dev/null; then
      warn " · 新服务器上已有的 Compose 项目 ${project} 配置无法读取，为避免损坏它，已停止"
      return 1
    fi
  elif ! compose_run -p "$project" "${config_args[@]}" config \
    >"${rollback_dir}/config.yml" 2>/dev/null; then
    warn " · 新服务器上已有的 Compose 项目 ${project} 找不到所在目录，无法先备份它，已停止"
    return 1
  fi

  printf '{"services":{}}\n' >"${rollback_dir}/images.yml"
  : >"${rollback_dir}/images.list"
  : >"${rollback_dir}/states.tsv"
  for id in "${ids[@]}"; do
    service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$id" 2>/dev/null || true)"
    [[ -n "$service" ]] || {
      warn " · 新服务器上的容器 ${id} 缺少 Compose 服务名，无法备份"
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
      warn " · 备份过程中，新服务器上的 Compose 服务 ${service} 的容器不见了"
      compose_rollback_image_cleanup "$rollback_dir"
      return 1
    fi
    image="docker-migrate-rollback:${id:0:12}-$$"
    if ! run_with_activity "创建 Compose 回滚镜像：$service" \
      dm_quiet docker commit "$id" "$image"; then
      warn " · Compose 服务 ${service} 的容器没能备份"
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
        dm_quiet docker start "$id" || rc=1
        ;;
      paused)
        dm_quiet docker start "$id" || {
          rc=1
          continue
        }
        dm_quiet docker pause "$id" || rc=1
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
    compose_run -p "$project" -f config.yml -f images.yml up --no-start >>"${DM_LOG_FILE:-/dev/null}" 2>&1
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
      ((${#start_services[@]} == 0)) ||
        compose_run -p "$project" -f config.yml -f images.yml start "${start_services[@]}" \
          >>"${DM_LOG_FILE:-/dev/null}" 2>&1
      for service in "${pause_services[@]}"; do
        while IFS= read -r id; do
          [[ -n "$id" ]] || continue
          dm_quiet docker pause "$id"
        done < <(compose_run -p "$project" -f config.yml -f images.yml ps -q "$service" 2>>"${DM_LOG_FILE:-/dev/null}")
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
            fail_reason "Compose 服务 ${service} 健康检查没有通过（当前 ${status}）" "执行 docker logs <容器名> 查看服务日志"
            return 1
            ;;
          *)
            all_ready=0
            pending=$((pending + 1))
            [[ -n "$first_pending" ]] || first_pending="$service（${status:-未知}）"
            ;;
        esac
      done < <(compose_run "${compose_args[@]}" ps -q "$service" 2>>"${DM_LOG_FILE:-/dev/null}")
      if ((service_found == 0)); then
        all_ready=0
        pending=$((pending + 1))
        [[ -n "$first_pending" ]] || first_pending="$service（未找到容器）"
      fi
    done
    if ((all_ready == 0)); then
      elapsed=$((SECONDS - started))
      if ((elapsed >= next_report)); then
        log_line "[进度] Compose 服务健康检查：${services[*]} · 待就绪 ${pending} 个 · ${first_pending:-未知} · ${elapsed}/${timeout}秒"
        next_report=$((elapsed + 5))
      fi
    else
      log_line "[完成] Compose 服务健康检查：${services[*]} · $((SECONDS - started))秒"
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
          fail_reason "Compose 项目 ${project} 的容器 ${id} 健康检查没有通过" "执行 docker logs ${id} 查看服务日志"
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
        log_line "[进度] Compose 项目健康检查：$project · 待就绪 ${pending} 个 · ${first_pending:-未知} · ${elapsed}/${timeout}秒"
        next_report=$((elapsed + 5))
      fi
    else
      log_line "[完成] Compose 项目健康检查：$project · $((SECONDS - started))秒"
      return 0
    fi
    sleep 1
  done
  return 1
}

# 匿名卷（没写名字、只有一串随机编号的卷）在新服务器上按原编号恢复了数据，但
# Compose 不认识它，会给新容器另建一个空的匿名卷。把数据搬进新卷，再删掉按原
# 编号恢复的卷；否则这些数据（例如镜像声明的数据库目录）在新服务器上就丢了。
compose_transplant_anonymous_volumes() {
  local project="$1" meta cname src dest dst
  for meta in "${BUNDLE_DIR}"/meta/*.inspect.json; do
    [[ -f "$meta" ]] || continue
    [[ "$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$meta")" == "$project" ]] || continue
    cname="$(jq -r '.[0].Name | ltrimstr("/")' "$meta")"
    while IFS=$'\t' read -r src dest; do
      [[ "$src" =~ ^[0-9a-f]{64}$ ]] || continue
      docker volume inspect "$src" >/dev/null 2>&1 || continue
      dst="$(docker inspect "$cname" 2>/dev/null | jq -r --arg d "$dest" \
        '.[0].Mounts[]? | select(.Type == "volume" and .Destination == $d) | .Name' | head -n1)"
      [[ -n "$dst" && "$dst" != "$src" ]] || continue
      log_line "匿名卷：${cname} 的 ${dest} 沿用迁移过来的数据"
      dm_quiet docker run --rm --network none -v "${src}:/from:ro" -v "${dst}:/to" alpine:3.20 \
        sh -eu -c 'find /to -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; cp -a /from/. /to/' || return 1
      dm_quiet docker volume rm "$src" || true
    done < <(jq -r '.[0].Mounts[]? | select(.Type == "volume") | [.Name, .Destination] | @tsv' "$meta")
  done
}
archive_members_safe() {
  # 只解析元数据，不访问软链接目标。完整建表后检查，避免归档通过成员顺序
  # 或路径重名，让解压程序沿链接写出目标树。gzip 只解压扫描一次。
  python3 - "$1" "${2:-}" <<'ARCHIVE_PY'
import gzip
import sys
import tarfile
import zlib


def archive_path(raw):
    parts = raw.split("/")
    if raw.startswith("/") or ".." in parts or "\0" in raw:
        raise ValueError("拒绝归档中的绝对或越界成员路径：" + repr(raw))
    return "/".join(part for part in parts if part not in ("", "."))


try:
    prefix = archive_path(sys.argv[2])
    members = {}

    def scoped_path(raw):
        name = archive_path(raw)
        if prefix and name != prefix and not name.startswith(prefix + "/"):
            raise ValueError("归档成员超出绑定路径：" + repr(raw))
        return name

    with gzip.open(sys.argv[1], "rb") as compressed:
        with tarfile.open(fileobj=compressed, mode="r:") as archive:
            for member in archive:
                name = scoped_path(member.name)
                if member.size < 0:
                    raise ValueError("归档成员长度不能为负数：" + repr(name))
                if member.isdir():
                    kind, target = "dir", ""
                elif member.issym():
                    # 绝对、外部、悬空乃至循环软链接均可原样保存；不解引用。
                    if not member.linkname or "\0" in member.linkname:
                        raise ValueError("软链接目标为空或包含空字节：" + repr(name))
                    kind, target = "symlink", member.linkname
                elif member.islnk():
                    kind, target = "hardlink", scoped_path(member.linkname)
                elif member.isreg() and member.sparse is None:
                    kind, target = "file", ""
                elif member.isfifo():
                    kind, target = "fifo", ""
                else:
                    raise ValueError("不支持的归档成员类型（设备或稀疏格式）：" + repr(name))
                if not name and kind != "dir":
                    raise ValueError("归档根必须是目录")
                if name in members and not (kind == members[name][0] == "dir"):
                    raise ValueError("拒绝重复或改变类型的归档成员：" + repr(name))
                members[name] = (kind, target)
                # 仅保留安全检查所需的信息，不重复缓存完整 TarInfo 对象。
                archive.members.clear()
            # tar 遇到结束块即停止，但 gzip 校验码在流末尾；必须读完尾部。
            # 同时拒绝结束块后藏有另一个归档或非零记录，消除解析器歧义。
            compressed.seek(archive.offset)
            while True:
                padding = compressed.read(1024 * 1024)
                if not padding:
                    break
                if padding.strip(b"\0"):
                    raise ValueError("归档结束标记后存在额外数据")

    for name in members:
        parent = name.rpartition("/")[0]
        while parent:
            if parent in members and members[parent][0] != "dir":
                raise ValueError("拒绝通过链接或非目录写入：%r（父路径：%r）" % (name, parent))
            parent = parent.rpartition("/")[0]

    # 硬链接会访问目标 inode，与只保存目标字符串的软链接不同。
    # 允许内部硬链接链，但最终必须指向同一归档内的普通文件。
    resolved = {name for name, (kind, _) in members.items() if kind == "file"}
    for name, (kind, _) in members.items():
        if kind != "hardlink":
            continue
        current, chain = name, set()
        while current not in resolved:
            if current in chain:
                raise ValueError("拒绝循环硬链接：" + repr(name))
            chain.add(current)
            node = members.get(current)
            if node is None or node[0] != "hardlink":
                raise ValueError("硬链接必须指向归档内的普通文件：%r -> %r" % (name, current))
            current = node[1]
        resolved.update(chain)

    if prefix and (prefix not in members or members[prefix][0] not in ("dir", "file")):
        raise ValueError("绑定路径根必须是普通文件或目录：" + repr(prefix))
except (OSError, EOFError, ValueError, tarfile.TarError, zlib.error) as error:
    print("归档预检失败：%s：%s" % (sys.argv[1], error), file=sys.stderr)
    sys.exit(1)
ARCHIVE_PY
}

archive_normalized_stream() {
  # 只用于已完成结构预检的归档。Python 与 BusyBox 对 PAX/GNU 扩展头的
  # 优先级、size 等字段存在差异；不把原始头交给第二个解析器。用同一个
  # tarfile 解析器生成明确的 GNU tar 流，再交给隔离容器保存权限和属主。
  python3 - "$1" <<'STREAM_PY'
import copy
import posixpath
import sys
import tarfile

try:
    with tarfile.open(sys.argv[1], "r:gz") as source:
        with tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.GNU_FORMAT,
                          copybufsize=1024 * 1024) as output:
            for original in source:
                member = copy.copy(original)
                member.name = posixpath.normpath(member.name)
                member.pax_headers = {}
                if member.islnk():
                    member.linkname = posixpath.normpath(member.linkname)
                elif not member.issym():
                    # BusyBox 会把带 linkname 的零字节普通文件误当硬链接。
                    member.linkname = ""
                if member.isreg():
                    member.type = tarfile.REGTYPE
                    with source.extractfile(original) as payload:
                        output.addfile(member, payload)
                else:
                    member.size = 0
                    output.addfile(member)
                source.members.clear()
except (OSError, EOFError, ValueError, tarfile.TarError) as error:
    print("归档读取失败：%s" % error, file=sys.stderr)
    sys.exit(1)
STREAM_PY
}
volume_clear_and_extract() {
  local volume="$1" archive_dir="$2" archive_file="$3" prechecked="${4:-0}"
  # 来自恢复入口的归档已经在停机前预检；本地回滚包仍须先验证再清空卷。
  [[ "$prechecked" == "1" ]] || archive_members_safe "${archive_dir}/${archive_file}" || return 1
  printf '清空并解压命名卷：%s（归档：%s）\n' "$volume" "$archive_file" >&2
  if ! archive_normalized_stream "${archive_dir}/${archive_file}" |
    docker run --rm -i --read-only --network none \
      --security-opt no-new-privileges --cap-drop MKNOD \
      -v "${volume}:/to" \
      alpine:3.20 sh -eu -c '
      find /to -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
      tar -xf - -C /to
    ' sh "$archive_file"; then
    return 1
  fi
  return 0
}

restore_volume_exact() {
  local volume="$1" archive_dir="$2" archive_file="$3" rollback_dir="$4" existed="$5"
  local prechecked="${6:-0}"
  local rollback_file="rollback_${volume}.tgz"
  [[ "$prechecked" == "1" ]] || archive_members_safe "${archive_dir}/${archive_file}" || return 1
  mkdir -p "$rollback_dir"
  if ((existed == 1)); then
    printf '先备份新服务器上原有的数据卷：%s\n' "$volume" >&2
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

  warn " 数据卷 ${volume} 恢复失败，正在还原原来的数据"
  if [[ -n "${RESTORE_TRANSACTION_DIR:-}" ]]; then
    # 全局事务持有回滚包；不要提前删除，让统一回滚按确定顺序处理。
    return 1
  fi
  if ((existed == 1)); then
    volume_clear_and_extract "$volume" "$rollback_dir" "$rollback_file" 0 || return 1
    rm -f "${rollback_dir}/${rollback_file}"
  else
    dm_quiet docker volume rm "$volume" || true
  fi
  return 1
}

restore_data_with_diagnostics() {
  # RESTORE_ACTIVE_DATA_LOG 必须是全局变量：bash 4.0/4.1 在函数内 exit 时会先
  # 撤销 local 再执行 EXIT trap，trap 将读不到日志路径。
  local label="$1" logfile rc
  shift
  # 有运行日志时，数据操作的输出直接追加进去；失败原因由调用方统一说明。
  if [[ -n "${DM_LOG_FILE:-}" ]]; then
    log_line "开始：${label}"
    RESTORE_ACTIVE_DATA_LOG="$DM_LOG_FILE"
    if "$@" >>"$DM_LOG_FILE" 2>&1; then
      RESTORE_ACTIVE_DATA_LOG=""
      return 0
    else
      rc=$?
    fi
    RESTORE_ACTIVE_DATA_LOG=""
    log_line "失败：${label}（退出码 ${rc}）"
    return "$rc"
  fi
  # 日志置于迁移包旁，不混入包内校验清单，也不随事务回滚点一起删除。
  # mktemp + umask 077 防止覆盖已有路径或泄露数据库文件信息。
  logfile="$(mktemp "${BUNDLE_DIR}/../docker-migrate-data.XXXXXX")" || {
    warn "无法创建恢复诊断日志，尚未执行：$label"
    return 1
  }
  RESTORE_ACTIVE_DATA_LOG="$logfile"
  if "$@" >"$logfile" 2>&1; then
    RESTORE_ACTIVE_DATA_LOG=""
    rm -f "$logfile" || true
    return 0
  else
    rc=$?
  fi
  RESTORE_ACTIVE_DATA_LOG=""
  printf '\n[错误详情] %s（退出码：%s）\n' "$label" "$rc" >&2
  tail -n 20 "$logfile" >&2
  printf '详细日志：%s\n' "$logfile" >&2
  return "$rc"
} 202>&1 203>&2

restore_diagnostic_output() {
  # 数据操作中收到信号时，EXIT trap 仍处于日志重定向内。切回调用前的
  # 输出，确保手动恢复模式下也能看见回滚进度和最终结果。
  if [[ -n "${RESTORE_ACTIVE_DATA_LOG:-}" ]]; then
    exec 1>&202 2>&203
    [[ "$RESTORE_ACTIVE_DATA_LOG" == "${DM_LOG_FILE:-}" ]] ||
      printf '详细日志：%s\n' "$RESTORE_ACTIVE_DATA_LOG" >&2
  fi
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
  local host="$1" archive="$2" prechecked="${3:-0}"
  local parent base stage old staged had_old=0
  [[ "$host" == /* && "$host" != "/" ]] || return 1
  [[ "$prechecked" == "1" ]] || archive_members_safe "$archive" "${host#/}" || return 1
  parent="$(dirname "$host")"
  base="$(basename "$host")"
  stage="${parent}/.${base}.docker-migrate-stage-$$"
  old="${parent}/.${base}.docker-migrate-old-$$"

  root_exec mkdir -p "$parent" || return 1
  root_exec rm -rf "$stage" "$old" || return 1
  root_exec mkdir -p "$stage" || return 1
  # 结构预检保证成员不穿过链接写入；仅目标 staging 可写，容器根只读。
  printf '解压绑定目录：%s（归档：%s）\n' "$host" "$archive" >&2
  if ! archive_normalized_stream "$archive" |
    docker run --rm -i --read-only --network none \
      --security-opt no-new-privileges --cap-drop MKNOD \
      -v "${stage}:/stage" \
      alpine:3.20 tar -C /stage -xf -; then
    root_exec rm -rf "$stage" || true
    return 1
  fi
  staged="${stage}/${host#/}"
  if ! root_exec test -e "$staged" && ! root_exec test -L "$staged"; then
    warn "归档中缺少绑定目录：$host"
    root_exec rm -rf "$stage" || true
    return 1
  fi
  # bind 根本身若是链接，移动出 staging 后其相对语义会改变；拒绝这种歧义结构。
  if root_exec test -L "$staged"; then
    warn "拒绝使用符号链接作为绑定目录根：$host"
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

# 源端 bind 是软链接时，数据已恢复到真实路径；在原路径重建同一个链接，
# 让容器按原挂载路径看到数据。新建的链接登记进 binds.tsv，回滚时删除。
restore_bind_link() {
  local link="$1" host="$2" current
  [[ -n "$link" ]] || return 0
  if root_exec test -L "$link"; then
    current="$(root_exec readlink "$link" 2>/dev/null || true)"
    [[ "$current" != "$host" ]] || return 0
    current="$(root_exec readlink -f "$link" 2>/dev/null || true)"
    [[ -z "$current" || "$current" != "$(root_exec readlink -f "$host" 2>/dev/null || true)" ]] ||
      return 0
    warn " 新服务器上已有同名软链接 ${link}，但它指向 ${current:-未知}（应该指向 ${host}）"
    return 1
  fi
  if root_exec test -e "$link"; then
    warn " 新服务器上的 ${link} 已存在且不是软链接，无法让它指向迁移过来的目录 ${host}"
    return 1
  fi
  if [[ -n "${RESTORE_TRANSACTION_DIR:-}" ]]; then
    printf '%s\t0\t\n' "$link" >>"${RESTORE_TRANSACTION_DIR}/binds.tsv" || return 1
  fi
  root_exec mkdir -p "$(dirname "$link")" || return 1
  root_exec ln -s "$host" "$link"
}

# 按预检时的选择跳过的项目或容器所独占的数据卷与目录（每行“volume<TAB>名称”
# 或“bind<TAB>路径”）。与其他容器共用的数据照常恢复。
restore_skipped_mounts() {
  decisions_present || return 0
  jq -rs --slurpfile d "$DM_RESTORE_DECISIONS" '
    ($d[0].skip_projects // []) as $sp | ($d[0].skip_containers // []) as $sc |
    [.[] | .[0] | {
      skipped: ((($sp | index(.Config.Labels["com.docker.compose.project"] // "")) != null) or
        (($sc | index(.Name | ltrimstr("/"))) != null)),
      mounts: [.Mounts[]? | if .Type == "volume" then "volume\t\(.Name)"
        elif .Type == "bind" then "bind\t\(.Source)" else empty end]
    }] as $all |
    (([$all[] | select(.skipped) | .mounts[]] | unique) -
     ([$all[] | select(.skipped | not) | .mounts[]] | unique))[]
  ' meta/*.inspect.json 2>/dev/null || true
}

restore_mount_skipped() {
  [[ -n "${RESTORE_SKIPPED_MOUNTS:-}" ]] || return 1
  grep -Fxq -- "$1"$'\t'"$2" <<<"$RESTORE_SKIPPED_MOUNTS"
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
    if dm_quiet docker network rm "$network_name"; then
      log_line "已清理旧网络：$network_name"
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
    : >"$tmp_cfg"
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
        network_row="$(jq -c --arg name "$net" '.networks[]? | select(.name == $name)' \
          "${BUNDLE_DIR}/manifest.json" | head -n1)"
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
          warn " · 迁移包里没有网络 ${net} 的设置，沿用新服务器上已有的这个网络"
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

  if ((seen == 0)); then
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
  # 迁移前预检中选择了沿用新服务器上已有的同名网络。
  if decision_listed reuse_network "$name" && docker network inspect "$name" >/dev/null 2>&1; then
    log_line "按预检时的选择沿用已有网络：$name"
    return 0
  fi

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
      warn " 网络 ${name} 已存在，只是标签和旧服务器不同，直接沿用，不做修改"
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
    # 迁移前预检中选择了让 Docker 自动选择网段。
    decision_listed auto_subnet "$name" && break
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

  dm_quiet "${create_args[@]}"
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
      warn "另一个恢复任务正在运行，请等它结束后再试。"
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
      warn "另一个恢复任务正在运行，请等它结束后再试。"
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
      { exec 201>&-; } 2>/dev/null || true
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
    "迁移包所在目录" "$BUNDLE_DIR"
    "还原资料目录" "$rollback_base"
    "锁文件目录" "$lock_base"
  )
  if [[ -n "${RESTORE_SESSION_DIR:-}" ]]; then
    protected_paths+=("下载目录" "$RESTORE_SESSION_DIR")
  fi

  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    bind_path_is_system "$host" && continue
    normalized_host="$(transaction_normalize_path "$host")" || return 1
    for ((protected_i = 0; protected_i < ${#protected_paths[@]}; protected_i += 2)); do
      label="${protected_paths[$protected_i]}"
      protected="${protected_paths[$((protected_i + 1))]}"
      normalized_protected="$(transaction_normalize_path "$protected")" || return 1
      if mount_paths_overlap "$normalized_host" "$normalized_protected"; then
        warn "挂载目录 ${host} 和${label}重叠，为避免覆盖，已在改动数据前停止"
        warn "重叠的位置：$normalized_protected"
        warn "请把 RESTORE_BASE、RESTORE_ROLLBACK_BASE、RESTORE_LOCK_BASE 设置到这个目录之外后重试。"
        return 1
      fi
    done
  done < <(jq -r '.binds[] | .host, (.link // empty)' manifest.json)
}
transaction_container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

transaction_restore_container_state() {
  local name="$1" state="$2"
  case "$state" in
    running | restarting)
      run_with_activity "启动目标端旧容器：$name" dm_quiet docker start "$name" || return 1
      [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" == "true" ]]
      ;;
    paused)
      run_with_activity "启动目标端旧容器：$name" dm_quiet docker start "$name" || return 1
      dm_quiet docker pause "$name"
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
    [[ "$state" != "paused" ]] || dm_quiet docker unpause "$name" || return 1
    case "$state" in
      running | restarting | paused) stop_names+=("$name") ;;
    esac
  done
  ((${#stop_names[@]} > 0)) || return 0

  run_with_activity "批量停止目标端容器（${#stop_names[@]} 个）" \
    dm_quiet docker stop "${stop_names[@]}" || stop_rc=$?
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
            dm_quiet docker rm -f "$name" || true
            if transaction_container_exists "$name"; then
              warn " · 本次新建的容器 ${name} 没能停止并删除"
              rc=1
            fi
          fi
        elif transaction_container_exists "$name"; then
          # WAL 已写入但 rename 尚未发生；当前仍是原容器，不删除。
          :
        else
          warn " · 容器 ${name} 和它的备份都找不到了"
          rc=1
        fi
      elif [[ "$had_old" == "0" ]]; then
        dm_quiet docker rm -f "$name" || true
        if transaction_container_exists "$name"; then
          warn " · 本次新建的容器 ${name} 没能停止并删除"
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
        dm_quiet docker rm -f "$id" || rc=1
      done < <(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}')
      if [[ -n "$(docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --format '{{.ID}}')" ]]; then
        warn " · Compose 项目 ${project} 还有容器没能删除，为安全起见没有还原旧数据"
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
        warn " · 数据卷 ${volume} 没能还原"
        rc=1
      fi
    elif docker volume inspect "$volume" >/dev/null 2>&1 && ! dm_quiet docker volume rm "$volume"; then
      warn " · 本次新建的数据卷 ${volume} 没能删除"
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
        warn " · 目录 ${host} 和它的备份都找不到了"
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
        dm_quiet docker rm -f "$name" || true
        if ! rename_container_with_retry "$backup" "$name"; then
          warn " · 旧容器 ${name} 没能改回原名，它现在叫 ${backup}"
          rc=1
          continue
        fi
        restored_from_backup=1
      elif ! transaction_container_exists "$name"; then
        warn " · 旧容器 ${name} 和它的备份都找不到了"
        rc=1
        continue
      fi
      if ((restored_from_backup == 1)); then
        network_file="${RESTORE_TRANSACTION_DIR}/standalone_networks/${name}.json"
        if ! restore_container_networks "$name" "$network_file"; then
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
        warn " · Compose 项目 ${project} 没能自动还原，还原资料在：${rollback_dir}"
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
      if ! dm_quiet docker rm -f "$backup"; then
        if ! docker info >/dev/null 2>&1 || transaction_container_exists "$backup"; then
          warn " · 用于还原的旧容器 ${backup} 没能删除"
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
        if ! dm_quiet docker image rm "$image"; then
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
        warn " · 用于还原的旧目录 ${old} 没能删除"
        rc=1
      fi
    done <"${RESTORE_TRANSACTION_DIR}/binds.tsv"
  fi
  if ! root_exec rm -rf "${RESTORE_TRANSACTION_DIR}/file_backups"; then
    warn " · 临时备份文件没能删除：${RESTORE_TRANSACTION_DIR}/file_backups"
    rc=1
  fi

  # 清理失败时保留所有事务清单。提交后的 EXIT handler 会将该目录报告为
  # FAILED_POST_COMMIT 的待清理资料，便于定位尚未删除的回滚点。
  return "$rc"
}

transaction_rollback() {
  local name state project had_old services_quiet=1 data_ok=1 rc=0 preserve_compose=0
  ((TRANSACTION_ACTIVE == 1)) || return 0
  warn "恢复失败，正在把服务和数据还原到恢复前的状态……"

  # 提交阶段若某个共享写入者重启失败，先重新静默已经启动的写入者。
  if [[ -f "${RESTORE_TRANSACTION_DIR}/shared.tsv" ]]; then
    while IFS=$'\t' read -r name state; do
      [[ -n "$name" ]] || continue
      transaction_quiesce_container "$name" >/dev/null || true
    done <"${RESTORE_TRANSACTION_DIR}/shared.tsv"
  fi

  run_with_activity "自动回滚：停止并移除本次新服务" \
    transaction_remove_new_services || services_quiet=0
  if ((services_quiet == 1)); then
    # 目标文件最后写入、但可能位于已替换 bind 内；严格按修改逆序回滚，
    # 先撤销单文件覆盖，再整体换回 bind，最后恢复 volume。
    run_with_activity "自动回滚：恢复被替换的配置文件" \
      transaction_restore_files || data_ok=0
    run_with_activity "自动回滚：恢复绑定目录数据" \
      transaction_restore_binds || data_ok=0
    run_with_activity "自动回滚：恢复命名卷数据" \
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
    warn "新启动的容器没能全部停止，为安全起见没有还原旧数据，还原资料已全部保留，请人工处理。"
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
        warn "部分还原资料没能清理，已保留在：$RESTORE_TRANSACTION_DIR"
      fi
      warn "新服务器上原来的服务和数据已经全部还原。"
      warn "Compose 回滚配置需随旧容器保留：$RESTORE_TRANSACTION_DIR"
    else
      if transaction_cleanup_artifacts; then
        rm -rf "$RESTORE_TRANSACTION_DIR" ||
          warn "已还原到恢复前的状态，但临时文件夹没能删除：$RESTORE_TRANSACTION_DIR"
      else
        warn "回滚已完成，但部分无用回滚资料未能清理：$RESTORE_TRANSACTION_DIR"
      fi
      warn "新服务器上原来的服务和数据已经全部还原。"
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
  restore_diagnostic_output

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
    warn "新服务器上已经有同名的服务，RESTORE_EXISTING=fail 不允许替换，已停止（没有改动任何数据）。"
    transaction_release_lock
    trap restore_nontransaction_exit_handler EXIT
    return 1
  fi
  if [[ "$policy" == "skip" && "$has_data" == "1" && "$existing_targets" -gt 0 ]]; then
    warn "RESTORE_EXISTING=skip 时无法判断共用的数据属于谁；迁移包里有数据卷或目录，为避免覆盖已有数据，已停止。"
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
      warn "新服务器没有安装 Docker Compose，已停止（没有改动任何数据）。"
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
    decision_listed skip_projects "$project" && continue
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
      say "备份新服务器上已有的 Compose 项目：$project"
      if ! compose_capture_rollback_metadata "$project" "$rollback_dir"; then
        warn " · 无法备份新服务器上已有的 Compose 项目 ${project}，已停止（它仍在正常运行）"
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
    decision_listed skip_containers "$name" && continue
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
    decision_listed keep_volumes "$name" && continue
    restore_mount_skipped volume "$name" && continue
    SELECTED_TRANSACTION_VOLUMES["$name"]=1
  done < <(jq -r '.volumes[].name' manifest.json)
  SELECTED_TRANSACTION_BINDS=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    bind_path_is_system "$name" && continue
    restore_mount_skipped bind "$name" && continue
    SELECTED_TRANSACTION_BINDS+=("$name")
  done < <(jq -r '.binds[] | .host, (.link // empty)' manifest.json)

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
      if [[ "$type" == "bind" ]] && ((${#SELECTED_TRANSACTION_BINDS[@]} > 0)); then
        for selected_path in "${SELECTED_TRANSACTION_BINDS[@]}"; do
          if mount_paths_overlap "$source" "$selected_path"; then
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
    warn "无法确定需要临时停止哪些容器，已停止（没有停止服务，也没有写入数据）。"
    return 1
  fi
  mapfile -t quiesce_names <"$quiesce_list_file"
  for name in "${quiesce_names[@]}"; do
    say "临时停止新服务器上的容器：$name"
  done
  transaction_quiesce_containers "${quiesce_names[@]}" || return 1

  # 所有目标服务及共享写入者停止后再提交 writable layer，使容器快照与
  # 随后建立的 volume/bind 数据回滚点处于同一个静默窗口。
  while IFS=$'\t' read -r project had_old; do
    [[ "$had_old" == "1" ]] || continue
    rollback_dir="${RESTORE_TRANSACTION_DIR}/compose/${project}"
    say "保存已停止的旧 Compose 容器镜像：$project"
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
  RESTORE_STAGE="清理还原资料"
  RESTORE_COMMIT_STARTED=1
  TRANSACTION_ACTIVE=0
  if ! run_with_activity "提交事务：清理旧容器、镜像和数据回滚点" \
    transaction_cleanup_artifacts; then
    warn "服务与数据已恢复，但部分旧回滚资料清理失败：$RESTORE_TRANSACTION_DIR"
    return 1
  fi
  if ! run_with_activity "提交事务：删除临时事务目录" \
    rm -rf "$RESTORE_TRANSACTION_DIR"; then
    warn "服务和数据已经恢复，但临时文件夹没能删除：$RESTORE_TRANSACTION_DIR"
    return 1
  fi
  RESTORE_TRANSACTION_DIR=""
  export RESTORE_TRANSACTION_DIR
  transaction_release_lock
  RESTORE_STAGE="完成"
  say "所有服务和数据都已验证通过。"
}
trap restore_nontransaction_exit_handler EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RESTORE_STAGE="校验迁移包"
restore_stage 1 "检查迁移包"
if [[ "${RESTORE_CHECKSUM_VERIFIED:-0}" != "1" ]]; then
  if ! run_with_activity "校验每个文件" verify_bundle_checksums "$BUNDLE_DIR"; then
    error_user "迁移包文件校验失败，拒绝恢复" "请在旧服务器重新运行备份"
    exit 1
  fi
fi
if ! bundle_manifest_is_safe "$BUNDLE_DIR"; then
  error_user "迁移包里的清单文件有问题（格式不对或包含不安全的路径），已拒绝恢复" "请用最新版脚本在旧服务器重新运行备份"
  exit 1
fi
if ! transaction_internal_paths_are_safe; then
  exit 1
fi

# 在迁移包目录手动执行时也做迁移前预检（由主脚本调用时已在下载前做过）。
if [[ "${DM_PREFLIGHT_DONE:-0}" != "1" && "${RESTORE_SKIP_PREFLIGHT:-0}" != "1" && -f plan.json ]]; then
  DM_RESTORE_DECISIONS="$(mktemp "${TMPDIR:-/tmp}/docker-migrate-decisions.XXXXXX")"
  printf '{}\n' >"$DM_RESTORE_DECISIONS"
  export DM_RESTORE_DECISIONS
  if ! PREFLIGHT_SKIP_BASE_DISK=1 preflight_run plan.json "$DM_RESTORE_DECISIONS" "$BUNDLE_DIR"; then
    exit 1
  fi
fi
RESTORE_SKIPPED_MOUNTS="$(restore_skipped_mounts)"

RESTORE_STAGE="检查数据备份文件"
if jq -e '(.volumes | length) > 0 or (.binds | length) > 0' manifest.json >/dev/null &&
  ! command -v python3 >/dev/null 2>&1; then
  error_user "缺少 python3（尚未停止服务或修改数据）" "安装 python3，或使用主脚本「下载备份并恢复」自动安装依赖"
  exit 1
fi
if jq -e '.volumes|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r row; do
    vname="$(jq -r '.name' <<<"$row")"
    file="vol_${vname}.tgz"
    if [[ ! -f "volumes/$file" ]]; then
      error_user "迁移包缺少数据卷 ${vname} 的备份文件" "请在旧服务器重新运行备份"
      FAILED_VOLUMES+=("$vname")
    elif ! run_with_activity "检查卷 ${vname}" \
      archive_members_safe "volumes/$file"; then
      error_user "数据卷 ${vname} 的备份文件结构异常" "请在旧服务器重新运行备份"
      FAILED_VOLUMES+=("$vname")
    fi
  done < <(jq -c '.volumes[]' manifest.json)
fi
if jq -e '.binds|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r row; do
    host="$(jq -r '.host' <<<"$row")"
    file="$(jq -r '.file' <<<"$row")"
    bind_prefix="${host#/}"
    if bind_path_is_system "$host"; then
      say "跳过宿主机系统路径，只重建挂载、不覆盖目标端：$host"
    elif [[ ! -f "binds/$file" ]]; then
      error_user "迁移包缺少挂载目录 ${host} 的备份文件" "请在旧服务器重新运行备份"
      FAILED_BINDS+=("$host")
    elif ! run_with_activity "检查目录 ${host}" \
      archive_members_safe "binds/$file" "$bind_prefix"; then
      error_user "挂载目录 ${host} 的备份文件结构异常" "请在旧服务器重新运行备份"
      FAILED_BINDS+=("$host")
    fi
  done < <(jq -c '.binds[]' manifest.json)
fi
if ((${#FAILED_VOLUMES[@]} > 0 || ${#FAILED_BINDS[@]} > 0)); then
  print_failure_summary
  exit 1
fi
stage_end "$(jq -r '"\(.volumes | length) 个卷 · \(.binds | length) 个目录"' manifest.json)"

RESTORE_STAGE="加载镜像"
restore_stage 2 "加载镜像"
if [[ -f images.tar ]]; then
  images_count_file="$(mktemp "${TMPDIR:-/tmp}/docker-migrate-load.XXXXXX")"
  DM_PROGRESS_HINT="镜像较大时需要几分钟，请耐心等待" \
    run_with_progress "加载镜像" "count:${images_count_file}" "$(progress_file_size images.tar)" \
    restore_load_images images.tar "$images_count_file" ||
    warn_user "部分镜像加载失败，创建容器时会尝试在线拉取"
  rm -f "$images_count_file" "${images_count_file}.tmp"
  stage_end "$(human "$(progress_file_size images.tar)")"
else
  warn_user "迁移包里没有镜像，创建容器时会在线拉取"
  stage_end
fi

RESTORE_STAGE="备份新服务器上已有的服务"
restore_stage 3 "备份已有服务"
if jq -e '(.volumes | length) > 0 or (.binds | length) > 0' manifest.json >/dev/null &&
  ! docker image inspect alpine:3.20 >/dev/null 2>&1; then
  DM_PROGRESS_HINT="正在从 Docker Hub 下载，网络较慢时可能需要几分钟" \
    run_with_activity "拉取卷操作镜像 alpine:3.20" dm_quiet docker pull alpine:3.20 || {
    fail_with_output "无法拉取卷操作镜像 alpine:3.20（尚未修改任何数据）" "$(log_tail_text 10)" \
      "检查服务器能否访问 Docker Hub，或先手动执行 docker pull alpine:3.20"
    exit 1
  }
fi
transaction_prepare
stage_end

RESTORE_STAGE="恢复数据卷"
restore_stage 4 "恢复数据"
if jq -e '.volumes|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p volumes
  while IFS= read -r row; do
    vname=$(jq -r '.name' <<<"$row")
    file="vol_${vname}.tgz"
    if [[ ! -f "volumes/$file" ]]; then
      error_user "迁移包缺少数据卷 ${vname} 的备份文件" "请在旧服务器重新运行备份"
      FAILED_VOLUMES+=("$vname")
      break
    fi
    if decision_listed keep_volumes "$vname" || restore_mount_skipped volume "$vname"; then
      say "按预检时的选择不写入数据卷：${vname}"
      continue
    fi
    say "恢复数据卷：${vname}"
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
        error_user "已存在同名但驱动或参数不同的数据卷 ${vname}，拒绝覆盖" \
          "确认新服务器上的这个卷可以删除后，执行 docker volume rm ${vname} 再重试"
        FAILED_VOLUMES+=("$vname")
        break
      fi
    else
      volume_create_args=(docker volume create --driver "$v_driver")
      mapfile -t volume_opts < <(jq -r '.opts // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row" 2>/dev/null || true)
      for volume_opt in "${volume_opts[@]}"; do
        volume_create_args+=(--opt "$volume_opt")
      done
      volume_create_args+=("$vname")
      if ! dm_quiet "${volume_create_args[@]}"; then
        fail_with_output "数据卷 ${vname} 创建失败（驱动 ${v_driver}）" "$(log_tail_text 10)" \
          "非 local 驱动的卷需要先在新服务器安装对应的卷插件"
        FAILED_VOLUMES+=("$vname")
        break
      fi
    fi
    if ! run_with_activity "卷 ${vname}" \
      restore_data_with_diagnostics "命名卷：$vname" \
      restore_volume_exact "$vname" "$PWD/volumes" "$file" \
      "${RESTORE_TRANSACTION_DIR}/volume_data" "$volume_existed" 1; then
      fail_with_output "恢复数据卷 ${vname} 失败" "$(log_tail_text 20)"
      FAILED_VOLUMES+=("$vname")
      break
    fi
  done < <(jq -c '.volumes[]' manifest.json)
fi

# 不覆盖后续绑定目录，也不让 RESTORE_STAGE 掩盖真正失败的数据卷阶段。
if ((${#FAILED_VOLUMES[@]} > 0)); then
  print_failure_summary
  exit 1
fi

RESTORE_STAGE="恢复挂载目录"
if jq -e '.binds|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p binds
  while IFS= read -r row; do
    host=$(jq -r '.host' <<<"$row")
    file=$(jq -r '.file' <<<"$row")
    bind_link=$(jq -r '.link // empty' <<<"$row")
    bind_path_is_system "$host" && continue
    if restore_mount_skipped bind "$host" || { [[ -n "$bind_link" ]] && restore_mount_skipped bind "$bind_link"; }; then
      say "按预检时的选择不写入目录：${host}"
      continue
    fi
    if [[ ! -f "binds/$file" ]]; then
      error_user "迁移包缺少挂载目录 ${host} 的备份文件" "请在旧服务器重新运行备份"
      FAILED_BINDS+=("$host")
      break
    fi
    say "恢复挂载目录：${host}"
    if ! run_with_activity "目录 ${host}" \
      restore_data_with_diagnostics "绑定目录：$host" \
      restore_bind_exact "$host" "$PWD/binds/${file}" 1; then
      fail_with_output "恢复挂载目录 ${host} 失败" "$(log_tail_text 20)"
      FAILED_BINDS+=("$host")
      break
    fi
    if ! restore_bind_link "$bind_link" "$host"; then
      error_user "无法在原路径重建软链接：${bind_link} -> ${host}" \
        "确认 ${bind_link} 在新服务器上没有被其他文件或目录占用"
      FAILED_BINDS+=("$bind_link")
      break
    fi
  done < <(jq -c '.binds[]' manifest.json)
fi

# 数据恢复失败时禁止继续启动容器，避免 Docker 自动创建空卷/空目录。
if ((${#FAILED_VOLUMES[@]} > 0 || ${#FAILED_BINDS[@]} > 0)); then
  print_failure_summary
  exit 1
fi
stage_end

# 在 run_with_activity 中启动一个 Compose 项目：命令输出写入日志，屏幕只显示进度。
compose_start_project() {
  local compose_dir="$1" name="$2" compose_impl="$3"
  local compose_log="${DM_LOG_FILE:-/dev/null}"
  (
    cd "$compose_dir"
    COMPOSE_IMPL="$compose_impl"
    compose_run "${COMPOSE_FILE_ARGS[@]}" config >/dev/null 2>>"$compose_log" || exit 1
    compose_prepare_networks "$name" "${COMPOSE_FILE_ARGS[@]}" >>"$compose_log" 2>&1 || exit 1
    declare -a source_state_records=() start_services=() pause_services=() project_ids=()
    mapfile -t source_state_records < <(compose_source_state_records "$name" || true)
    say "Compose 项目 ${name}：读取到 ${#source_state_records[@]} 条源端服务状态"
    if ((${#source_state_records[@]} == 0)); then
      error_user "迁移包缺少 Compose 项目 ${name} 的服务状态记录" "请用最新版脚本在旧服务器重新运行备份"
      exit 1
    fi
    log_line "\$ compose up --no-start（${name}）"
    compose_run "${COMPOSE_FILE_ARGS[@]}" up --no-start >>"$compose_log" 2>&1 || exit 1
    compose_transplant_anonymous_volumes "$name" >>"$compose_log" 2>&1 || {
      fail_reason "Compose 项目 ${name} 的匿名卷数据没能放进新容器" "执行 df -h 检查磁盘空间后重试"
      exit 1
    }
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
    mapfile -t project_ids < <(docker ps -aq --filter "label=com.docker.compose.project=${name}")
    health_timeout="$(health_wait_seconds "${RESTORE_HEALTH_TIMEOUT:-60}" \
      "${project_ids[@]+"${project_ids[@]}"}")"
    if ((${#start_services[@]} > 0)); then
      log_line "\$ compose start ${start_services[*]}（${name}）"
      compose_run "${COMPOSE_FILE_ARGS[@]}" start "${start_services[@]}" >>"$compose_log" 2>&1 || exit 1
      compose_wait_services "$health_timeout" \
        "${COMPOSE_FILE_ARGS[@]}" -- "${start_services[@]}" || exit 1
    fi
    compose_wait_project_health "$name" "$health_timeout" || exit 1
    for service in "${pause_services[@]}"; do
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        dm_quiet docker pause "$id" || exit 1
      done < <(compose_run "${COMPOSE_FILE_ARGS[@]}" ps -q "$service" 2>>"$compose_log")
    done
  )
}

restore_stage 5 "启动服务"

# 先按迁移记录创建独立网络，再启动 Compose 项目：Compose 自动分配网段时
# 会占用第一个空闲网段，可能正是独立网络在源端使用的网段。
RESTORE_STAGE="创建网络"
say "创建自定义网络"
declare -A COMPOSE_NETS=()
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  COMPOSE_NETS["$n"]=1
done < <(compose_networks_from_meta_all)

if jq -e '.networks|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r network_row; do
    n="$(jq -r '.name // empty' <<<"$network_row")"
    case "$n" in bridge | host | none | "") continue ;; esac
    if [[ -n "${COMPOSE_NETS[$n]:-}" ]]; then
      continue
    fi
    if ! create_network_from_record "$network_row"; then
      [[ -n "$(fail_reason_read || true)" ]] ||
        fail_with_output "网络 ${n} 创建失败" "$(log_tail_text 10)" "检查是否与新服务器已有网络的网段冲突"
      FAILED_NETWORKS+=("$n")
    fi
  done < <(jq -c '.networks[]' manifest.json)
fi

if ((${#FAILED_NETWORKS[@]} > 0)); then
  print_failure_summary
  exit 1
fi

RESTORE_STAGE="恢复 Compose 项目"
if jq -e '.projects|length>0' manifest.json >/dev/null 2>&1; then
  COMPOSE_RESTORE_ROOT="${RESTORE_TRANSACTION_DIR}/incoming_compose"
  mkdir -p "$COMPOSE_RESTORE_ROOT"
  while IFS= read -r row; do
    USE_WDIR=0
    name=$(jq -r '.name' <<<"$row")
    wdir=$(jq -r '.working_dir // ""' <<<"$row")
    say "恢复 Compose 项目：${name}"
    mkdir -p "${COMPOSE_RESTORE_ROOT}/${name}"

    if decision_listed skip_projects "$name"; then
      say "按预检时的选择跳过 Compose 项目：${name}"
      continue
    fi
    if [[ -n "${SKIP_PROJECTS[$name]:-}" ]]; then
      warn_user "Compose 项目 ${name} 已存在，按 RESTORE_EXISTING=skip 保持不变"
      continue
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      compose_impl="plugin"
    elif command -v docker-compose >/dev/null 2>&1; then
      compose_impl="legacy"
    else
      error_user "新服务器没有安装 docker compose" "安装 docker-compose-plugin 后重试"
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
      say "还原 Compose 配置到原路径：$wdir"
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
      done <"compose/${name}/.env_file_map.jsonl"
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
    # 项目名必须显式指定：源端常用 -p、COMPOSE_PROJECT_NAME 或面板自定义项目名，
    # 与所在目录名不同；不指定时 Compose 会按目录名建出另一个项目。
    COMPOSE_FILE_ARGS=(-p "$name" "${COMPOSE_FILE_ARGS[@]+"${COMPOSE_FILE_ARGS[@]}"}")

    if [[ "$USE_WDIR" == "1" ]]; then
      compose_dir="$wdir"
    else
      compose_dir="${COMPOSE_RESTORE_ROOT}/${name}"
    fi
    compose_rc=0
    DM_PROGRESS_HINT="正在等待服务启动与健康检查" \
      run_with_activity "Compose 项目 ${name}" \
      compose_start_project "$compose_dir" "$name" "$compose_impl" || compose_rc=$?

    if ((compose_rc != 0)); then
      fail_with_output "Compose 项目 ${name} 启动失败" "$(log_tail_text 30)" \
        "执行 docker compose -p ${name} logs 查看服务日志"
      FAILED_PROJECTS+=("$name")
      print_failure_summary
      exit 1
    fi
  done < <(jq -c '.projects[]' manifest.json)
fi

# --network/--pid/--ipc container:X 要求 X 先存在。按依赖排序独立容器的恢复
# 顺序；被依附者若是 Compose 容器，已在 [D] 启动，不构成阻塞。循环依赖时按原顺序。
restore_runs_in_dependency_order() {
  local run name f id cname mode ref dep blocked progressed
  local -a pending=() next=()
  local -A name_of_id=() run_names=() done_names=()
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    id="$(jq -r '.[0].Id' "$f")"
    cname="$(jq -r '.[0].Name | ltrimstr("/")' "$f")"
    name_of_id["$id"]="$cname"
    name_of_id["${id:0:12}"]="$cname"
  done
  mapfile -t pending < <(jq -r '.runs[]' manifest.json)
  for run in "${pending[@]}"; do
    name="${run#runs/}"
    run_names["${name%.sh}"]=1
  done
  while ((${#pending[@]} > 0)); do
    next=()
    progressed=0
    for run in "${pending[@]}"; do
      name="${run#runs/}"
      name="${name%.sh}"
      blocked=0
      while IFS= read -r mode; do
        [[ "$mode" == container:* ]] || continue
        ref="${mode#container:}"
        dep="${name_of_id[$ref]:-${name_of_id[${ref:0:12}]:-$ref}}"
        if [[ "$dep" != "$name" && -n "${run_names[$dep]:-}" && -z "${done_names[$dep]:-}" ]]; then
          blocked=1
        fi
      done < <(jq -r '.[0].HostConfig | .NetworkMode, .PidMode, .IpcMode | values' \
        "meta/${name}.inspect.json" 2>/dev/null || true)
      if ((blocked == 1)); then
        next+=("$run")
      else
        printf '%s\n' "$run"
        done_names["$name"]=1
        progressed=1
      fi
    done
    if ((progressed == 0)); then
      printf '%s\n' "${next[@]}"
      break
    fi
    pending=("${next[@]+"${next[@]}"}")
  done
}

RESTORE_STAGE="启动容器"
if jq -e '.runs|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    cname_from_script="${r#runs/}"
    cname_from_script="${cname_from_script%.sh}"
    if decision_listed skip_containers "$cname_from_script"; then
      say "按预检时的选择保留已有容器：${cname_from_script}"
      continue
    fi
    if [[ -n "${SKIP_CONTAINERS[$cname_from_script]:-}" ]]; then
      warn_user "容器 ${cname_from_script} 已存在，按 RESTORE_EXISTING=skip 保持不变"
      continue
    fi
    say "恢复容器：${cname_from_script}"
    if ! RESTORE_TRANSACTION_DIR="$RESTORE_TRANSACTION_DIR" bash "$r"; then
      [[ -n "$(fail_reason_read || true)" ]] ||
        error_user "容器 ${cname_from_script} 恢复失败" "查看下方日志中的最后几行了解详情"
      FAILED_CONTAINERS+=("$cname_from_script")
      print_failure_summary
      exit 1
    fi
  done < <(restore_runs_in_dependency_order)
fi

if restore_has_failures; then
  print_failure_summary
  exit 1
fi

transaction_commit
stage_end "$(jq -r '"\(.runs | length) 个容器 · \(.projects | length) 个 Compose 项目"' manifest.json)"
REST_SH
  chmod +x "$out"
}

#####################################
# 恢复模式
#####################################
RESTORE_CLIENT_SESSION_BASE=""
RESTORE_CLIENT_SESSION_DIR=""
RESTORE_CLIENT_PHASE="idle"

restore_client_session_path_is_safe() {
  local base="${1:-}" session="${2:-}" prefix suffix
  [[ -n "$base" && -n "$session" && "$session" != "/" ]] || return 1
  if [[ "$base" == "/" ]]; then
    prefix="/restore."
  else
    prefix="${base%/}/restore."
  fi
  [[ "$session" == "$prefix"* ]] || return 1
  suffix="${session#"$prefix"}"
  [[ "$suffix" =~ ^[A-Za-z0-9]+$ ]]
}

restore_client_remove_session() {
  local base="${RESTORE_CLIENT_SESSION_BASE:-}"
  local session="${RESTORE_CLIENT_SESSION_DIR:-}"
  if ! restore_client_session_path_is_safe "$base" "$session"; then
    log_line "拒绝清理不安全的恢复临时目录：${session:-<空>}"
    return 1
  fi
  [[ -e "$session" || -L "$session" ]] || return 0
  rm -rf -- "$session"
}

restore_client_exit_handler() {
  local rc="${1:-$?}"
  trap - EXIT
  # 首次中断已确定退出结果；清理期间忽略后续信号，避免连续按 Ctrl+C
  # 又把 rm 打断，反而留下正在清理的半成品。
  trap '' INT TERM HUP
  set +e
  case "${RESTORE_CLIENT_PHASE:-idle}" in
    preparing | cleanup)
      if restore_client_remove_session; then
        if ((rc != 0)); then
          case "$rc" in
            129 | 130 | 143) printf '已清理中断产生的下载与临时文件。\n' >&2 ;;
            *) printf '已清理未完成的下载与临时文件。\n' >&2 ;;
          esac
        fi
      else
        printf '自动清理失败，请检查：%s\n' "${RESTORE_CLIENT_SESSION_DIR:-未知目录}" >&2
      fi
      ;;
  esac
  if ((rc != 0)); then
    stage_fail
    [[ -z "${DM_LOG_FILE:-}" ]] || printf '日志：%s（反馈问题时请附上这个文件）\n' "$DM_LOG_FILE" >&2
  else
    log_finish 1
  fi
  RESTORE_CLIENT_PHASE="finished"
  # 清理失败不能覆盖原始信号或错误退出码；诊断信息已在上面明确给出。
  exit "$rc"
}

restore_client_arm_session_cleanup() {
  local base="$1" session="$2"
  if ! restore_client_session_path_is_safe "$base" "$session"; then
    error_user "恢复工作目录不安全：$session" "设置 RESTORE_BASE 指向一个普通目录后重试"
    return 1
  fi
  RESTORE_CLIENT_SESSION_BASE="$base"
  RESTORE_CLIENT_SESSION_DIR="$session"
  RESTORE_CLIENT_PHASE="preparing"
  trap 'restore_client_exit_handler $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

restore_client_begin_restore() {
  RESTORE_CLIENT_PHASE="restoring"
  # 包内 restore.sh 有自己的信号回滚处理。外层继续保留 EXIT handler，
  # 但恢复阶段只保留诊断目录，不能抢先退出或删除回滚资料。
  trap - INT TERM HUP
}

restore_client_begin_cleanup() {
  RESTORE_CLIENT_PHASE="cleanup"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

restore_client_preserve_session() {
  RESTORE_CLIENT_PHASE="preserve"
  trap - EXIT INT TERM HUP
}

restore_client_finish_session() {
  RESTORE_CLIENT_PHASE="finished"
  RESTORE_CLIENT_SESSION_BASE=""
  RESTORE_CLIENT_SESSION_DIR=""
  trap - EXIT INT TERM HUP
}

restore_prompt_url() {
  local restore_url="${1:-}"
  if [[ -z "$restore_url" ]]; then
    read -rp "请输入旧服务器的一键包下载链接： " restore_url
  fi
  if ! [[ "$restore_url" =~ ^https?://[^[:space:]]+\.tar\.gz\.enc($|[?#]) ]]; then
    error_user "链接格式不正确" "请完整复制旧服务器输出的 http(s)://….tar.gz.enc#… 链接"
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
  local pair bin pkg
  local -a required_pairs=("curl curl" "tar tar" "find findutils" "jq jq" "docker docker"
    "python3 python3" "openssl openssl")
  PKGMGR="$(pm_detect)"
  for pair in "${required_pairs[@]}"; do
    bin="${pair%% *}"
    pkg="${pair##* }"
    command -v "$bin" >/dev/null 2>&1 && continue
    if [[ "$PKGMGR" == "none" ]]; then
      error_user "缺少命令 ${bin}，且没有可用的包管理器" "请手动安装 ${bin} 后重试"
      exit 1
    fi
    if [[ "$bin" == "docker" ]]; then
      case "$PKGMGR" in
        apt) install_package docker docker.io || true ;;
        *) install_package docker docker || true ;;
      esac
      if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        case "$PKGMGR" in
          apt) install_package "docker compose" docker-compose-plugin ||
            install_package docker-compose docker-compose || true ;;
          *) install_package docker-compose docker-compose || true ;;
        esac
      fi
      command -v docker >/dev/null 2>&1 || {
        error_user "Docker 自动安装失败" "请按 https://docs.docker.com/engine/install/ 手动安装后重试"
        exit 1
      }
    else
      need_bin "$bin" "$pkg"
    fi
  done
  ensure_docker_running
}

# 下载迁移包：响应头写入 header_file，供进度显示读取总大小；curl 的报错
# 写入日志，失败时据此给出原因。
restore_download() {
  local url="$1" output="$2" header_file="$3"
  curl -fL --globoff -sS --retry 5 --retry-delay 10 --retry-max-time 300 \
    --connect-timeout 30 -D "$header_file" --output "$output" --url "$url" \
    2>>"${DM_LOG_FILE:-/dev/null}"
}

# 解压迁移包，同时统计已读取的压缩数据量用于显示进度。
restore_extract() {
  local archive="$1" outdir="$2" count_file="$3"
  progress_meter "$count_file" <"$archive" | tar -xzf - -C "$outdir"
}

# 先试连一次旧服务器：连不上时立即说清楚原因，而不是让下载重试好几分钟后
# 才报错。只要旧服务器有任何 HTTP 响应（包括旧版本没有迁移计划时的 404）
# 就算连通；其他少见的错误交给后面的下载步骤处理。
restore_probe_source() {
  local url="$1" rc=0 host port
  host="${url#*://}"
  host="${host%%/*}"
  if [[ "$host" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
    port="${BASH_REMATCH[3]}"
    host="${BASH_REMATCH[1]}"
  elif [[ "$host" == *:* ]]; then
    port="${host##*:}"
    host="${host%:*}"
  fi
  [[ -n "${port:-}" ]] || port=80
  curl -sS --globoff -o /dev/null --connect-timeout "${RESTORE_CONNECT_TIMEOUT:-10}" \
    --max-time $((${RESTORE_CONNECT_TIMEOUT:-10} + 10)) --url "$url" \
    2>>"${DM_LOG_FILE:-/dev/null}" || rc=$?
  case "$rc" in
    6)
      error_user "找不到旧服务器 ${host}" "检查链接是否完整复制，以及新服务器能否正常解析域名"
      return 1
      ;;
    7)
      error_user "旧服务器 ${host} 的端口 ${port} 拒绝连接" \
        "确认旧服务器上的脚本还在运行（没有按回车结束）；如果还在运行，请在旧服务器放行这个端口：ufw allow ${port}/tcp，或 firewall-cmd --add-port=${port}/tcp"
      return 1
      ;;
    28)
      error_user "连接旧服务器 ${host} 的端口 ${port} 超时" \
        "通常是端口没有放行：请在云厂商控制台的安全组（防火墙）里放行 TCP ${port}，并在旧服务器执行 ufw allow ${port}/tcp，或 firewall-cmd --add-port=${port}/tcp"
      return 1
      ;;
  esac
  return 0
}

# 迁移前预检：从同一个链接推算迁移计划的地址，下载、验证后检查新服务器。
# 旧版源端没有迁移计划时静默跳过。返回 1 表示发现了无法继续的问题。
restore_preflight() {
  local download_url="$1" encryption_key="$2" mac_key="$3" iv="$4" decisions="$5"
  local plan_url work rc=0 summary
  plan_url="$(plan_url_from_bundle_url "$download_url")" || return 0
  work="$(mktemp -d "${TMPDIR:-/tmp}/docker-migrate-plan.XXXXXX")" || return 0
  log_line "迁移计划地址：${plan_url}"
  if ! curl -fsS --globoff --max-time 30 --retry 2 -o "${work}/plan.enc" --url "$plan_url" \
    2>>"${DM_LOG_FILE:-/dev/null}"; then
    log_line "没有获取到迁移计划（旧服务器可能是旧版本），跳过迁移前预检"
    rm -rf "$work"
    stage_end "旧服务器没有提供迁移计划，已跳过"
    return 0
  fi
  plan_decrypt "${work}/plan.enc" "${work}/plan.json" "$encryption_key" "$mac_key" "$iv" || rc=$?
  if ((rc != 0)); then
    rm -rf "$work"
    if ((rc == 2)); then
      error_user "迁移计划的签名校验失败，链接可能没有复制完整" "请重新完整复制旧服务器输出的链接"
      return 1
    fi
    log_line "迁移计划无法解析，跳过迁移前预检"
    stage_end "已跳过"
    return 0
  fi
  if ! preflight_run "${work}/plan.json" "$decisions" "$RESTORE_BASE_DIR"; then
    rm -rf "$work"
    return 1
  fi
  RESTORE_BASE_DIR="$(jq -r --arg d "$RESTORE_BASE_DIR" '.restore_base // $d' "$decisions")"
  summary="${PREFLIGHT_CONTAINERS:-0} 个容器 · 需要约 $(human "${PREFLIGHT_NEED_BYTES:-0}")"
  if [[ "$(jq '[.port_map, .skip_projects, .skip_containers, .auto_ip, .auto_subnet, .reuse_network, .keep_volumes] |
    map(length? // 0) | add' "$decisions" 2>/dev/null || echo 0)" != "0" ]]; then
    summary+=" · 已按你的选择调整"
  fi
  rm -rf "$work"
  stage_end "$summary"
}

# 恢复工作目录建立之前的退出：失败时告诉用户日志位置，成功时删除日志。
restore_early_exit() {
  local rc="$1"
  trap - EXIT
  if ((rc == 0)); then
    log_finish 1
  else
    stage_fail
    [[ -z "${DM_LOG_FILE:-}" ]] || printf '日志：%s（反馈问题时请附上这个文件）\n' "$DM_LOG_FILE" >&2
  fi
  exit "$rc"
}

restore_main() {
  local URL DOWNLOAD_URL EXPECTED_SHA256 ENCRYPTION_SCHEME ENCRYPTION_SECRET
  local ENCRYPTION_IV ENCRYPTION_MAC ENCRYPTION_KEY MAC_KEY tgz_bytes free_bytes
  local restore_started=$SECONDS decisions
  URL="$(restore_prompt_url "${1:-}")"
  log_init restore
  trap 'restore_early_exit $?' EXIT
  stage_begin 1 9 "检查环境"
  DOWNLOAD_URL="$(bundle_download_url "$URL")"
  EXPECTED_SHA256="$(bundle_expected_sha256 "$URL")"
  ENCRYPTION_SCHEME="$(bundle_encryption_scheme "$URL")"
  ENCRYPTION_SECRET="$(bundle_encryption_secret "$URL")"
  ENCRYPTION_IV="$(bundle_encryption_iv "$URL")"
  ENCRYPTION_MAC="$(bundle_encryption_mac "$URL")"
  # 只接受本工具生成的加密链接：来源摘要、加密参数和 HMAC 必须齐全。
  # 迁移包只在源端脚本运行期间提供下载，不需要兼容早期的明文或无摘要链接。
  if [[ "$ENCRYPTION_SCHEME" != "$BUNDLE_ENCRYPTION_SCHEME" ]] ||
    ! valid_sha256 "$EXPECTED_SHA256" ||
    ! valid_hex_length "$ENCRYPTION_SECRET" 128 ||
    ! valid_hex_length "$ENCRYPTION_IV" 32 ||
    ! valid_hex_length "$ENCRYPTION_MAC" 64; then
    error_user "链接不完整，缺少解密和校验需要的部分" \
      "请完整复制旧服务器输出的链接；如果旧服务器运行的是旧版脚本，请用最新版重新生成"
    exit 1
  fi
  restore_ensure_deps
  stage_end "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"

  stage_begin 2 9 "迁移前预检"
  RESTORE_BASE_DIR="${RESTORE_BASE:-$HOME/docker_migrate_restore}"
  decisions="$(mktemp "${TMPDIR:-/tmp}/docker-migrate-decisions.XXXXXX")"
  printf '{}\n' >"$decisions"
  if ! restore_probe_source "$DOWNLOAD_URL"; then
    rm -f "$decisions"
    exit 1
  fi
  if [[ "${RESTORE_SKIP_PREFLIGHT:-0}" == "1" ]]; then
    stage_end "已按 RESTORE_SKIP_PREFLIGHT=1 跳过"
  elif ! restore_preflight "$DOWNLOAD_URL" "$(bundle_secret_encryption_key "$ENCRYPTION_SECRET")" \
    "$(bundle_secret_mac_key "$ENCRYPTION_SECRET")" "$ENCRYPTION_IV" "$decisions"; then
    rm -f "$decisions"
    exit 1
  fi
  if [[ "${RESTORE_CHECK_ONLY:-0}" == "1" ]]; then
    printf '\n预检通过，没有下载或修改任何内容。去掉 --check 重新运行即可开始迁移。\n'
    print_decision_summary "$decisions"
    rm -f "$decisions"
    exit 0
  fi

  local BASE="$RESTORE_BASE_DIR"
  mkdir -p "$BASE"
  BASE="$(cd "$BASE" && pwd -P)" || {
    error_user "无法访问恢复目录：$BASE" "设置 RESTORE_BASE 指向一个可写的目录后重试"
    exit 1
  }
  local SESSION_DIR
  SESSION_DIR="$(mktemp -d "${BASE}/restore.XXXXXX")" || {
    error_user "无法创建恢复工作目录：$BASE" "执行 df -h 检查磁盘空间，或设置 RESTORE_BASE 指向其他目录"
    exit 1
  }
  if ! restore_client_arm_session_cleanup "$BASE" "$SESSION_DIR"; then
    rmdir "$SESSION_DIR" 2>/dev/null || true
    exit 1
  fi
  mv "$decisions" "${SESSION_DIR}/decisions.json"
  decisions="${SESSION_DIR}/decisions.json"
  DM_RESTORE_DECISIONS="$decisions"
  local RID
  RID="$(basename "$DOWNLOAD_URL" | sed 's/\.tar\.gz.*$//' | tr -dc 'A-Za-z0-9_-')"
  [[ -n "$RID" ]] || RID="$(date +%s)"
  local TGZ="${SESSION_DIR}/bundle.tar.gz"
  local ENCRYPTED_BUNDLE="${SESSION_DIR}/bundle.tar.gz.enc"
  local DOWNLOAD_FILE="$ENCRYPTED_BUNDLE"
  local DOWNLOAD_PARTIAL="${DOWNLOAD_FILE}.partial"
  local HEADER_FILE="${SESSION_DIR}/download.headers"
  local OUTDIR="${SESSION_DIR}/unpacked"

  stage_begin 3 9 "下载迁移包"
  log_line "下载地址：${DOWNLOAD_URL}"
  if ! DM_PROGRESS_HINT="长时间没有进展时，请检查旧服务器的防火墙和云厂商安全组" \
    run_with_progress "下载" "$DOWNLOAD_PARTIAL" "header:${HEADER_FILE}" \
    restore_download "$DOWNLOAD_URL" "$DOWNLOAD_PARTIAL" "$HEADER_FILE"; then
    fail_with_output "下载迁移包失败" "$(log_tail_text 10)" \
      "确认旧服务器上的脚本仍在运行，并检查防火墙和安全组是否放行了下载端口"
    exit 1
  fi
  if ! mv "$DOWNLOAD_PARTIAL" "$DOWNLOAD_FILE"; then
    error_user "无法保存下载的迁移包" "执行 df -h 检查磁盘空间后重试"
    exit 1
  fi
  stage_end "$(human "$(progress_file_size "$DOWNLOAD_FILE")")"

  stage_begin 4 9 "校验并解密"
  ENCRYPTION_KEY="$(bundle_secret_encryption_key "$ENCRYPTION_SECRET")"
  MAC_KEY="$(bundle_secret_mac_key "$ENCRYPTION_SECRET")"
  if ! run_with_activity "校验摘要与签名" verify_bundle_digests \
    "$ENCRYPTED_BUNDLE" "$MAC_KEY" "$ENCRYPTION_IV" \
    "$EXPECTED_SHA256" "$ENCRYPTION_MAC"; then
    error_user "迁移包摘要或签名校验失败，文件可能被篡改或链接不完整" \
      "确认链接完整复制后重新恢复；仍失败时请在旧服务器重新运行备份"
    exit 1
  fi
  if ! ensure_free_space "$SESSION_DIR" "$(progress_file_size "$ENCRYPTED_BUNDLE")" "解密迁移包"; then
    exit 1
  fi
  if ! run_with_progress "解密" "${TGZ}.partial.$$" \
    "$(progress_file_size "$ENCRYPTED_BUNDLE")" bundle_decrypt_file \
    "$ENCRYPTED_BUNDLE" "$TGZ" "$ENCRYPTION_KEY" "$ENCRYPTION_IV"; then
    rm -f "$TGZ"
    fail_with_output "解密迁移包失败" "$(log_tail_text 10)" "执行 df -h 检查磁盘空间后重试"
    exit 1
  fi
  ENCRYPTION_SECRET=""
  ENCRYPTION_KEY=""
  MAC_KEY=""
  # 密文已通过认证并解密，后续只用明文包；尽早释放一份完整包的空间。
  [[ "${RESTORE_KEEP:-0}" == "1" ]] || rm -f "$ENCRYPTED_BUNDLE"
  if ! run_with_activity "检查归档结构" archive_layout_is_safe "$TGZ"; then
    error_user "迁移包结构不安全或已损坏，拒绝解压" "请在旧服务器重新运行备份"
    exit 1
  fi
  mkdir -p "$OUTDIR"
  # 解压后体积未知；镜像归档通常压缩率不高，按 1.5 倍估算仅作提醒。
  tgz_bytes="$(progress_file_size "$TGZ")"
  free_bytes="$(free_disk_bytes "$SESSION_DIR")"
  if [[ "$free_bytes" =~ ^[0-9]+$ ]] && ((free_bytes < tgz_bytes * 3 / 2)); then
    warn_user "磁盘剩余空间可能不足以解压迁移包（约需 $(human "$((tgz_bytes * 3 / 2))")）"
  fi
  if ! run_with_progress "解压" "count:${TGZ}.count" "$tgz_bytes" \
    restore_extract "$TGZ" "$OUTDIR" "${TGZ}.count"; then
    rm -f "${TGZ}.count"
    fail_with_output "解压迁移包失败" "$(log_tail_text 10)" "执行 df -h 检查磁盘空间后重试"
    exit 1
  fi
  rm -f "${TGZ}.count"
  [[ "${RESTORE_KEEP:-0}" == "1" ]] || rm -f "$TGZ"

  local BUNDLE_DIR
  BUNDLE_DIR="$(restore_find_bundle_dir "$OUTDIR" "$RID" || true)"
  if [[ -z "$BUNDLE_DIR" || ! -f "${BUNDLE_DIR}/restore.sh" ]]; then
    error_user "迁移包内容不完整：找不到 restore.sh" "请在旧服务器重新运行备份"
    exit 1
  fi
  if ! run_with_activity "校验每个文件" \
    verify_bundle_checksums "$BUNDLE_DIR"; then
    error_user "迁移包文件校验失败，拒绝恢复" "请在旧服务器重新运行备份"
    exit 1
  fi
  if ! bundle_manifest_is_safe "$BUNDLE_DIR"; then
    error_user "迁移包里的清单文件有问题（格式不对或包含不安全的路径），已拒绝恢复" "请用最新版脚本在旧服务器重新运行备份"
    exit 1
  fi
  stage_end "$(human "$tgz_bytes")"

  # 使用当前脚本内置的修复版 restore.sh 覆盖包内旧 restore.sh。
  write_bundle_restore_script "${BUNDLE_DIR}/restore.sh"

  local rc result_file="${SESSION_DIR}/restore-result.json" result_status result_stage rollback_dir
  local metrics total running paused stopped missing volumes binds
  local container_line="" data_line="" cleanup_line="" diagnostic_dir="" elapsed
  restore_client_begin_restore
  set +e
  DM_SUMMARY_ARMED=1
  RESTORE_CHECKSUM_VERIFIED=1 RESTORE_SESSION_DIR="$SESSION_DIR" \
    RESTORE_RESULT_FILE="$result_file" RESTORE_DEFER_FINAL_SUMMARY=1 \
    DM_STAGE_OFFSET=4 DM_STAGE_TOTAL=9 DM_SUMMARY_ARMED=1 \
    DM_PREFLIGHT_DONE=1 DM_RESTORE_DECISIONS="$decisions" \
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
    if [[ "${RESTORE_KEEP:-0}" == "1" ]]; then
      restore_client_preserve_session
    else
      restore_client_begin_cleanup
    fi
  elif [[ "${RESTORE_CLEAN_ALL:-0}" == "1" ]]; then
    restore_client_begin_cleanup
  else
    restore_client_preserve_session
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
      if run_with_activity "清理恢复临时文件" restore_client_remove_session; then
        cleanup_line="下载文件与临时目录已删除"
        restore_client_finish_session
      else
        cleanup_line="恢复成功，但部分下载文件或临时目录未能删除，请人工检查"
        diagnostic_dir="$SESSION_DIR"
        restore_client_preserve_session
      fi
    fi
  else
    if [[ "${RESTORE_CLEAN_ALL:-0}" == "1" ]]; then
      if run_with_activity "清理恢复临时文件" restore_client_remove_session; then
        cleanup_line="已按 RESTORE_CLEAN_ALL=1 删除下载文件与临时目录"
        restore_client_finish_session
      else
        cleanup_line="RESTORE_CLEAN_ALL=1 清理未完成，请人工检查"
        diagnostic_dir="$SESSION_DIR"
        restore_client_preserve_session
      fi
    else
      cleanup_line="恢复文件已保留，便于排查"
      diagnostic_dir="$SESSION_DIR"
    fi
  fi

  elapsed="$(format_elapsed "$((SECONDS - restore_started))")"
  print_restore_result_summary "$result_status" "$result_stage" "$container_line" "$data_line" \
    "$cleanup_line" "$diagnostic_dir" "$rollback_dir" "$elapsed"
  restore_client_finish_session
  if [[ "$result_status" == "SUCCESS" ]]; then
    log_finish 1
  else
    log_finish 0
  fi
  exit "$rc"
}

# --diagnose：收集排查问题所需的信息，生成一个可以直接附到 issue 里的文件。
# 只读取信息，不改动任何容器或数据；写入前统一隐藏密钥与密码。

diagnose_section() {
  printf '\n===== %s =====\n' "$1"
}

run_diagnose() {
  local out log_dir restore_dir file
  out="${PWD}/docker_migrate_diagnose-$(date +%Y%m%d-%H%M%S).txt"
  log_dir="${DOCKER_MIGRATE_LOG_DIR:-${HOME:-/tmp}/docker_migrate_logs}"
  restore_dir="${RESTORE_BASE:-${HOME:-/tmp}/docker_migrate_restore}"
  printf '正在收集诊断信息……\n' >&2
  {
    # 收集过程中个别命令失败（目录不存在、工具未安装）是正常的，不能中断整份报告。
    set +e +o pipefail
    log_environment diagnose
    diagnose_section "Docker 信息"
    docker info 2>&1 | head -n 80
    diagnose_section "容器"
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1
    diagnose_section "网络"
    docker network ls 2>&1
    diagnose_section "数据卷"
    docker volume ls 2>&1
    diagnose_section "磁盘"
    df -h 2>&1
    diagnose_section "监听端口"
    { ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null || echo "ss / netstat 均不可用"; } | head -n 60
    diagnose_section "防火墙"
    if command -v ufw >/dev/null 2>&1; then ufw status 2>&1; fi
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --state 2>&1
      firewall-cmd --list-ports 2>&1
    fi
    diagnose_section "最近的运行日志（最多 3 份，每份最后 300 行）"
    if [[ -d "$log_dir" ]]; then
      while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        printf -- '--- %s\n' "$file"
        tail -n 300 "$file" 2>&1
      done < <(ls -1t "$log_dir"/*.log 2>/dev/null | head -n 3)
    else
      echo "没有找到日志目录：$log_dir"
    fi
    diagnose_section "恢复工作目录"
    ls -la "$restore_dir" 2>&1 | head -n 30
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      printf -- '--- %s\n' "$file"
      cat "$file" 2>&1
    done < <(find "$restore_dir" -maxdepth 2 -name 'restore-result.json' 2>/dev/null | head -n 5)
    diagnose_section "回滚资料目录"
    ls -la "${RESTORE_ROLLBACK_BASE:-${HOME:-/tmp}/.docker_migrate_rollback}" 2>&1 | head -n 30
  } 2>&1 | log_redact >"$out"
  chmod 600 "$out" 2>/dev/null || true
  printf '诊断文件已生成：%s\n' "$out" >&2
  printf '提交 issue 时请附上这个文件。密钥与密码已自动隐藏，上传前也建议自己再检查一遍。\n' >&2
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
    --diagnose) REQUESTED_MODE=diagnose ;;
    --verbose | -v) DOCKER_MIGRATE_VERBOSE=1 ;;
    --check=*)
      REQUESTED_MODE=2
      export RESTORE_CHECK_ONLY=1
      RESTORE_URL="${ORIGINAL_ARGS[$arg_i]#*=}"
      ;;
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

export DOCKER_MIGRATE_VERBOSE="${DOCKER_MIGRATE_VERBOSE:-0}"

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
  diagnose)
    run_diagnose
    exit 0
    ;;
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
log_init backup "${ORIGINAL_ARGS[@]}"

# 锁与清理流程就绪前的退出：失败时保留日志并告诉用户位置。
backup_early_exit() {
  local rc="$1"
  trap - EXIT
  if ((rc == 0)); then
    log_finish 1
  else
    stage_fail
    [[ -z "${DM_LOG_FILE:-}" ]] || printf '日志：%s\n' "$DM_LOG_FILE" >&2
  fi
  exit "$rc"
}
trap 'backup_early_exit $?' EXIT

stage_begin 1 7 "检查环境"
PKGMGR="$(pm_detect)"

case "$PKGMGR" in
  apt)
    need_bin curl curl
    need_bin jq jq
    try_optional_bin python3 python3
    need_bin tar tar
    need_bin find findutils
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
    need_bin find findutils
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
    need_bin find findutils
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
    need_bin find findutils
    need_bin gzip gzip
    try_optional_bin pigz pigz
    need_bin openssl openssl
    need_bin docker docker
    ;;
  none)
    for required_bin in curl jq tar find gzip openssl docker; do
      if ! command -v "$required_bin" >/dev/null 2>&1; then
        error_user "缺少命令 ${required_bin}，且没有可用的包管理器" "请手动安装 ${required_bin} 后重试"
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
    --verbose | -v) shift ;;
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
      error_user "未知参数：$1" "运行 --help 查看可用参数"
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
detail "迁移包工作目录：${BUNDLE}"

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
    error_user "本机已有另一个迁移任务正在运行" "等待它结束后重试"
    exit 1
  fi
elif ! mkdir "$LOCKDIR" 2>/dev/null; then
  error_user "本机已有另一个迁移任务正在运行" "确认没有其他任务后，删除 ${LOCKDIR} 再重试"
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
  [[ -z "${PLAN_PATH:-}" ]] || rm -f "${PLAN_PATH}" 2>/dev/null || failed=1
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
  detail "恢复源服务器容器原始运行状态（共 ${#STOPPED_ON_BACKUP[@]} 个）"
  local ok=0 fail=0 record n original_state current_state restore_ok
  local -a remaining=()
  for record in "${STOPPED_ON_BACKUP[@]}"; do
    IFS=$'\t' read -r n original_state <<<"$record"
    detail "恢复源容器状态：${n}（${original_state}）"
    current_state="$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo missing)"
    restore_ok=1
    case "$original_state" in
      paused)
        if [[ "$current_state" != "paused" ]]; then
          case "$current_state" in
            running | restarting) ;;
            *)
              run_with_activity "启动源容器：$n" \
                dm_quiet run_with_timeout 60 docker start "$n" || restore_ok=0
              ;;
          esac
          ((restore_ok == 0)) || dm_quiet docker pause "$n" || restore_ok=0
        fi
        ;;
      *)
        case "$current_state" in
          running | restarting) ;;
          paused) dm_quiet docker unpause "$n" || restore_ok=0 ;;
          *)
            run_with_activity "启动源容器：$n" \
              dm_quiet run_with_timeout 60 docker start "$n" || restore_ok=0
            ;;
        esac
        ;;
    esac
    if ((restore_ok == 1)); then
      detail "源容器已恢复：${n}"
      ok=$((ok + 1))
    else
      detail "源容器恢复失败：${n}"
      fail=$((fail + 1))
      remaining+=("$record")
    fi
  done
  STOPPED_ON_BACKUP=("${remaining[@]}")
  SOURCE_RESTORED_COUNT=$((SOURCE_RESTORE_EXPECTED - ${#STOPPED_ON_BACKUP[@]}))
  if ((fail > 0)); then
    error_user "有 ${fail} 个源容器未能恢复原来的运行状态" \
      "立即执行 docker ps -a 检查，并用 docker start <容器名> 手动启动"
    return 1
  fi
  detail "源容器已恢复：${ok}/${attempted}"
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
  ((rc == 0)) || stage_fail
  print_source_result_summary "$status" "$package_line" "$HTTP_CLEANUP_STATUS" \
    "$source_line" "$CLEANUP_STATUS" "$elapsed"
  if [[ "$status" == "SUCCESS" ]]; then
    log_finish 1
  else
    log_finish 0
  fi
  exit "$final_rc"
}

# 从获得锁开始，任何正常退出、错误或信号都会恢复源容器并清理临时包。
trap 'graceful_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
DM_SUMMARY_ARMED=1
stage_end "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"

#####################################
# 容器选择（支持 compose 分组）
#####################################
stage_begin 2 7 "选择容器"
if [[ -n "$INCLUDE_LIST" ]]; then
  declare -A INCLUDE_ID_BY_NAME=()
  include_container_count=0
  while IFS=$'\t' read -r id n; do
    [[ -n "$id" && -n "$n" ]] || continue
    INCLUDE_ID_BY_NAME["$n"]="$id"
    include_container_count=$((include_container_count + 1))
  done < <(docker ps -a --format '{{.ID}}\t{{.Names}}')
  ((include_container_count > 0)) || {
    error_user "本机没有任何容器（运行中或已停止）"
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
      warn_user "未找到容器：$n"
    fi
  done
  ((${#IDS[@]})) || {
    error_user "--include 没有匹配到任何容器" "执行 docker ps -a 确认容器名称"
    exit 1
  }
else
  mapfile -t PS_LINES < <(docker ps -a --format '{{.ID}} {{.Names}}')
  ((${#PS_LINES[@]})) || {
    error_user "本机没有任何容器（运行中或已停止）"
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
  detail "识别容器与 Compose 分组（共 ${scan_total} 个）"
  for line in "${PS_LINES[@]}"; do
    scan_index=$((scan_index + 1))
    id="${line%% *}"
    cname="${line#* }"
    [[ -z "$cname" || "$cname" == "$id" ]] && cname="$id"
    progress_count "识别容器" "$scan_index" "$scan_total" "$cname"
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
        mapfile -t cfgs_arr < <(compose_config_files_split "$cfgs_raw")
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
  stage_hold
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
    error_user "没有可迁移的容器"
    exit 1
  fi

  if [[ ! -t 0 ]]; then
    error_user "非交互模式无法选择容器" "用 --include=容器名1,容器名2 指定要迁移的容器"
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
        warn_user "忽略无效的序号：$t"
        continue
      fi
      num="$t"
      if ((num < 1 || num > idx)); then
        warn_user "忽略超出范围的序号：$t"
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
      error_user "没有选择任何容器"
      exit 1
    }
  fi
fi

#####################################
# 自动纳入被依附的容器
#####################################
# --network/--pid/--ipc container:X 的容器离开 X 无法启动，自动把 X 一并迁移。
dependency_added=1
while ((dependency_added == 1)); do
  dependency_added=0
  for id in "${IDS[@]}"; do
    while IFS= read -r dep_mode; do
      [[ "$dep_mode" == container:* ]] || continue
      dep_ref="${dep_mode#container:}"
      dep_id="$(docker inspect -f '{{.Id}}' "$dep_ref" 2>/dev/null || true)"
      if [[ -z "$dep_id" ]]; then
        BACKUP_FAILURES+=("容器 ${id} 依附的容器 ${dep_ref:0:12} 不存在")
        continue
      fi
      dep_selected=0
      for existing in "${IDS[@]}"; do
        [[ "$dep_id" != "$existing"* ]] || dep_selected=1
      done
      ((dep_selected == 0)) || continue
      dep_name="$(docker inspect -f '{{.Name}}' "$dep_id" 2>/dev/null | sed 's#^/##')"
      warn_user "自动加入被依附的容器 ${dep_name:-${dep_id:0:12}}（选中的容器要借用它的网络，必须一起迁移）"
      IDS+=("${dep_id:0:12}")
      dependency_added=1
    done < <(docker inspect -f '{{.HostConfig.NetworkMode}}
{{.HostConfig.PidMode}}
{{.HostConfig.IpcMode}}' "$id" 2>/dev/null || true)
    ((dependency_added == 0)) || break
  done
done

# shellcheck disable=SC2154
stage_end "${#IDS[@]} 个容器"

#####################################
# 元数据采集
#####################################
stage_begin 3 7 "读取配置"
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
  jtmp="$(docker inspect "$id")"
  progress_count "分析容器" "$metadata_index" "$metadata_total" "$(jq -r '.[0].Name | ltrimstr("/")' <<<"$jtmp")"
  SELECTED_INSPECT_JSON["$id"]="$jtmp"
  projtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$jtmp")
  wdirtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$jtmp")
  # 兼容 v1：缺少 working_dir 时从 config_files 推断
  if [[ -z "$wdirtmp" && -n "$projtmp" ]]; then
    cfgstmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$jtmp")
    if [[ -n "$cfgstmp" ]]; then
      mapfile -t cfgs_tmp < <(compose_config_files_split "$cfgstmp")
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
  progress_count "读取容器配置" "$metadata_index" "$metadata_total" "$name"
  img=$(jq -r '.[0].Config.Image' <<<"$j")
  CONTAINER_NAME["$id"]="$name"
  IMGSET["$img"]=1

  proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
  wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")
  cfgs=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$j")
  # 兼容 v1：缺少 working_dir 时从 config_files 推断
  if [[ -z "$wdir" && -n "$proj" ]]; then
    if [[ -n "$cfgs" ]]; then
      mapfile -t cfgs_arr < <(compose_config_files_split "$cfgs")
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
  detail "打包 Docker Compose 项目配置"
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
      mapfile -t CFG_ARR < <(compose_config_files_split "$cfgs")
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
      detail "解析 Compose 配置：$proj"
      compose_log="${DM_LOG_FILE:-/dev/null}"
      if docker compose version >/dev/null 2>&1 &&
        { docker compose -p "$proj" --project-directory "$wdir" "${CFG_SOURCE_ARGS[@]}" config --no-path-resolution >"$resolved_tmp" 2>>"$compose_log" ||
          docker compose -p "$proj" --project-directory "$wdir" "${CFG_SOURCE_ARGS[@]}" config >"$resolved_tmp" 2>>"$compose_log"; }; then
        mv "$resolved_tmp" "${dest}/_resolved_config.yml"
      elif command -v docker-compose >/dev/null 2>&1 &&
        (cd "$wdir" && docker-compose -p "$proj" "${CFG_SOURCE_ARGS[@]}" config) >"$resolved_tmp" 2>>"$compose_log"; then
        mv "$resolved_tmp" "${dest}/_resolved_config.yml"
      else
        rm -f "$resolved_tmp"
        warn_user "Compose 项目 ${proj} 无法生成解析后的配置，将使用原始配置文件"
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

# 读取配置时发现的问题在停机之前就报告，避免为一个配置错误让旧服务器白白停机。
for service_key in "${!COMPOSE_SERVICE_COUNT[@]}"; do
  if ((${COMPOSE_SERVICE_COUNT[$service_key]} > 1)); then
    BACKUP_FAILURES+=("Compose 服务存在多个副本，无法逐容器保留可写层：${service_key##*|}")
  fi
done
if ((${#BACKUP_FAILURES[@]} > 0)); then
  case "${BACKUP_FAILURES[0]}" in
    "Compose 服务存在多个副本"*) failure_hint="请只迁移单副本的 Compose 服务，或先把副本数缩减为 1" ;;
    "Compose 配置文件缺失"*) failure_hint="确认 Compose 项目的配置文件还在启动时的位置；移动过目录的话，请在新位置重新执行 docker compose up -d 后再备份" ;;
    *"依附的容器"*) failure_hint="先启动它依附的容器，或把两个容器一起迁移" ;;
    *) failure_hint="运行 --diagnose 生成诊断包并反馈问题" ;;
  esac
  error_user "${BACKUP_FAILURES[0]}" "$failure_hint"
  exit 1
fi

#####################################
# 预拉取卷操作镜像，避免把下载时间计入后面的停机快照窗口
#####################################
if docker image inspect alpine:3.20 >/dev/null 2>&1; then
  detail "卷操作镜像 alpine:3.20 已存在"
else
  DM_PROGRESS_HINT="正在从 Docker Hub 下载，网络较慢时可能需要几分钟" \
    run_with_activity "拉取卷操作镜像 alpine:3.20" dm_quiet docker pull alpine:3.20 ||
    warn_user "无法拉取 alpine:3.20，打包数据卷时可能失败"
fi

#####################################
# 检查未选中容器是否仍在写共享挂载
#####################################
declare -a SHARED_MOUNT_ROWS=()
mapfile -t SHARED_MOUNT_ROWS < <(
  run_with_activity "检查与其他容器共享的数据" \
    collect_shared_running_containers "${IDS[@]}"
)
if ((${#SHARED_MOUNT_ROWS[@]} > 0)); then
  stage_hold
  for shared_row in "${SHARED_MOUNT_ROWS[@]}"; do
    IFS=$'\t' read -r _ shared_name shared_reason <<<"$shared_row"
    warn_user "未选中的容器 ${shared_name} 正在使用相同的数据（${shared_reason}）"
  done

  if ((NO_STOP == 1)); then
    error_user "--no-stop 无法保证共享数据的一致性，已取消备份" \
      "停止这些容器，或去掉 --no-stop 让脚本临时停止并自动恢复它们"
    exit 1
  fi

  stop_shared=0
  if [[ -t 0 ]]; then
    read -rp "是否临时停止这些容器？备份完成后会自动恢复。[Y/n] " STOP_SHARED
    STOP_SHARED=${STOP_SHARED:-Y}
    [[ "$STOP_SHARED" =~ ^[Yy]$ ]] && stop_shared=1
  elif [[ "${STOP_SHARED_MOUNTS:-0}" == "1" ]]; then
    stop_shared=1
  fi
  if ((stop_shared == 0)); then
    error_user "未允许停止共享数据的容器，为避免备份出不一致的数据已取消" \
      "非交互模式可设置 STOP_SHARED_MOUNTS=1 允许临时停止它们"
    exit 1
  fi

  declare -a SHARED_STOP_NAMES=()
  for shared_row in "${SHARED_MOUNT_ROWS[@]}"; do
    IFS=$'\t' read -r _ shared_name _ <<<"$shared_row"
    shared_state="$(docker inspect -f '{{.State.Status}}' "$shared_name" 2>/dev/null || echo running)"
    detail "临时停止共享数据的容器：${shared_name}"
    # Write-ahead：在 unpause/stop 前登记原状态；信号可在任意指令后安全恢复。
    STOPPED_ON_BACKUP+=("${shared_name}"$'\t'"${shared_state}")
    [[ "$shared_state" != "paused" ]] || dm_quiet docker unpause "$shared_name" || true
    SHARED_STOP_NAMES+=("$shared_name")
  done
  if ! docker_stop_batch_verified \
    "停止共享数据的容器（${#SHARED_STOP_NAMES[@]} 个）" "${SHARED_STOP_NAMES[@]}"; then
    error_user "共享数据的容器没有全部停止，已取消备份" "执行 docker ps 检查这些容器的状态"
    exit 1
  fi
fi
stage_end "${#IDS[@]} 个容器"

#####################################
# 停机窗口（可选）
#####################################
stage_begin 4 7 "停机并打包数据"
DOWNTIME_STARTED=$SECONDS
if ((NO_STOP == 1)); then
  warn_user "使用 --no-stop 不停机备份，数据库等有状态服务的数据可能不一致"
else
  # 非交互运行（定时任务、nohup、管道）时 stdin 可能已关闭；read 读到 EOF
  # 不能触发 set -e 中止，按默认的一致性停机备份继续。
  STOPNOW=""
  if [[ -t 0 ]]; then
    stage_hold
    read -rp "是否临时停止所选容器以保证数据一致？完成打包后会立即恢复。[Y/n] " STOPNOW || true
  fi
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
        detail "停机 ${idx}/${total_count}：${n} 原本就已停止"
        continue
      fi
      detail "停机 ${idx}/${total_count}：${n}"
      # Write-ahead：先登记再改变源容器状态，避免 TERM 落在 stop 与数组追加之间。
      STOPPED_ON_BACKUP+=("${n}"$'\t'"${source_state}")
      [[ "$source_state" != "paused" ]] || dm_quiet docker unpause "$n" || true
      SOURCE_STOP_NAMES+=("$n")
    done
    DOWNTIME_STARTED=$SECONDS
    if ! docker_stop_batch_verified \
      "停止所选容器（${#SOURCE_STOP_NAMES[@]} 个）" "${SOURCE_STOP_NAMES[@]}"; then
      error_user "所选容器没有全部停止，为避免备份出不一致的数据已取消" "执行 docker ps 检查容器状态"
      exit 1
    fi
  else
    warn_user "选择了不停机备份，数据库等有状态服务的数据可能不一致"
  fi
fi

#####################################
# 捕获容器 writable layer
#####################################
detail "检查容器可写层"

# 后续只需保存临时快照镜像；其父镜像层会由 docker image save 自动包含。
IMGSET=()
snapshot_total=${#IDS[@]}
snapshot_index=0
for id in "${IDS[@]}"; do
  snapshot_index=$((snapshot_index + 1))
  n="${CONTAINER_NAME[$id]}"
  snapshot_image="$(snapshot_image_ref "$RID" "$id")"
  snapshot_reason="$(container_snapshot_reason "$id" "${BUNDLE}/meta/${n}.inspect.json")"
  if [[ -z "$snapshot_reason" ]]; then
    original_image="$(jq -r '.[0].Config.Image' "${BUNDLE}/meta/${n}.inspect.json")"
    detail "可写层 ${snapshot_index}/${snapshot_total}：${n} 没有改动，沿用原镜像 ${original_image}"
    IMGSET["$original_image"]=1
    continue
  fi
  detail "可写层 ${snapshot_index}/${snapshot_total}：${n} 创建快照（${snapshot_reason}）"
  if ! run_with_activity "快照 ${n}" \
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
      BACKUP_FAILURES+=("Compose 快照覆盖配置生成失败：$n")
      continue
    fi
  fi
done
if ((${#BACKUP_FAILURES[@]} > 0)); then
  fail_with_output "${BACKUP_FAILURES[0]}" "$(log_tail_text)"
  exit 1
fi

#####################################
# 备份卷与绑定目录
#####################################
detail "打包数据卷与挂载目录"
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
        detail "数据卷 ${v_idx}/${vol_count}：${n} 的 ${vname} -> ${dest}"
        mkdir -p "${BUNDLE}/volumes"
        out="${BUNDLE}/volumes/vol_${vname}.tgz"
        if ! run_with_progress "卷 ${vname}" "count:${out}.count" "$(volume_size_bytes "$vname")" \
          archive_volume_to_gzip "$vname" "$out" "${out}.count"; then
          rm -f "${out}.count"
          BACKUP_FAILURES+=("数据卷 ${vname} 打包失败")
          continue
        fi
        item_bytes="$(progress_current "count:${out}.count")"
        PACKED_BYTES=$((${PACKED_BYTES:-0} + item_bytes))
        rm -f "${out}.count"
        MAN_VOL+=("$(jq -cn --arg name "$vname" --arg dest "$dest" --arg driver "$v_driver" \
          --argjson opts "$v_opts_json" --argjson bytes "$item_bytes" \
          '{name:$name,dest:$dest,driver:$driver,opts:$opts,bytes:$bytes}')")
        ;;
      bind)
        src=$(jq -r '.Source' <<<"$m")
        # 过滤 Docker socket 等 Unix socket 文件，防止恢复时覆盖目标服务器 daemon
        case "$src" in
          */docker.sock | */podman.sock | */containerd.sock)
            detail "跳过 Docker socket 挂载：$src（新服务器会挂载自己的 Docker）"
            continue
            ;;
        esac
        b_idx=$((b_idx + 1))
        if bind_path_is_system "$src"; then
          detail "宿主机系统路径只在新服务器重建挂载、不迁移内容：$src"
          continue
        fi
        # 软链接 bind 必须备份链接指向的真实数据；只打包链接本身会丢数据，
        # 恢复端也会拒绝以链接作为绑定根。恢复时在原路径重建同一个链接。
        bind_link=""
        real_src="$(bind_resolve_source "$src")"
        if [[ "$real_src" != "$src" ]]; then
          if bind_path_is_system "$real_src"; then
            detail "软链接指向宿主机系统路径，只在新服务器重建挂载：$src -> $real_src"
            continue
          fi
          bind_link="$src"
          src="$real_src"
          detail "挂载路径是软链接，备份它指向的真实目录：${bind_link} -> ${src}"
        fi
        [[ -z "${BACKED_BINDS[$src]:-}" ]] || continue
        BACKED_BINDS["$src"]=1
        esc="$(basename "$src" | tr -c 'A-Za-z0-9_.-' '_')"
        src_id="$(printf '%s' "$src" | cksum | awk '{print $1}')"
        out="${BUNDLE}/binds/bind_${esc}_${src_id}.tgz"
        detail "挂载目录 ${b_idx}/${bind_count}：${n} 的 ${src} -> ${dest}"
        mkdir -p "${BUNDLE}/binds"
        if ! run_with_progress "目录 ${src}" "count:${out}.count" "$(path_size_bytes "$src")" \
          archive_bind_to_gzip "$src" "$out" "${out}.count"; then
          rm -f "${out}.count"
          BACKUP_FAILURES+=("挂载目录 ${src} 打包失败")
          continue
        fi
        item_bytes="$(progress_current "count:${out}.count")"
        PACKED_BYTES=$((${PACKED_BYTES:-0} + item_bytes))
        rm -f "${out}.count"
        MAN_BIND+=("$(jq -cn --arg host "$src" --arg link "$bind_link" --arg dest "$dest" \
          --arg file "$(basename "$out")" --argjson bytes "$item_bytes" \
          '{host:$host,dest:$dest,file:$file,bytes:$bytes} + (if $link == "" then {} else {link:$link} end)')")
        ;;
      *)
        detail "跳过不需要迁移的挂载类型：$t（$dest）"
        ;;
    esac
  done < <(jq -c '.[0].Mounts[]?' <<<"$j")
done

if ((${#BACKUP_FAILURES[@]} > 0)); then
  fail_with_output "${BACKUP_FAILURES[0]}" "$(log_tail_text)"
  exit 1
fi

# 容器可写层、volume 与 bind 数据现在都已经真正归档为同一停机快照；后续
# 镜像保存、压缩、加密和下载不再需要业务保持停止，立即恢复源端状态。
SOURCE_RESTORE_EXPECTED=${#STOPPED_ON_BACKUP[@]}
if ((SOURCE_RESTORE_EXPECTED > 0)); then
  detail "数据快照已完成，立即恢复源服务器容器状态"
  if ! run_with_activity "恢复源容器运行" restart_source_containers; then
    exit 1
  fi
fi
packed_summary="${#MAN_VOL[@]} 个卷 · ${#MAN_BIND[@]} 个目录 · $(human "${PACKED_BYTES:-0}")"
if ((SOURCE_RESTORE_EXPECTED > 0)); then
  packed_summary+=" · 停机 $(format_elapsed "$((SECONDS - DOWNTIME_STARTED))")"
fi
stage_end "$packed_summary"

#####################################
# 生成独立容器 run 脚本
#####################################
stage_begin 5 7 "保存镜像"
if ((${#IDS[@]})); then
  detail "生成单容器恢复脚本"
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
  IMAGES_TOTAL_BYTES="$(images_total_bytes "${IMAGES[@]}")"
  if progress_docker_save "${OUT_IMG}" "$IMAGES_TOTAL_BYTES" \
    docker image save "${IMAGES[@]}"; then
    detail "images.tar 已生成：$(human "$(progress_file_size "$OUT_IMG")")"
    if ! cleanup_snapshot_images; then
      detail "部分临时快照镜像暂未删除，退出清理时会自动重试"
    fi
  else
    rm -f "${OUT_IMG}" 2>/dev/null || true
    fail_with_output "保存镜像失败" "$(log_tail_text)" "执行 df -h 检查磁盘空间，并确认 Docker 运行正常"
    exit 1
  fi
else
  warn_user "没有找到需要保存的镜像，新服务器将尝试在线拉取"
fi
stage_end "${#IMAGES[@]} 个镜像 · $(human "$(progress_file_size "${OUT_IMG:-/dev/null}")")"

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
      mapfile -t CFS_ARR < <(compose_config_files_split "$cfs")
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
README
}

stage_begin 6 7 "加密打包"
generate_manifest_and_restore
# 迁移计划：新服务器下载前据此预检（端口、磁盘、CPU 类型等）。
if ! plan_build "$BUNDLE" "${IMAGES_TOTAL_BYTES:-0}" >"${BUNDLE}/plan.json"; then
  rm -f "${BUNDLE}/plan.json"
  warn_user "迁移计划生成失败，新服务器将跳过迁移前预检"
fi
run_with_activity "计算文件校验值" generate_bundle_checksums "$BUNDLE"

#####################################
# 流式压缩并加密成单文件
#####################################
BUNDLE_BASENAME="docker_migrate_${STAMP}_${RID}"
SINGLE_TAR_PATH="${BUNDLE_ROOT}/${BUNDLE_BASENAME}.tar.gz"
BUNDLE_SECRET="$(openssl rand -hex 64)" || {
  error_user "无法生成迁移包加密密钥" "确认 openssl 可以正常运行"
  exit 1
}
BUNDLE_IV="$(openssl rand -hex 16)" || {
  error_user "无法生成迁移包加密 IV" "确认 openssl 可以正常运行"
  exit 1
}
valid_hex_length "$BUNDLE_SECRET" 128 && valid_hex_length "$BUNDLE_IV" 32 || {
  error_user "OpenSSL 返回了无效的随机密钥" "确认 openssl 可以正常运行"
  exit 1
}
BUNDLE_ENCRYPTION_KEY="$(bundle_secret_encryption_key "$BUNDLE_SECRET")"
BUNDLE_MAC_KEY="$(bundle_secret_mac_key "$BUNDLE_SECRET")"
ENCRYPTED_TAR_PATH="${SINGLE_TAR_PATH}.enc"
ENCRYPTED_PARTIAL_PATH="${ENCRYPTED_TAR_PATH}.partial.$$"
# 加密包最大约等于明文目录大小（镜像层通常已压缩）。
bundle_plain_bytes="$(du -sk "$BUNDLE" 2>/dev/null | awk '{ printf "%.0f\n", $1 * 1024 }')"
if ! ensure_free_space "$BUNDLE_ROOT" "${bundle_plain_bytes:-0}" "生成加密迁移包"; then
  exit 1
fi
PACK_COUNT_FILE="${ENCRYPTED_PARTIAL_PATH}.count"
if ! BUNDLE_DIGESTS="$(DM_PROGRESS_HINT="正在压缩，数据量大时需要几分钟" \
  run_with_progress "压缩并加密" "count:${PACK_COUNT_FILE}" "${bundle_plain_bytes:-0}" \
  bundle_pack_encrypt_directory \
  "$BUNDLE_ROOT" "$RID" "$ENCRYPTED_PARTIAL_PATH" \
  "$BUNDLE_ENCRYPTION_KEY" "$BUNDLE_MAC_KEY" "$BUNDLE_IV" "$PACK_COUNT_FILE")"; then
  rm -f "$PACK_COUNT_FILE"
  fail_with_output "压缩或加密迁移包失败" "$(log_tail_text)" "执行 df -h 检查磁盘空间后重试"
  exit 1
fi
rm -f "$PACK_COUNT_FILE"
IFS=$'\t' read -r BUNDLE_SHA256 BUNDLE_HMAC BUNDLE_DIGEST_EXTRA <<<"$BUNDLE_DIGESTS"
if [[ -n "$BUNDLE_DIGEST_EXTRA" ]] || ! valid_sha256 "$BUNDLE_SHA256" ||
  ! valid_sha256 "$BUNDLE_HMAC"; then
  error_user "无法生成加密迁移包的摘要"
  exit 1
fi
if ! mv "$ENCRYPTED_PARTIAL_PATH" "$ENCRYPTED_TAR_PATH"; then
  error_user "无法保存加密迁移包" "执行 df -h 检查磁盘空间后重试"
  exit 1
fi
# 迁移计划单独加密，与迁移包放在同一随机路径下，新服务器从同一个链接推算地址。
PLAN_NAME="${BUNDLE_BASENAME}.plan"
PLAN_PATH="${BUNDLE_ROOT}/${PLAN_NAME}"
if [[ -f "${BUNDLE}/plan.json" ]] && ! plan_encrypt "${BUNDLE}/plan.json" "$PLAN_PATH" \
  "$BUNDLE_ENCRYPTION_KEY" "$BUNDLE_MAC_KEY" "$BUNDLE_IV"; then
  rm -f "$PLAN_PATH"
  warn_user "迁移计划加密失败，新服务器将跳过迁移前预检"
fi
[[ -f "$PLAN_PATH" ]] || PLAN_PATH=""
# 明文目录已全部进入加密包：立即删除，释放磁盘并减少明文数据停留时间。
rm -rf "$BUNDLE" 2>/dev/null || detail "明文迁移目录暂未删除，退出时会再次清理：$BUNDLE"
TRANSFER_NAME="${BUNDLE_BASENAME}.tar.gz.enc"
TRANSFER_PATH="$ENCRYPTED_TAR_PATH"
TRANSFER_FRAGMENT="#sha256=${BUNDLE_SHA256}&enc=${BUNDLE_ENCRYPTION_SCHEME}&secret=${BUNDLE_SECRET}&iv=${BUNDLE_IV}&mac=${BUNDLE_HMAC}"
BUNDLE_ENCRYPTION_KEY=""
BUNDLE_MAC_KEY=""
BUNDLE_SECRET=""
SOURCE_PACKAGE_READY=1
stage_end "$(human "$(progress_file_size "$TRANSFER_PATH")")"

#####################################
# HTTP 下载服务
#####################################
stage_begin 7 7 "启动下载服务"
if [[ -t 0 ]]; then
  stage_hold
  read -rp "下载服务端口 [回车=${PORT}]： " IN_PORT || true
  if [[ -n "${IN_PORT:-}" ]]; then
    if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && ((IN_PORT >= 1 && IN_PORT <= 65535)); then
      NEW_PORT="$(pick_free_port "$IN_PORT")"
      if [[ "$NEW_PORT" != "$IN_PORT" ]]; then
        warn_user "端口 ${IN_PORT} 已被占用，改用 ${NEW_PORT}"
      fi
      PORT="$NEW_PORT"
    else
      warn_user "输入的端口无效，继续使用 ${PORT}"
    fi
  fi
fi

SECRET_TOKEN="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
BASE_URL="$(pick_advertise_url "$PORT")"
FINAL_URL="" # will be set below by the chosen HTTP server

SHPID=""

HTTP_LOG="${BUNDLE_ROOT}/http_server_${RID}.log"
: >"$HTTP_LOG"
log_line "下载服务日志：${HTTP_LOG}"
cd "${BUNDLE_ROOT}" || exit 1

# start_http_server: multi-fallback — python3 > busybox httpd > netcat
TRANSFER_SIZE="$(stat -c%s "$TRANSFER_PATH" 2>/dev/null || stat -f%z "$TRANSFER_PATH" 2>/dev/null || echo 0)"

if command -v python3 >/dev/null 2>&1; then
  # --- Fallback 1: Python3 HTTP server (best — supports secret token + proper headers) ---
  http_log_event "启动 backend=python3 port=${PORT} file=${TRANSFER_NAME} size=${TRANSFER_SIZE}"
  python3 - "$PORT" "$SECRET_TOKEN" "$TRANSFER_NAME" "${PLAN_PATH:+$PLAN_NAME}" >>"${HTTP_LOG}" 2>&1 <<'PY' &
import http.server
import os
from socketserver import ThreadingTCPServer
import sys

port = int(sys.argv[1])
secret = sys.argv[2]
fname = sys.argv[3]
plan_name = sys.argv[4] if len(sys.argv) > 4 else ""
# 同一随机路径下只提供两个文件：迁移包与迁移计划。
allowed = {"/" + secret + "/" + fname: fname}
if plan_name:
    allowed["/" + secret + "/" + plan_name] = plan_name
root = os.getcwd()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        name = allowed.get(path)
        if not name:
            self.send_response(404)
            self.end_headers()
            return
        fpath = os.path.join(root, name)
        try:
            st = os.stat(fpath)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(st.st_size))
        self.send_header("Content-Disposition", 'attachment; filename="' + name + '"')
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

import socket


class Server(ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        # 同时监听 IPv4 与 IPv6，纯 IPv6 服务器也能提供下载。
        if self.address_family == socket.AF_INET6:
            try:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except (AttributeError, OSError):
                pass
        super().server_bind()


try:
    Server.address_family = socket.AF_INET6
    httpd = Server(("::", port), Handler)
except OSError:
    Server.address_family = socket.AF_INET
    httpd = Server(("", port), Handler)

with httpd:
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
  [[ -z "${PLAN_PATH:-}" ]] || ln -sf "$PLAN_PATH" "$BUSYBOX_WEB/$SECRET_TOKEN/$PLAN_NAME"
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
  error_user "找不到可用的下载服务程序（python3、busybox httpd 或 nc）" "安装 python3 后重试"
  exit 1
fi
HTTP_WAS_STARTED=1

cd "$WORKDIR"
sleep 1

if ! kill -0 "$SHPID" 2>/dev/null; then
  HTTP_EXIT_UNEXPECTED=1
  error_user "下载服务启动失败（端口 ${PORT}）" "换一个端口重试，或查看下方的下载服务日志"
  print_http_diagnostics_once "$HTTP_LOG"
  graceful_exit 1
fi
SOURCE_TRANSFER_PUBLISHED=1
stage_end "端口 ${PORT}"

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
  error_user "下载服务意外停止（退出码 ${http_wait_rc}）" "查看下方的下载服务日志，然后重新运行备份"
  print_http_diagnostics_once "$HTTP_LOG"
  graceful_exit 1
else
  print_transfer_instructions "$FINAL_URL" noninteractive "$$"
  http_wait_rc=0
  wait "$SHPID" || http_wait_rc=$?
  HTTP_EXIT_UNEXPECTED=1
  SHPID=""
  error_user "下载服务意外停止（退出码 ${http_wait_rc}）" "查看下方的下载服务日志，然后重新运行备份"
  print_http_diagnostics_once "$HTTP_LOG"
  graceful_exit 1
fi
