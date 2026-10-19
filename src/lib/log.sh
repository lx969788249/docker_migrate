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
