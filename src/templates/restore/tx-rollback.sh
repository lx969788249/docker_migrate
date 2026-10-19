transaction_remove_new_services() {
  local project had_old name state backup id rc=0
  if [[ -f "${RESTORE_TRANSACTION_DIR}/standalone.tsv" ]]; then
    while IFS=$'\t' read -r name had_old state; do
      [[ -n "$name" ]] || continue
      backup="$(awk -F '\t' -v name="$name" '$1 == name { print $2; exit }' \
        "${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv")"
      if [[ -n "$backup" ]]; then
        if transaction_container_exists "$backup"; then
          if transaction_container_exists "$name"; then
            dm_quiet docker rm -f "$name" || true
            if transaction_container_exists "$name"; then
              warn " · 无法静默并删除本次新建的单容器：$name"
              rc=1
            fi
          fi
        elif transaction_container_exists "$name"; then
          # WAL 已写入但 rename 尚未发生；当前仍是原容器，不删除。
          :
        else
          warn " · 单容器及其预登记回滚点均不存在：$name"
          rc=1
        fi
      elif [[ "$had_old" == "0" ]]; then
        dm_quiet docker rm -f "$name" || true
        if transaction_container_exists "$name"; then
          warn " · 无法静默并删除本次新建的单容器：$name"
          rc=1
        fi
      fi
    done <"${RESTORE_TRANSACTION_DIR}/standalone.tsv"
  fi

  if [[ -f "${RESTORE_TRANSACTION_DIR}/compose.tsv" ]]; then
    while IFS=$'\t' read -r project had_old; do
      [[ -n "$project" ]] || continue
      grep -Fxq "$project" "${RESTORE_TRANSACTION_DIR}/compose_replaced.list" || continue
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        dm_quiet docker rm -f "$id" || rc=1
      done < <(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}')
      if [[ -n "$(docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --format '{{.ID}}')" ]]; then
        warn " · 新 Compose 项目仍有容器未能删除，禁止回灌旧数据：$project"
        rc=1
      fi
    done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  fi
  return "$rc"
}

transaction_restore_volumes() {
  local volume existed rollback_file rc=0 i
  local -a records=()
  [[ -f "${RESTORE_TRANSACTION_DIR}/volumes.tsv" ]] || return 0
  mapfile -t records <"${RESTORE_TRANSACTION_DIR}/volumes.tsv"
  for ((i = ${#records[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r volume existed rollback_file <<<"${records[$i]}"
    [[ -n "$volume" ]] || continue
    if [[ "$existed" == "1" ]]; then
      if ! volume_clear_and_extract "$volume" "$(dirname "$rollback_file")" \
        "$(basename "$rollback_file")" 0; then
        warn " · 命名卷数据回滚失败：$volume"
        rc=1
      fi
    elif ! dm_quiet docker volume rm "$volume"; then
      warn " · 无法删除本次新建的命名卷：$volume"
      rc=1
    fi
  done
  return "$rc"
}

transaction_restore_binds() {
  local host had_old old rc=0 i
  local -a records=()
  [[ -f "${RESTORE_TRANSACTION_DIR}/binds.tsv" ]] || return 0
  mapfile -t records <"${RESTORE_TRANSACTION_DIR}/binds.tsv"
  for ((i = ${#records[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r host had_old old <<<"${records[$i]}"
    [[ "$host" == /* && "$host" != "/" ]] || {
      rc=1
      continue
    }
    if [[ "$had_old" == "1" ]]; then
      if root_exec test -e "$old" || root_exec test -L "$old"; then
        if root_exec test -e "$host" || root_exec test -L "$host"; then
          root_exec rm -rf "$host" || {
            warn " · 无法移除本次恢复的绑定路径：$host"
            rc=1
            continue
          }
        fi
      elif root_exec test -e "$host" || root_exec test -L "$host"; then
        # WAL 可能已写入但 rename 尚未发生，或本地失败处理已把旧路径移回。
        continue
      else
        warn " · 绑定目录及其回滚点均不存在：$host"
        rc=1
        continue
      fi
      if ! root_exec mv "$old" "$host"; then
        warn " · 绑定目录数据回滚失败：$host"
        rc=1
      fi
    elif root_exec test -e "$host" || root_exec test -L "$host"; then
      root_exec rm -rf "$host" || {
        warn " · 无法移除本次新建的绑定路径：$host"
        rc=1
      }
    fi
  done
  return "$rc"
}

transaction_restore_standalones() {
  local restore_running="$1" name had_old state backup network_file rc=0 restored_from_backup
  [[ -f "${RESTORE_TRANSACTION_DIR}/standalone.tsv" ]] || return 0
  while IFS=$'\t' read -r name had_old state; do
    [[ -n "$name" ]] || continue
    if [[ "$had_old" == "1" ]]; then
      restored_from_backup=0
      backup="$(awk -F '\t' -v name="$name" '$1 == name { print $2; exit }' \
        "${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv")"
      if [[ -n "$backup" ]] && transaction_container_exists "$backup"; then
        dm_quiet docker rm -f "$name" || true
        if ! rename_container_with_retry "$backup" "$name"; then
          warn " · 无法恢复旧单容器名称：$name（回滚点：$backup）"
          rc=1
          continue
        fi
        restored_from_backup=1
      elif ! transaction_container_exists "$name"; then
        warn " · 旧单容器及其回滚点均不存在：$name"
        rc=1
        continue
      fi
      if ((restored_from_backup == 1)); then
        network_file="${RESTORE_TRANSACTION_DIR}/standalone_networks/${name}.json"
        if ! restore_container_networks "$name" "$network_file"; then
          warn " · 旧单容器网络恢复失败：$name"
          rc=1
          continue
        fi
      fi
      if [[ "$restore_running" == "1" ]] && ! transaction_restore_container_state "$name" "$state"; then
        warn " · 无法恢复旧单容器运行状态：$name ($state)"
        rc=1
      fi
    fi
  done <"${RESTORE_TRANSACTION_DIR}/standalone.tsv"
  return "$rc"
}

transaction_restore_compose() {
  local restore_running="$1" project had_old rollback_dir rc=0
  [[ -f "${RESTORE_TRANSACTION_DIR}/compose.tsv" ]] || return 0
  while IFS=$'\t' read -r project had_old; do
    [[ -n "$project" ]] || continue
    [[ "$had_old" == "1" ]] || continue
    rollback_dir="${RESTORE_TRANSACTION_DIR}/compose/${project}"
    if grep -Fxq "$project" "${RESTORE_TRANSACTION_DIR}/compose_replaced.list"; then
      if ! compose_restore_rollback "$project" "$rollback_dir" "$restore_running"; then
        warn " · Compose 项目自动回滚失败：$project（回滚点：$rollback_dir）"
        rc=1
      fi
    elif ! compose_restore_existing_states "$project" "$rollback_dir" "$restore_running"; then
      warn " · Compose 原容器运行状态恢复失败：$project"
      rc=1
    fi
  done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  return "$rc"
}

transaction_restore_shared() {
  local name state rc=0
  [[ -f "${RESTORE_TRANSACTION_DIR}/shared.tsv" ]] || return 0
  while IFS=$'\t' read -r name state; do
    [[ -n "$name" ]] || continue
    if ! transaction_restore_container_state "$name" "$state"; then
      warn " · 无法恢复共享挂载容器状态：$name ($state)"
      rc=1
    fi
  done <"${RESTORE_TRANSACTION_DIR}/shared.tsv"
  return "$rc"
}

transaction_cleanup_artifacts() {
  local preserve_compose="${1:-0}"
  local name backup state project had_old rollback_dir volume existed rollback_file host old image
  local rc=0
  if [[ -f "${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv" ]]; then
    while IFS=$'\t' read -r name backup state; do
      [[ -n "$backup" ]] || continue
      if ! dm_quiet docker rm -f "$backup"; then
        if ! docker info >/dev/null 2>&1 || transaction_container_exists "$backup"; then
          warn " · 无法清理旧单容器回滚点：$backup"
          rc=1
        fi
      fi
    done <"${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv"
  fi
  if [[ "$preserve_compose" != "1" && -f "${RESTORE_TRANSACTION_DIR}/compose.tsv" ]]; then
    while IFS=$'\t' read -r project had_old; do
      [[ "$had_old" == "1" ]] || continue
      rollback_dir="${RESTORE_TRANSACTION_DIR}/compose/${project}"
      [[ -f "${rollback_dir}/images.list" ]] || continue
      while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        if ! dm_quiet docker image rm "$image"; then
          if ! docker info >/dev/null 2>&1 ||
            docker image inspect "$image" >/dev/null 2>&1; then
            warn " · 无法清理 Compose 回滚镜像：$image"
            rc=1
          fi
        fi
      done <"${rollback_dir}/images.list"
    done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  fi
  if [[ -f "${RESTORE_TRANSACTION_DIR}/volumes.tsv" ]]; then
    while IFS=$'\t' read -r volume existed rollback_file; do
      [[ "$existed" == "1" ]] || continue
      if ! rm -f "$rollback_file"; then
        warn " · 无法清理命名卷回滚包：$rollback_file"
        rc=1
      fi
    done <"${RESTORE_TRANSACTION_DIR}/volumes.tsv"
  fi
  if [[ -f "${RESTORE_TRANSACTION_DIR}/binds.tsv" ]]; then
    while IFS=$'\t' read -r host had_old old; do
      [[ "$had_old" == "1" ]] || continue
      if ! root_exec rm -rf "$old"; then
        warn " · 无法清理绑定目录回滚点：$old"
        rc=1
      fi
    done <"${RESTORE_TRANSACTION_DIR}/binds.tsv"
  fi
  if ! root_exec rm -rf "${RESTORE_TRANSACTION_DIR}/file_backups"; then
    warn " · 无法清理文件回滚点：${RESTORE_TRANSACTION_DIR}/file_backups"
    rc=1
  fi

  # 清理失败时保留所有事务清单。提交后的 EXIT handler 会将该目录报告为
  # FAILED_POST_COMMIT 的待清理资料，便于定位尚未删除的回滚点。
  return "$rc"
}

transaction_rollback() {
  local name state project had_old services_quiet=1 data_ok=1 rc=0 preserve_compose=0
  ((TRANSACTION_ACTIVE == 1)) || return 0
  warn "恢复事务失败，正在统一回滚服务与数据……"

  # 提交阶段若某个共享写入者重启失败，先重新静默已经启动的写入者。
  if [[ -f "${RESTORE_TRANSACTION_DIR}/shared.tsv" ]]; then
    while IFS=$'\t' read -r name state; do
      [[ -n "$name" ]] || continue
      transaction_quiesce_container "$name" >/dev/null || true
    done <"${RESTORE_TRANSACTION_DIR}/shared.tsv"
  fi

  run_with_activity "自动回滚：停止并移除本次新服务" \
    transaction_remove_new_services || services_quiet=0
  if ((services_quiet == 1)); then
    # 目标文件最后写入、但可能位于已替换 bind 内；严格按修改逆序回滚，
    # 先撤销单文件覆盖，再整体换回 bind，最后恢复 volume。
    run_with_activity "自动回滚：恢复被替换的配置文件" \
      transaction_restore_files || data_ok=0
    run_with_activity "自动回滚：恢复绑定目录数据" \
      transaction_restore_binds || data_ok=0
    run_with_activity "自动回滚：恢复命名卷数据" \
      transaction_restore_volumes || data_ok=0
    ((data_ok == 1)) || rc=1

    say "[进度] 自动回滚：恢复旧 Compose 项目"
    transaction_restore_compose "$data_ok" || rc=1
    say "[进度] 自动回滚：恢复旧独立容器"
    transaction_restore_standalones "$data_ok" || rc=1
    if ((data_ok == 1)); then
      say "[进度] 自动回滚：恢复共享挂载写入者"
      transaction_restore_shared || rc=1
    else
      warn "数据回滚不完整，旧服务与共享写入者保持停止，请按回滚目录人工处理。"
    fi
  else
    rc=1
    data_ok=0
    warn "新服务未能全部静默，禁止回灌旧数据；已保留全部回滚点供人工处理。"
  fi

  if ((rc == 0)); then
    while IFS=$'\t' read -r project had_old; do
      if [[ "$had_old" == "1" ]] &&
        grep -Fxq "$project" "${RESTORE_TRANSACTION_DIR}/compose_replaced.list"; then
        preserve_compose=1
        break
      fi
    done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
    if ((preserve_compose == 1)); then
      # Compose 会把实际配置文件路径写入容器 labels。回滚后的容器仍引用这里的
      # config.yml/images.yml，因此保留这些小文件，后续迁移才能再次建立回滚点。
      if ! transaction_cleanup_artifacts 1; then
        warn "部分无用回滚资料未能清理，事务清单已保留：$RESTORE_TRANSACTION_DIR"
      fi
      warn "目标端旧服务、volume 与 bind 数据已统一恢复。"
      warn "Compose 回滚配置需随旧容器保留：$RESTORE_TRANSACTION_DIR"
    else
      if transaction_cleanup_artifacts; then
        rm -rf "$RESTORE_TRANSACTION_DIR" ||
          warn "回滚已完成，但事务目录未能删除：$RESTORE_TRANSACTION_DIR"
      else
        warn "回滚已完成，但部分无用回滚资料未能清理：$RESTORE_TRANSACTION_DIR"
      fi
      warn "目标端旧服务、volume 与 bind 数据已统一恢复。"
    fi
  else
    warn "自动回滚未完全成功，已保留回滚目录：$RESTORE_TRANSACTION_DIR"
  fi
  TRANSACTION_ACTIVE=0
  transaction_release_lock
  return "$rc"
}

transaction_exit_handler() {
  local original_rc=$? exit_rc rollback_rc=0 rollback_dir="${RESTORE_TRANSACTION_DIR:-}" status
  exit_rc=$original_rc
  trap - EXIT INT TERM
  restore_diagnostic_output

  # RESTORE_COMMIT_STARTED 是唯一的不可逆提交点。它置位后绝不再回滚，即使
  # TRANSACTION_ACTIVE 尚未来得及清零或清理过程中收到 INT/TERM。
  if ((RESTORE_COMMIT_STARTED == 1)); then
    transaction_release_lock || true
    if ((original_rc == 0)); then
      status="SUCCESS"
    else
      status="FAILED_POST_COMMIT"
    fi
    restore_finish_result "$status" "$rollback_dir"
    exit "$exit_rc"
  fi

  if ((TRANSACTION_ACTIVE == 1)); then
    set +e
    transaction_rollback
    rollback_rc=$?
    set -e
    ((exit_rc != 0)) || exit_rc=1
  fi
  if [[ "$original_rc" == "129" || "$original_rc" == "130" || "$original_rc" == "143" ]]; then
    if ((rollback_rc == 0)); then
      status="INTERRUPTED_ROLLED_BACK"
    else
      status="INTERRUPTED_ROLLBACK_INCOMPLETE"
    fi
  elif ((rollback_rc == 0)); then
    status="FAILED_ROLLED_BACK"
  else
    status="FAILED_ROLLBACK_INCOMPLETE"
  fi
  restore_finish_result "$status" "$rollback_dir"
  exit "$exit_rc"
}
