compose_networks_from_meta_all() {
  [[ -d meta ]] || return 0
  local f proj
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$f" 2>/dev/null || true)"
    [[ -n "$proj" ]] || continue
    # 只有 manifest.projects 中实际按 Compose 恢复的项目才跳过 [E]；单容器
    # Compose 会按独立容器恢复，其自定义网络仍必须在 [E] 精确创建。
    jq -e --arg project "$proj" 'any(.projects[]?; .name == $project)' \
      "${BUNDLE_DIR}/manifest.json" >/dev/null 2>&1 || continue
    jq -r '.[0].NetworkSettings.Networks | keys[]?' "$f" 2>/dev/null || true
  done | awk '!/^(bridge|host|none)$/' | sort -u
}

compose_networks_from_meta_for_project() {
  local project="$1"
  [[ -d meta ]] || return 0
  local f proj
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$f" 2>/dev/null || true)"
    [[ "$proj" == "$project" ]] || continue
    jq -r '.[0].NetworkSettings.Networks | keys[]?' "$f" 2>/dev/null || true
  done | awk '!/^(bridge|host|none)$/' | sort -u
}

compose_cleanup_conflicting_network() {
  local project="$1" network_name="$2"
  [[ -n "$network_name" ]] || return 0
  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    return 0
  fi
  local proj_label net_label
  proj_label="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$network_name" 2>/dev/null || true)"
  net_label="$(docker network inspect -f '{{ index .Labels "com.docker.compose.network" }}' "$network_name" 2>/dev/null || true)"
  # 仅当网络属于当前项目（有 project label 且匹配）时才允许删除
  # 空 proj_label 表示非 compose 网络（手动创建或外部共享），跳过删除
  if [[ -n "$proj_label" && -n "$net_label" && "$proj_label" == "$project" ]]; then
    if dm_quiet docker network rm "$network_name"; then
      log_line "已清理旧网络：$network_name"
    else
      warn " · 无法清理网络：$network_name（可能仍被占用）"
    fi
  fi
}

compose_network_records() {
  local project="$1"
  shift
  local tmp_cfg=""
  if command -v mktemp >/dev/null 2>&1; then
    tmp_cfg="$(mktemp)"
  else
    tmp_cfg="/tmp/docker_migrate_compose_config_$$.json"
    : >"$tmp_cfg"
  fi

  if compose_run "$@" config --format json >"$tmp_cfg" 2>/dev/null; then
    jq -r '
      .name as $project |
      ((.networks // {"default": {}}) | to_entries[]) |
      [(.value.name // "\($project)_\(.key)"), ((.value.external // false) | tostring)] | @tsv
    ' "$tmp_cfg"
    rm -f "$tmp_cfg" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp_cfg" 2>/dev/null || true

  while IFS= read -r net; do
    [[ -n "$net" ]] || continue
    if [[ "$net" == "${project}_"* ]]; then
      printf '%s\tfalse\n' "$net"
    else
      printf '%s\tunknown\n' "$net"
    fi
  done < <(compose_networks_from_meta_for_project "$project")
}

compose_prepare_networks() {
  local project="$1"
  shift
  local seen=0 net external network_row
  while IFS=$'\t' read -r net external; do
    [[ -n "$net" ]] || continue
    seen=1
    case "$external" in
      true)
        network_row="$(jq -c --arg name "$net" '.networks[]? | select(.name == $name)' \
          "${BUNDLE_DIR}/manifest.json" | head -n1)"
        if [[ -n "$network_row" ]]; then
          if ! docker network inspect "$net" >/dev/null 2>&1; then
            warn " · 检测到外部网络缺失，按迁移记录创建：$net"
          fi
          create_network_from_record "$network_row" || {
            warn " · 外部网络无法按迁移记录准备：$net"
            return 1
          }
        elif ! docker network inspect "$net" >/dev/null 2>&1; then
          warn " · 外部网络缺失且迁移包没有其配置，拒绝创建默认错误网络：$net"
          return 1
        else
          warn " · 迁移包里没有网络 ${net} 的设置，沿用新服务器上已有的这个网络"
        fi
        ;;
      false)
        compose_cleanup_conflicting_network "$project" "$net"
        ;;
      *)
        if [[ "$net" == "${project}_"* ]]; then
          compose_cleanup_conflicting_network "$project" "$net"
        fi
        ;;
    esac
  done < <(compose_network_records "$project" "$@")

  if ((seen == 0)); then
    while IFS= read -r net; do
      [[ -n "$net" ]] || continue
      if [[ "$net" == "${project}_"* ]]; then
        compose_cleanup_conflicting_network "$project" "$net"
      fi
    done < <(compose_networks_from_meta_for_project "$project")
  fi
}

create_network_from_record() {
  local row="$1"
  local name driver desired_core actual_core desired_labels actual_labels cfg subnet ip_range gateway
  local ipam_driver pair
  local -a create_args option_pairs label_pairs ipam_option_pairs aux_pairs
  name="$(jq -r '.name' <<<"$row")"
  driver="$(jq -r '.driver // "bridge"' <<<"$row")"
  [[ -n "$name" && "$name" != "null" ]] || return 1
  # 迁移前预检中选择了沿用新服务器上已有的同名网络。
  if decision_listed reuse_network "$name" && docker network inspect "$name" >/dev/null 2>&1; then
    log_line "按预检时的选择沿用已有网络：$name"
    return 0
  fi

  desired_core="$(jq -cS '{
    driver: (.driver // "bridge"),
    internal: (.internal // false),
    attachable: (.attachable // false),
    enable_ipv6: (.enable_ipv6 // false),
    options: (.options // {}),
    ipam: {
      driver: (.ipam.driver // "default"),
      options: (.ipam.options // {}),
      config: (.ipam.config // [])
    }
  }' <<<"$row")"

  if docker network inspect "$name" >/dev/null 2>&1; then
    actual_core="$(docker network inspect "$name" | jq -cS '.[0] | {
      driver: (.Driver // "bridge"),
      internal: (.Internal // false),
      attachable: (.Attachable // false),
      enable_ipv6: (.EnableIPv6 // false),
      options: (.Options // {}),
      ipam: {
        driver: (.IPAM.Driver // "default"),
        options: (.IPAM.Options // {}),
        config: (.IPAM.Config // [])
      }
    }')"
    if [[ "$actual_core" != "$desired_core" ]]; then
      warn " 已存在同名但配置不同的网络：$name；为避免断开其他容器，不自动删除。"
      return 1
    fi
    desired_labels="$(jq -cS '.labels // {}' <<<"$row")"
    actual_labels="$(docker network inspect "$name" | jq -cS '.[0].Labels // {}')"
    if [[ "$actual_labels" != "$desired_labels" ]]; then
      warn " 网络 ${name} 已存在，只是标签和旧服务器不同，直接沿用，不做修改"
    fi
    return 0
  fi

  create_args=(docker network create --driver "$driver")
  [[ "$(jq -r '.internal // false' <<<"$row")" != "true" ]] || create_args+=(--internal)
  [[ "$(jq -r '.attachable // false' <<<"$row")" != "true" ]] || create_args+=(--attachable)
  [[ "$(jq -r '.enable_ipv6 // false' <<<"$row")" != "true" ]] || create_args+=(--ipv6)
  ipam_driver="$(jq -r '.ipam.driver // "default"' <<<"$row")"
  [[ "$ipam_driver" == "default" ]] || create_args+=(--ipam-driver "$ipam_driver")

  mapfile -t option_pairs < <(jq -r '.options // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row")
  for pair in "${option_pairs[@]}"; do create_args+=(--opt "$pair"); done
  mapfile -t label_pairs < <(jq -r '.labels // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row")
  for pair in "${label_pairs[@]}"; do create_args+=(--label "$pair"); done
  mapfile -t ipam_option_pairs < <(jq -r '.ipam.options // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row")
  for pair in "${ipam_option_pairs[@]}"; do create_args+=(--ipam-opt "$pair"); done

  while IFS= read -r cfg; do
    [[ -n "$cfg" ]] || continue
    # 迁移前预检中选择了让 Docker 自动选择网段。
    decision_listed auto_subnet "$name" && break
    subnet="$(jq -r '.Subnet // empty' <<<"$cfg")"
    ip_range="$(jq -r '.IPRange // empty' <<<"$cfg")"
    gateway="$(jq -r '.Gateway // empty' <<<"$cfg")"
    [[ -z "$subnet" ]] || create_args+=(--subnet "$subnet")
    [[ -z "$ip_range" ]] || create_args+=(--ip-range "$ip_range")
    [[ -z "$gateway" ]] || create_args+=(--gateway "$gateway")
    mapfile -t aux_pairs < <(jq -r '.AuxiliaryAddresses // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$cfg")
    for pair in "${aux_pairs[@]}"; do create_args+=(--aux-address "$pair"); done
  done < <(jq -c '.ipam.config[]?' <<<"$row")
  create_args+=("$name")

  dm_quiet "${create_args[@]}"
}
