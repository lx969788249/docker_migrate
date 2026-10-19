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
