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
    RED "[ERR] 拒绝清理不安全的恢复临时目录：${session:-<空>}"
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
            129 | 130 | 143) YEL "[INFO] 已清理中断产生的下载与临时文件。" ;;
            *) YEL "[INFO] 已清理未完成的下载与临时文件。" ;;
          esac
        fi
      else
        RED "[ERR] 自动清理失败，请检查：${RESTORE_CLIENT_SESSION_DIR:-未知目录}"
      fi
      ;;
  esac
  RESTORE_CLIENT_PHASE="finished"
  # 清理失败不能覆盖原始信号或错误退出码；诊断信息已在上面明确给出。
  exit "$rc"
}

restore_client_arm_session_cleanup() {
  local base="$1" session="$2"
  if ! restore_client_session_path_is_safe "$base" "$session"; then
    RED "[ERR] 无法保护不安全的恢复临时目录：$session"
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
  local -a required_pairs=("curl curl" "tar tar" "find findutils" "jq jq" "docker docker" "python3 python3")
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
  local ENCRYPTION_IV ENCRYPTION_MAC ENCRYPTION_KEY MAC_KEY encrypted=0 tgz_bytes free_bytes
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
  BASE="$(cd "$BASE" && pwd -P)" || {
    RED "[ERR] 无法访问恢复目录：$BASE"
    exit 1
  }
  local SESSION_DIR
  SESSION_DIR="$(mktemp -d "${BASE}/restore.XXXXXX")" || {
    RED "[ERR] 无法创建独立恢复工作目录：$BASE"
    exit 1
  }
  if ! restore_client_arm_session_cleanup "$BASE" "$SESSION_DIR"; then
    rmdir "$SESSION_DIR" 2>/dev/null || true
    exit 1
  fi
  local RID
  RID="$(basename "$DOWNLOAD_URL" | sed 's/\.tar\.gz.*$//' | tr -dc 'A-Za-z0-9_-')"
  [[ -n "$RID" ]] || RID="$(date +%s)"
  local TGZ="${SESSION_DIR}/bundle.tar.gz"
  local ENCRYPTED_BUNDLE="${SESSION_DIR}/bundle.tar.gz.enc"
  local DOWNLOAD_FILE="$TGZ"
  if ((encrypted == 1)); then
    DOWNLOAD_FILE="$ENCRYPTED_BUNDLE"
  fi
  local DOWNLOAD_PARTIAL="${DOWNLOAD_FILE}.partial"
  local OUTDIR="${SESSION_DIR}/unpacked"

  BLUE "[INFO] 下载：$DOWNLOAD_URL"
  if ! curl -fL --globoff --progress-bar --retry 5 --retry-delay 10 --retry-max-time 300 \
    --connect-timeout 30 --output "$DOWNLOAD_PARTIAL" --url "$DOWNLOAD_URL"; then
    RED "[ERR] 下载失败：$DOWNLOAD_URL"
    exit 1
  fi
  if ! mv "$DOWNLOAD_PARTIAL" "$DOWNLOAD_FILE"; then
    RED "[ERR] 无法保存已下载的迁移包，请检查磁盘空间：$DOWNLOAD_FILE"
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
    if ! ensure_free_space "$SESSION_DIR" "$(progress_file_size "$ENCRYPTED_BUNDLE")" "解密迁移包"; then
      exit 1
    fi
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
    # 密文已通过认证并解密，后续只用明文包；尽早释放一份完整包的空间。
    [[ "${RESTORE_KEEP:-0}" == "1" ]] || rm -f "$ENCRYPTED_BUNDLE"
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
  # 解压后体积未知；镜像归档通常压缩率不高，按 1.5 倍估算仅作提醒。
  tgz_bytes="$(progress_file_size "$TGZ")"
  free_bytes="$(free_disk_bytes "$SESSION_DIR")"
  if [[ "$free_bytes" =~ ^[0-9]+$ ]] && ((free_bytes < tgz_bytes * 3 / 2)); then
    YEL "[WARN] 磁盘剩余空间可能不足以解压迁移包（约需 $(human "$((tgz_bytes * 3 / 2))")），解压失败时请先清理磁盘。"
  fi
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
  restore_client_begin_restore
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
  exit "$rc"
}
