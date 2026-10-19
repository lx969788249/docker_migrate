trap restore_nontransaction_exit_handler EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RESTORE_STAGE="迁移包校验"
if [[ "${RESTORE_CHECKSUM_VERIFIED:-0}" == "1" ]]; then
  :
elif [[ -f checksums.sha256 ]]; then
  say "[0] 验证迁移包完整性"
  if ! run_with_activity "校验迁移包内全部文件" verify_bundle_checksums "$BUNDLE_DIR"; then
    warn "迁移包完整性校验失败，拒绝恢复。"
    exit 1
  fi
else
  warn "旧版迁移包未包含校验清单，按兼容模式继续。"
fi
if ! bundle_manifest_is_safe "$BUNDLE_DIR"; then
  warn "迁移包 manifest 结构或路径不安全，拒绝恢复。"
  exit 1
fi
if ! transaction_internal_paths_are_safe; then
  exit 1
fi

RESTORE_STAGE="预检数据归档"
if jq -e '(.volumes | length) > 0 or (.binds | length) > 0' manifest.json >/dev/null &&
  ! command -v python3 >/dev/null 2>&1; then
  warn "缺少 python3，尚未停止服务或修改数据；请使用主脚本「下载备份并恢复」自动补齐依赖。"
  exit 1
fi
say "[0.1] 在停止目标服务前预检 volume 与 bind 归档"
if jq -e '.volumes|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r row; do
    vname="$(jq -r '.name' <<<"$row")"
    file="vol_${vname}.tgz"
    if [[ ! -f "volumes/$file" ]]; then
      warn " 命名卷缺少备份文件：$vname（volumes/$file）"
      FAILED_VOLUMES+=("$vname")
    elif ! run_with_activity "预检命名卷归档：$vname" \
      archive_members_safe "volumes/$file"; then
      warn " 命名卷归档结构异常：$vname"
      FAILED_VOLUMES+=("$vname")
    fi
  done < <(jq -c '.volumes[]' manifest.json)
fi
if jq -e '.binds|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r row; do
    host="$(jq -r '.host' <<<"$row")"
    file="$(jq -r '.file' <<<"$row")"
    bind_prefix="${host#/}"
    if bind_path_is_system "$host"; then
      warn " 跳过宿主机系统路径，只重建挂载、不覆盖目标端：$host"
    elif [[ ! -f "binds/$file" ]]; then
      warn " 绑定目录缺少备份文件：$host（binds/$file）"
      FAILED_BINDS+=("$host")
    elif ! run_with_activity "预检绑定目录归档：$host" \
      archive_members_safe "binds/$file" "$bind_prefix"; then
      warn " 绑定目录归档结构异常：$host"
      FAILED_BINDS+=("$host")
    fi
  done < <(jq -c '.binds[]' manifest.json)
fi
if ((${#FAILED_VOLUMES[@]} > 0 || ${#FAILED_BINDS[@]} > 0)); then
  print_failure_summary
  exit 1
fi

RESTORE_STAGE="加载镜像"
say "[A] 加载镜像（如 images.tar 存在）"
if [[ -f images.tar ]]; then
  run_with_activity "加载镜像归档 images.tar" restore_load_images images.tar ||
    warn "部分镜像加载失败，将尝试在线拉取"
else
  warn "images.tar 不存在，将按需在线拉取镜像。"
fi

RESTORE_STAGE="建立统一回滚事务"
say "[A.1] 建立目标端服务与数据统一回滚事务"
if jq -e '(.volumes | length) > 0 or (.binds | length) > 0' manifest.json >/dev/null &&
  ! docker image inspect alpine:3.20 >/dev/null 2>&1; then
  run_with_activity "拉取卷操作镜像 alpine:3.20" docker pull alpine:3.20 || {
    warn "无法准备 alpine:3.20；为避免在无回滚能力时修改数据，恢复终止。"
    exit 1
  }
fi
transaction_prepare

RESTORE_STAGE="回灌命名卷"
say "[B] 回灌命名卷"
if jq -e '.volumes|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p volumes
  while IFS= read -r row; do
    vname=$(jq -r '.name' <<<"$row")
    file="vol_${vname}.tgz"
    if [[ ! -f "volumes/$file" ]]; then
      warn " 命名卷缺少备份文件：$vname（volumes/$file）"
      FAILED_VOLUMES+=("$vname")
      break
    fi
    echo " - ${vname}"
    # 使用备份时记录的 driver 和 options 创建卷；同名卷已存在时必须先
    # 核对后端，绝不能把 NFS/plugin 数据误写进碰巧同名的 local 卷。
    v_driver=$(jq -r '.driver // "local"' <<<"$row")
    desired_volume_opts="$(jq -cS '.opts // {}' <<<"$row")"
    volume_existed=0
    if docker volume inspect "$vname" >/dev/null 2>&1; then
      volume_existed=1
      actual_volume_driver="$(docker volume inspect "$vname" | jq -r '.[0].Driver // "local"')"
      actual_volume_opts="$(docker volume inspect "$vname" | jq -cS '.[0].Options // {}')"
      if [[ "$actual_volume_driver" != "$v_driver" ||
        "$actual_volume_opts" != "$desired_volume_opts" ]]; then
        warn " 已存在同名但 driver/options 不同的卷，拒绝覆盖：$vname"
        FAILED_VOLUMES+=("$vname")
        break
      fi
    else
      volume_create_args=(docker volume create --driver "$v_driver")
      mapfile -t volume_opts < <(jq -r '.opts // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row" 2>/dev/null || true)
      for volume_opt in "${volume_opts[@]}"; do
        volume_create_args+=(--opt "$volume_opt")
      done
      volume_create_args+=("$vname")
      if ! "${volume_create_args[@]}" >/dev/null; then
        warn " 卷创建失败（driver=$v_driver）：$vname"
        FAILED_VOLUMES+=("$vname")
        break
      fi
    fi
    if ! run_with_activity "回灌命名卷：$vname" \
      restore_data_with_diagnostics "命名卷：$vname" \
      restore_volume_exact "$vname" "$PWD/volumes" "$file" \
      "${RESTORE_TRANSACTION_DIR}/volume_data" "$volume_existed" 1; then
      warn " 恢复卷 ${vname} 失败，终止恢复"
      FAILED_VOLUMES+=("$vname")
      break
    fi
  done < <(jq -c '.volumes[]' manifest.json)
fi

# 不覆盖后续绑定目录，也不让 RESTORE_STAGE 掩盖真正失败的数据卷阶段。
if ((${#FAILED_VOLUMES[@]} > 0)); then
  print_failure_summary
  exit 1
fi

RESTORE_STAGE="回灌绑定目录"
say "[C] 回灌绑定目录"
if jq -e '.binds|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p binds
  while IFS= read -r row; do
    host=$(jq -r '.host' <<<"$row")
    file=$(jq -r '.file' <<<"$row")
    bind_link=$(jq -r '.link // empty' <<<"$row")
    bind_path_is_system "$host" && continue
    if [[ ! -f "binds/$file" ]]; then
      warn " 绑定目录缺少备份文件：$host（binds/$file）"
      FAILED_BINDS+=("$host")
      break
    fi
    echo " - ${host}"
    if ! run_with_activity "回灌绑定目录：$host" \
      restore_data_with_diagnostics "绑定目录：$host" \
      restore_bind_exact "$host" "$PWD/binds/${file}" 1; then
      warn " 恢复绑定目录失败，终止恢复：$host"
      FAILED_BINDS+=("$host")
      break
    fi
    if ! restore_bind_link "$bind_link" "$host"; then
      warn " 无法在原路径重建软链接，终止恢复：$bind_link -> $host"
      FAILED_BINDS+=("$bind_link")
      break
    fi
  done < <(jq -c '.binds[]' manifest.json)
fi

# 数据恢复失败时禁止继续启动容器，避免 Docker 自动创建空卷/空目录。
if ((${#FAILED_VOLUMES[@]} > 0 || ${#FAILED_BINDS[@]} > 0)); then
  print_failure_summary
  exit 1
fi

RESTORE_STAGE="恢复 Compose 项目"
say "[D] 恢复 Compose 项目"
if jq -e '.projects|length>0' manifest.json >/dev/null 2>&1; then
  COMPOSE_RESTORE_ROOT="${RESTORE_TRANSACTION_DIR}/incoming_compose"
  mkdir -p "$COMPOSE_RESTORE_ROOT"
  while IFS= read -r row; do
    USE_WDIR=0
    name=$(jq -r '.name' <<<"$row")
    wdir=$(jq -r '.working_dir // ""' <<<"$row")
    echo " - project: $name"
    mkdir -p "${COMPOSE_RESTORE_ROOT}/${name}"

    if [[ -n "${SKIP_PROJECTS[$name]:-}" ]]; then
      warn " · Compose 项目已存在，按 RESTORE_EXISTING=skip 保持不变：$name"
      continue
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      compose_impl="plugin"
    elif command -v docker-compose >/dev/null 2>&1; then
      compose_impl="legacy"
    else
      warn " 新机未安装 docker compose/docker-compose，跳过该项目。"
      FAILED_PROJECTS+=("$name")
      continue
    fi
    COMPOSE_IMPL="$compose_impl"

    if [[ -d "compose/${name}" ]]; then
      cp -a "compose/${name}/." "${COMPOSE_RESTORE_ROOT}/${name}/"
    fi

    # 在第一个目标端文件或服务被改动前先写入 WAL；回滚据此判断是否需要
    # 删除本次 Compose 容器并从静默快照重建旧项目。
    printf '%s\n' "$name" >>"${RESTORE_TRANSACTION_DIR}/compose_replaced.list"

    if [[ -n "$wdir" ]]; then
      echo " · 还原 compose 配置到原路径：$wdir"
      transaction_install_tree "compose/${name}" "$wdir"
      # 如果 wdir 存在且 compose 文件已还原到 wdir，则从 wdir 执行 compose up
      # 这确保 1Panel / 宝塔等使用相对路径 bind mount 的 compose 项目能正确解析路径
      USE_WDIR=1
    fi

    # 恢复原本使用绝对路径的 env_file（普通相对路径已由递归复制保留）。
    if [[ -f "compose/${name}/.env_file_map.jsonl" ]]; then
      while IFS= read -r env_map; do
        env_source="$(jq -r '.source' <<<"$env_map")"
        env_stored="$(jq -r '.stored' <<<"$env_map")"
        [[ -n "$env_source" && -f "compose/${name}/${env_stored}" ]] || continue
        transaction_install_file "compose/${name}/${env_stored}" "$env_source"
      done <"compose/${name}/.env_file_map.jsonl"
    fi

    # 构建多文件 -f 参数：从 manifest 的 config_files 提取 basename
    # 如果没有 config_files，compose 会按默认文件名自动扫描
    declare -a COMPOSE_FILE_ARGS=()
    if jq -e '.config_files|length>0' <<<"$row" >/dev/null 2>&1; then
      while IFS= read -r cf; do
        [[ -n "$cf" ]] || continue
        local_fn="${COMPOSE_RESTORE_ROOT}/${name}/$(basename "$cf")"
        if [[ -f "$local_fn" ]]; then
          COMPOSE_FILE_ARGS+=(-f "$(basename "$cf")")
        fi
      done < <(jq -r '.config_files[]?' <<<"$row")
    fi

    if [[ "$USE_WDIR" == "1" ]]; then
      compose_dir="$wdir"
    else
      compose_dir="${COMPOSE_RESTORE_ROOT}/${name}"
    fi
    compose_rc=0
    (
      cd "$compose_dir"
      COMPOSE_IMPL="$compose_impl"
      compose_run "${COMPOSE_FILE_ARGS[@]}" config >/dev/null || exit 1
      compose_prepare_networks "$name" "${COMPOSE_FILE_ARGS[@]}" || exit 1
      declare -a source_state_records=() start_services=() pause_services=()
      mapfile -t source_state_records < <(compose_source_state_records "$name" || true)
      echo " · 已读取 ${#source_state_records[@]} 条源端服务状态"
      if ((${#source_state_records[@]} == 0)); then
        # 兼容旧迁移包：没有状态元数据时沿用全部启动行为。
        compose_run "${COMPOSE_FILE_ARGS[@]}" up -d 2>&1 || exit 1
        compose_wait_project_health "$name" "${RESTORE_HEALTH_TIMEOUT:-60}" || exit 1
      else
        compose_run "${COMPOSE_FILE_ARGS[@]}" up --no-start 2>&1 || exit 1
        for state_record in "${source_state_records[@]}"; do
          service="${state_record%%$'\t'*}"
          state="${state_record#*$'\t'}"
          case "$state" in
            running) start_services+=("$service") ;;
            paused)
              start_services+=("$service")
              pause_services+=("$service")
              ;;
          esac
        done
        if ((${#start_services[@]} > 0)); then
          compose_run "${COMPOSE_FILE_ARGS[@]}" start "${start_services[@]}" 2>&1 || exit 1
          compose_wait_services "${RESTORE_HEALTH_TIMEOUT:-60}" \
            "${COMPOSE_FILE_ARGS[@]}" -- "${start_services[@]}" || exit 1
        fi
        compose_wait_project_health "$name" "${RESTORE_HEALTH_TIMEOUT:-60}" || exit 1
        for service in "${pause_services[@]}"; do
          while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            docker pause "$id" >/dev/null || exit 1
          done < <(compose_run "${COMPOSE_FILE_ARGS[@]}" ps -q "$service")
        done
      fi
    ) || compose_rc=$?

    if ((compose_rc != 0)); then
      warn " · 新 Compose 项目启动失败：$name"
      FAILED_PROJECTS+=("$name")
      print_failure_summary
      exit 1
    fi
  done < <(jq -c '.projects[]' manifest.json)
fi

RESTORE_STAGE="创建独立容器网络"
say "[E] 创建独立容器自定义网络（非 Compose）"
declare -A COMPOSE_NETS=()
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  COMPOSE_NETS["$n"]=1
done < <(compose_networks_from_meta_all)

if jq -e '.networks|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r network_row; do
    n="$(jq -r '.name // empty' <<<"$network_row")"
    case "$n" in bridge | host | none | "") continue ;; esac
    if [[ -n "${COMPOSE_NETS[$n]:-}" ]]; then
      continue
    fi
    if ! create_network_from_record "$network_row"; then
      FAILED_NETWORKS+=("$n")
    fi
  done < <(jq -c '.networks[] | if type == "string" then
    {name: ., legacy: true, driver: "bridge", internal: false, attachable: false,
     enable_ipv6: false, options: {}, labels: {},
     ipam: {driver: "default", options: {}, config: []}}
    else . end' manifest.json)
fi

if ((${#FAILED_NETWORKS[@]} > 0)); then
  print_failure_summary
  exit 1
fi

# --network/--pid/--ipc container:X 要求 X 先存在。按依赖排序独立容器的恢复
# 顺序；被依附者若是 Compose 容器，已在 [D] 启动，不构成阻塞。循环依赖时按原顺序。
restore_runs_in_dependency_order() {
  local run name f id cname mode ref dep blocked progressed
  local -a pending=() next=()
  local -A name_of_id=() run_names=() done_names=()
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    id="$(jq -r '.[0].Id' "$f")"
    cname="$(jq -r '.[0].Name | ltrimstr("/")' "$f")"
    name_of_id["$id"]="$cname"
    name_of_id["${id:0:12}"]="$cname"
  done
  mapfile -t pending < <(jq -r '.runs[]' manifest.json)
  for run in "${pending[@]}"; do
    name="${run#runs/}"
    run_names["${name%.sh}"]=1
  done
  while ((${#pending[@]} > 0)); do
    next=()
    progressed=0
    for run in "${pending[@]}"; do
      name="${run#runs/}"
      name="${name%.sh}"
      blocked=0
      while IFS= read -r mode; do
        [[ "$mode" == container:* ]] || continue
        ref="${mode#container:}"
        dep="${name_of_id[$ref]:-${name_of_id[${ref:0:12}]:-$ref}}"
        if [[ "$dep" != "$name" && -n "${run_names[$dep]:-}" && -z "${done_names[$dep]:-}" ]]; then
          blocked=1
        fi
      done < <(jq -r '.[0].HostConfig | .NetworkMode, .PidMode, .IpcMode | values' \
        "meta/${name}.inspect.json" 2>/dev/null || true)
      if ((blocked == 1)); then
        next+=("$run")
      else
        printf '%s\n' "$run"
        done_names["$name"]=1
        progressed=1
      fi
    done
    if ((progressed == 0)); then
      printf '%s\n' "${next[@]}"
      break
    fi
    pending=("${next[@]+"${next[@]}"}")
  done
}

RESTORE_STAGE="恢复独立容器"
say "[F] 恢复单容器（非 Compose）"
if jq -e '.runs|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    cname_from_script="${r#runs/}"
    cname_from_script="${cname_from_script%.sh}"
    if [[ -n "${SKIP_CONTAINERS[$cname_from_script]:-}" ]]; then
      warn " 同名单容器按 RESTORE_EXISTING=skip 保持不变：$cname_from_script"
      continue
    fi
    echo " - $r"
    if ! RESTORE_TRANSACTION_DIR="$RESTORE_TRANSACTION_DIR" bash "$r" 2>&1; then
      warn " 容器恢复脚本失败：$r"
      FAILED_CONTAINERS+=("$cname_from_script")
      print_failure_summary
      exit 1
    fi
  done < <(restore_runs_in_dependency_order)
fi

if restore_has_failures; then
  print_failure_summary
  exit 1
fi

transaction_commit
