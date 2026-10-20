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
