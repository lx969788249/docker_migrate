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
