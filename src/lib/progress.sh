# 进度显示与耗时格式化：主脚本与生成的恢复脚本共用。

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

progress_tty_draw() {
  # 用一次写入覆盖旧内容，再清除新内容右侧的残留；不要先输出一整行空格，
  # 否则 SSH 或刷新较慢的终端会把中间空帧显示成闪烁。
  printf '\r%s\033[K' "$1" >&2
}

progress_tty_clear() {
  printf '\r\033[K' >&2
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
  local suffix="" line
  [[ -z "$item" ]] || suffix="（${item}）"
  if [[ -t 2 ]]; then
    printf -v line '[进度] %s：%d/%d%s' "$label" "$current" "$total" "$suffix"
    progress_tty_draw "$line"
    ((current < total)) || printf '\n' >&2
  elif ((current == 1 || current == total || current % 10 == 0)); then
    printf '[进度] %s：%d/%d%s\n' "$label" "$current" "$total" "$suffix" >&2
  fi
}

progress_watch() {
  local label="$1" file="$2" total="$3" started="$4" owner_pid="$5"
  local mode="${DOCKER_MIGRATE_PROGRESS_MODE:-auto}" interval current elapsed line timer_pid=""
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
      line="$(progress_render "$label" "$current" "$total" "$elapsed")"
      progress_tty_draw "$line"
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
  [[ ! -t 2 ]] || progress_tty_clear
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
