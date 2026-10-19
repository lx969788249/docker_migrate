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
