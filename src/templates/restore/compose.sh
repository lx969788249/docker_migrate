compose_run() {
  if [[ "${COMPOSE_IMPL:-}" == "plugin" ]]; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

compose_rollback_image_cleanup() {
  local rollback_dir="$1" image
  [[ -f "${rollback_dir}/images.list" ]] || return 0
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    dm_quiet docker image rm "$image" || true
  done <"${rollback_dir}/images.list"
}

compose_capture_rollback_metadata() {
  local project="$1" rollback_dir="$2"
  local first_id old_wdir config_files normalized file id service state
  local -a ids=() config_args=()

  mapfile -t ids < <(docker ps -a \
    --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}')
  ((${#ids[@]} > 0)) || return 2
  mkdir -p "$rollback_dir"
  first_id="${ids[0]}"
  old_wdir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$first_id" 2>/dev/null || true)"
  config_files="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$first_id" 2>/dev/null || true)"
  normalized="${config_files//,/:}"
  if [[ -n "$normalized" ]]; then
    IFS=':' read -r -a old_files <<<"$normalized"
    for file in "${old_files[@]}"; do
      [[ -n "$file" ]] || continue
      [[ "$file" == /* ]] || file="${old_wdir}/${file}"
      [[ -f "$file" ]] || {
        warn " · 新服务器上已有项目的 Compose 文件找不到（${file}），无法先备份它，已停止"
        return 1
      }
      config_args+=(-f "$file")
    done
  fi

  if [[ -n "$old_wdir" ]]; then
    if ! (cd "$old_wdir" && compose_run -p "$project" "${config_args[@]}" config) \
      >"${rollback_dir}/config.yml" 2>/dev/null; then
      warn " · 新服务器上已有的 Compose 项目 ${project} 配置无法读取，为避免损坏它，已停止"
      return 1
    fi
  elif ! compose_run -p "$project" "${config_args[@]}" config \
    >"${rollback_dir}/config.yml" 2>/dev/null; then
    warn " · 新服务器上已有的 Compose 项目 ${project} 找不到所在目录，无法先备份它，已停止"
    return 1
  fi

  printf '{"services":{}}\n' >"${rollback_dir}/images.yml"
  : >"${rollback_dir}/images.list"
  : >"${rollback_dir}/states.tsv"
  for id in "${ids[@]}"; do
    service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$id" 2>/dev/null || true)"
    [[ -n "$service" ]] || {
      warn " · 新服务器上的容器 ${id} 缺少 Compose 服务名，无法备份"
      compose_rollback_image_cleanup "$rollback_dir"
      return 1
    }
    if awk -F '\t' -v service="$service" '$1 == service { found=1 } END { exit found ? 0 : 1 }' \
      "${rollback_dir}/states.tsv"; then
      warn " · Compose 服务存在多个副本，当前无法保证逐容器回滚：$service"
      compose_rollback_image_cleanup "$rollback_dir"
      return 1
    fi
    state="$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || echo unknown)"
    printf '%s\t%s\t%s\n' "$service" "$state" "$id" >>"${rollback_dir}/states.tsv"
  done
}

compose_capture_rollback_images() {
  local rollback_dir="$1"
  local service state id image tmp
  : >"${rollback_dir}/images.list"
  printf '{"services":{}}\n' >"${rollback_dir}/images.yml"
  while IFS=$'\t' read -r service state id; do
    [[ -n "$service" && -n "$id" ]] || continue
    if ! docker container inspect "$id" >/dev/null 2>&1; then
      warn " · 备份过程中，新服务器上的 Compose 服务 ${service} 的容器不见了"
      compose_rollback_image_cleanup "$rollback_dir"
      return 1
    fi
    image="docker-migrate-rollback:${id:0:12}-$$"
    if ! run_with_activity "创建 Compose 回滚镜像：$service" \
      dm_quiet docker commit "$id" "$image"; then
      warn " · Compose 服务 ${service} 的容器没能备份"
      compose_rollback_image_cleanup "$rollback_dir"
      return 1
    fi
    printf '%s\n' "$image" >>"${rollback_dir}/images.list"
    tmp="${rollback_dir}/images.yml.tmp"
    jq --arg service "$service" --arg image "$image" \
      '.services[$service].image = $image' "${rollback_dir}/images.yml" >"$tmp"
    mv "$tmp" "${rollback_dir}/images.yml"
  done <"${rollback_dir}/states.tsv"
}

compose_restore_existing_states() {
  local project="$1" rollback_dir="$2" restore_running="${3:-1}"
  local service state id rc=0
  [[ -f "${rollback_dir}/states.tsv" ]] || return 1
  while IFS=$'\t' read -r service state id; do
    [[ -n "$id" ]] || continue
    if ! docker container inspect "$id" >/dev/null 2>&1; then
      warn " · 目标端旧 Compose 容器已不存在：$service ($id)"
      rc=1
      continue
    fi
    [[ "$restore_running" == "1" ]] || continue
    case "$state" in
      running | restarting)
        dm_quiet docker start "$id" || rc=1
        ;;
      paused)
        dm_quiet docker start "$id" || {
          rc=1
          continue
        }
        dm_quiet docker pause "$id" || rc=1
        ;;
    esac
  done <"${rollback_dir}/states.tsv"
  return "$rc"
}

compose_restore_rollback() {
  local project="$1" rollback_dir="$2" restore_running="${3:-1}"
  local service state id _recorded_id
  local -a start_services=() pause_services=()
  [[ -s "${rollback_dir}/config.yml" && -s "${rollback_dir}/images.yml" ]] || return 1
  (
    cd "$rollback_dir"
    compose_run -p "$project" -f config.yml -f images.yml up --no-start
    while IFS=$'\t' read -r service state _recorded_id; do
      case "$state" in
        running | restarting) start_services+=("$service") ;;
        paused)
          start_services+=("$service")
          pause_services+=("$service")
          ;;
      esac
    done <states.tsv
    if [[ "$restore_running" == "1" ]]; then
      ((${#start_services[@]} == 0)) ||
        compose_run -p "$project" -f config.yml -f images.yml start "${start_services[@]}"
      for service in "${pause_services[@]}"; do
        while IFS= read -r id; do
          [[ -n "$id" ]] || continue
          dm_quiet docker pause "$id"
        done < <(compose_run -p "$project" -f config.yml -f images.yml ps -q "$service")
      done
    fi
  )
}

compose_source_state_records() {
  local project="$1" file file_project service running paused found=0
  for file in "${BUNDLE_DIR}"/meta/*.inspect.json; do
    [[ -f "$file" ]] || continue
    file_project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$file" 2>/dev/null || true)"
    [[ "$file_project" == "$project" ]] || continue
    service="$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // empty' "$file")"
    [[ -n "$service" ]] || continue
    running="$(jq -r '.[0].State.Running // false' "$file")"
    paused="$(jq -r '.[0].State.Paused // false' "$file")"
    if [[ "$paused" == "true" ]]; then
      printf '%s\tpaused\n' "$service"
    elif [[ "$running" == "true" ]]; then
      printf '%s\trunning\n' "$service"
    else
      printf '%s\tstopped\n' "$service"
    fi
    found=1
  done
  ((found == 1))
}

compose_wait_services() {
  local timeout="$1"
  shift
  local deadline=$((SECONDS + timeout)) started=$SECONDS next_report=0
  local service id status all_ready service_found elapsed pending first_pending
  local -a compose_args=()
  while (($# > 0)) && [[ "$1" != -- ]]; do
    compose_args+=("$1")
    shift
  done
  (($# == 0)) || shift
  local -a services=("$@")

  while ((SECONDS < deadline)); do
    all_ready=1
    pending=0
    first_pending=""
    for service in "${services[@]}"; do
      service_found=0
      while IFS= read -r id; do
        [[ -n "$id" ]] || {
          all_ready=0
          pending=$((pending + 1))
          [[ -n "$first_pending" ]] || first_pending="$service（尚未创建）"
          continue
        }
        service_found=1
        status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)"
        case "$status" in
          healthy | running) ;;
          unhealthy | exited | dead)
            fail_reason "Compose 服务 ${service} 健康检查没有通过（当前 ${status}）" "执行 docker logs <容器名> 查看服务日志"
            return 1
            ;;
          *)
            all_ready=0
            pending=$((pending + 1))
            [[ -n "$first_pending" ]] || first_pending="$service（${status:-未知}）"
            ;;
        esac
      done < <(compose_run "${compose_args[@]}" ps -q "$service")
      if ((service_found == 0)); then
        all_ready=0
        pending=$((pending + 1))
        [[ -n "$first_pending" ]] || first_pending="$service（未找到容器）"
      fi
    done
    if ((all_ready == 0)); then
      elapsed=$((SECONDS - started))
      if ((elapsed >= next_report)); then
        log_line "[进度] Compose 服务健康检查：${services[*]} · 待就绪 ${pending} 个 · ${first_pending:-未知} · ${elapsed}/${timeout}秒"
        next_report=$((elapsed + 5))
      fi
    else
      log_line "[完成] Compose 服务健康检查：${services[*]} · $((SECONDS - started))秒"
      return 0
    fi
    sleep 1
  done
  return 1
}

compose_wait_project_health() {
  local project="$1" timeout="$2"
  local deadline=$((SECONDS + timeout)) started=$SECONDS next_report=0
  local id running health all_ready found elapsed pending first_pending
  while ((SECONDS < deadline)); do
    all_ready=1
    found=0
    pending=0
    first_pending=""
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      found=1
      running="$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || echo false)"
      [[ "$running" == "true" ]] || continue
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)"
      case "$health" in
        healthy | none) ;;
        unhealthy)
          fail_reason "Compose 项目 ${project} 的容器 ${id} 健康检查没有通过" "执行 docker logs ${id} 查看服务日志"
          return 1
          ;;
        *)
          all_ready=0
          pending=$((pending + 1))
          [[ -n "$first_pending" ]] || first_pending="容器 $id（${health:-未知}）"
          ;;
      esac
    done < <(docker ps -a \
      --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}')
    if ((found == 0)); then
      all_ready=0
      pending=1
      first_pending="尚未找到项目容器"
    fi
    if ((all_ready == 0)); then
      elapsed=$((SECONDS - started))
      if ((elapsed >= next_report)); then
        log_line "[进度] Compose 项目健康检查：$project · 待就绪 ${pending} 个 · ${first_pending:-未知} · ${elapsed}/${timeout}秒"
        next_report=$((elapsed + 5))
      fi
    else
      log_line "[完成] Compose 项目健康检查：$project · $((SECONDS - started))秒"
      return 0
    fi
    sleep 1
  done
  return 1
}
