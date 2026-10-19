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
