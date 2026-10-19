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

dm_tty_draw() {
  printf '\r%s\033[K' "$1" >&2
}

dm_tty_clear() {
  printf '\r\033[K' >&2
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
      dm_tty_draw "$message"
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
  [[ ! -t 2 ]] || dm_tty_clear
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

