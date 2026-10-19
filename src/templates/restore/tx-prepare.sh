transaction_prepare() {
  local policy="${RESTORE_EXISTING:-replace}" has_data=0 existing_targets=0
  local project run name state had_old id inspect mount type source selected_path matched
  local rollback_dir rollback_base lock_base self_container_name="" quiesce_list_file
  local -a quiesce_names=()

  case "$policy" in replace | skip | fail) ;; *)
    warn "RESTORE_EXISTING 值无效：$policy（应为 replace、skip 或 fail）"
    return 1
    ;;
  esac

  rollback_base="${RESTORE_ROLLBACK_BASE:-${HOME:-${BUNDLE_DIR}}/.docker_migrate_rollback}"
  lock_base="${RESTORE_LOCK_BASE:-${HOME:-${BUNDLE_DIR}}/.docker_migrate_locks}"
  transaction_internal_paths_are_safe || return 1
  mkdir -p "$rollback_base"
  chmod 700 "$rollback_base" 2>/dev/null || true
  mkdir -p "$lock_base"
  chmod 700 "$lock_base" 2>/dev/null || true
  transaction_acquire_lock "$lock_base" || return 1
  trap restore_nontransaction_exit_handler EXIT

  if jq -e '(.volumes | length) > 0 or (.binds | length) > 0' manifest.json >/dev/null; then
    has_data=1
  fi
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    if [[ -n "$(docker ps -a --filter "label=com.docker.compose.project=${project}" \
      --format '{{.ID}}')" ]]; then
      existing_targets=$((existing_targets + 1))
    fi
  done < <(jq -r '.projects[].name' manifest.json)
  while IFS= read -r run; do
    name="$(basename "${run%.sh}")"
    transaction_container_exists "$name" && existing_targets=$((existing_targets + 1))
  done < <(jq -r '.runs[]' manifest.json)

  if [[ "$policy" == "fail" && "$existing_targets" -gt 0 ]]; then
    warn "目标端已存在待恢复服务，RESTORE_EXISTING=fail 在修改任何数据前终止。"
    transaction_release_lock
    trap restore_nontransaction_exit_handler EXIT
    return 1
  fi
  if [[ "$policy" == "skip" && "$has_data" == "1" && "$existing_targets" -gt 0 ]]; then
    warn "RESTORE_EXISTING=skip 无法安全区分共享数据归属；存在 volume/bind 时拒绝部分覆盖。"
    transaction_release_lock
    trap restore_nontransaction_exit_handler EXIT
    return 1
  fi

  if jq -e '.projects | length > 0' manifest.json >/dev/null; then
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      COMPOSE_IMPL="plugin"
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_IMPL="legacy"
    else
      warn "新机未安装 docker compose/docker-compose，恢复尚未修改目标端。"
      transaction_release_lock
      trap restore_nontransaction_exit_handler EXIT
      return 1
    fi
  fi

  RESTORE_TRANSACTION_DIR="$(mktemp -d \
    "${rollback_base}/transaction.XXXXXX")" || {
    transaction_release_lock
    trap restore_nontransaction_exit_handler EXIT
    return 1
  }
  export RESTORE_TRANSACTION_DIR
  mkdir -p "${RESTORE_TRANSACTION_DIR}/compose" \
    "${RESTORE_TRANSACTION_DIR}/file_backups" \
    "${RESTORE_TRANSACTION_DIR}/standalone_networks"
  : >"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/standalone.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/shared.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/volumes.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/binds.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/files.tsv"
  : >"${RESTORE_TRANSACTION_DIR}/managed_names.list"
  : >"${RESTORE_TRANSACTION_DIR}/all_target_names.list"
  : >"${RESTORE_TRANSACTION_DIR}/compose_replaced.list"

  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    had_old=0
    if [[ -n "$(docker ps -a --filter "label=com.docker.compose.project=${project}" \
      --format '{{.ID}}')" ]]; then
      had_old=1
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        printf '%s\n' "$name" >>"${RESTORE_TRANSACTION_DIR}/all_target_names.list"
      done < <(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}')
      if [[ "$policy" == "skip" ]]; then
        SKIP_PROJECTS["$project"]=1
        continue
      fi
      rollback_dir="${RESTORE_TRANSACTION_DIR}/compose/${project}"
      echo " · 保存目标端旧 Compose 配置与运行状态：$project"
      if ! compose_capture_rollback_metadata "$project" "$rollback_dir"; then
        warn " · 无法安全读取 Compose 回滚元数据，目标端尚未停止：$project"
        transaction_discard_prepared
        return 1
      fi
      docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}' \
        >>"${RESTORE_TRANSACTION_DIR}/managed_names.list"
    fi
    printf '%s\t%s\n' "$project" "$had_old" >>"${RESTORE_TRANSACTION_DIR}/compose.tsv"
  done < <(jq -r '.projects[].name' manifest.json)

  while IFS= read -r run; do
    [[ -n "$run" ]] || continue
    name="$(basename "${run%.sh}")"
    had_old=0
    state="absent"
    if transaction_container_exists "$name"; then
      had_old=1
      state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo unknown)"
      printf '%s\n' "$name" >>"${RESTORE_TRANSACTION_DIR}/all_target_names.list"
      if [[ "$policy" == "skip" ]]; then
        SKIP_CONTAINERS["$name"]=1
        continue
      fi
      printf '%s\n' "$name" >>"${RESTORE_TRANSACTION_DIR}/managed_names.list"
    fi
    printf '%s\t%s\t%s\n' "$name" "$had_old" "$state" \
      >>"${RESTORE_TRANSACTION_DIR}/standalone.tsv"
  done < <(jq -r '.runs[]' manifest.json)

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    SELECTED_TRANSACTION_VOLUMES["$name"]=1
  done < <(jq -r '.volumes[].name' manifest.json)
  SELECTED_TRANSACTION_BINDS=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    bind_path_is_system "$name" || SELECTED_TRANSACTION_BINDS+=("$name")
  done < <(jq -r '.binds[] | .host, (.link // empty)' manifest.json)

  # restore.sh 也可在挂载 Docker socket 的工具容器中运行；绝不能把执行自身停掉。
  if docker container inspect "$(hostname)" >/dev/null 2>&1; then
    self_container_name="$(docker inspect -f '{{.Name}}' "$(hostname)" 2>/dev/null | sed 's#^/##')"
  fi

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')"
    [[ -n "$name" ]] || continue
    grep -Fxq "$name" "${RESTORE_TRANSACTION_DIR}/all_target_names.list" && continue
    inspect="$(docker inspect "$id" 2>/dev/null)" || continue
    matched=0
    while IFS= read -r mount; do
      [[ -n "$mount" ]] || continue
      type="$(jq -r '.Type // empty' <<<"$mount")"
      source="$(jq -r 'if .Type == "volume" then .Name else .Source end // empty' <<<"$mount")"
      if [[ "$type" == "volume" && -n "${SELECTED_TRANSACTION_VOLUMES[$source]:-}" ]]; then
        matched=1
        break
      fi
      if [[ "$type" == "bind" ]] && ((${#SELECTED_TRANSACTION_BINDS[@]} > 0)); then
        for selected_path in "${SELECTED_TRANSACTION_BINDS[@]}"; do
          if mount_paths_overlap "$source" "$selected_path"; then
            matched=1
            break 2
          fi
        done
      fi
    done < <(jq -c '.[0].Mounts[]?' <<<"$inspect")
    if ((matched == 1)); then
      if [[ -n "$self_container_name" && "$name" == "$self_container_name" ]]; then
        warn " · 恢复脚本运行容器共享目标路径，保持自身运行：$name"
        continue
      fi
      case ",${RESTORE_IGNORE_CONTAINERS:-${DOCKER_MIGRATE_IGNORE_CONTAINERS:-}}," in
        *,"$name",*)
          warn " · 已显式忽略共享挂载容器：$name"
          continue
          ;;
      esac
      state="$(jq -r '.[0].State.Status // "running"' <<<"$inspect")"
      printf '%s\t%s\n' "$name" "$state" >>"${RESTORE_TRANSACTION_DIR}/shared.tsv"
    fi
  done < <(docker ps -q)

  sort -u -o "${RESTORE_TRANSACTION_DIR}/managed_names.list" \
    "${RESTORE_TRANSACTION_DIR}/managed_names.list"
  sort -u -o "${RESTORE_TRANSACTION_DIR}/shared.tsv" "${RESTORE_TRANSACTION_DIR}/shared.tsv"

  TRANSACTION_ACTIVE=1
  trap transaction_exit_handler EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  quiesce_list_file="${RESTORE_TRANSACTION_DIR}/quiesce_names.list"
  if ! transaction_build_quiesce_list \
    "${RESTORE_TRANSACTION_DIR}/shared.tsv" \
    "${RESTORE_TRANSACTION_DIR}/managed_names.list" "$quiesce_list_file"; then
    warn "无法完整生成目标端停机名单，尚未停止服务或回灌数据。"
    return 1
  fi
  mapfile -t quiesce_names <"$quiesce_list_file"
  for name in "${quiesce_names[@]}"; do
    echo " · 准备暂停目标端服务或共享写入者：$name"
  done
  transaction_quiesce_containers "${quiesce_names[@]}" || return 1

  # 所有目标服务及共享写入者停止后再提交 writable layer，使容器快照与
  # 随后建立的 volume/bind 数据回滚点处于同一个静默窗口。
  while IFS=$'\t' read -r project had_old; do
    [[ "$had_old" == "1" ]] || continue
    rollback_dir="${RESTORE_TRANSACTION_DIR}/compose/${project}"
    echo " · 保存已静默的旧 Compose 容器镜像：$project"
    compose_capture_rollback_images "$rollback_dir" || return 1
  done <"${RESTORE_TRANSACTION_DIR}/compose.tsv"
}

transaction_commit() {
  local name state shared_ok=1
  ((TRANSACTION_ACTIVE == 1)) || return 0
  if [[ -f "${RESTORE_TRANSACTION_DIR}/shared.tsv" ]]; then
    while IFS=$'\t' read -r name state; do
      [[ -n "$name" ]] || continue
      if ! transaction_restore_container_state "$name" "$state"; then
        warn " · 新服务已验证，但共享挂载容器无法恢复：$name"
        shared_ok=0
      fi
    done <"${RESTORE_TRANSACTION_DIR}/shared.tsv"
  fi
  ((shared_ok == 1)) || return 1

  # 这是不可逆提交点：新服务及数据已验证，共享写入者也已恢复。
  # EXIT handler 始终保持不变，只用这一条赋值区分“可回滚”与“已提交”；
  # 因此 INT/TERM 不会落入 trap 切换或两个状态变量之间的竞态窗口。
  RESTORE_STAGE="提交与清理回滚点"
  RESTORE_COMMIT_STARTED=1
  TRANSACTION_ACTIVE=0
  if ! run_with_activity "提交事务：清理旧容器、镜像和数据回滚点" \
    transaction_cleanup_artifacts; then
    warn "服务与数据已恢复，但部分旧回滚资料清理失败：$RESTORE_TRANSACTION_DIR"
    return 1
  fi
  if ! run_with_activity "提交事务：删除临时事务目录" \
    rm -rf "$RESTORE_TRANSACTION_DIR"; then
    warn "服务与数据已恢复，但事务目录清理失败：$RESTORE_TRANSACTION_DIR"
    return 1
  fi
  RESTORE_TRANSACTION_DIR=""
  export RESTORE_TRANSACTION_DIR
  transaction_release_lock
  RESTORE_STAGE="完成"
  say "所有服务与数据已通过验证，恢复事务已提交。"
}
