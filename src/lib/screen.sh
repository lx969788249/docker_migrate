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
