#####################################
# 元数据采集
#####################################
stage_begin 3 7 "读取配置"
declare -A IMGSET=()
declare -A NETWORKS=()
declare -A CONTAINER_NAME=()
declare -A CONTAINER_IS_COMPOSE=()
declare -A COMPOSE_GROUP=()
declare -A COMPOSE_CFGS=()
declare -A SELECTED_COMPOSE_COUNT=()
declare -A COMPOSE_SERVICE_COUNT=()
declare -A SELECTED_INSPECT_JSON=()

# 关键修复：重新按最终选择的容器统计 compose 分组数量，避免菜单阶段归类为单容器，元数据阶段又被重新归为 compose。
metadata_total=${#IDS[@]}
metadata_index=0
for id in "${IDS[@]}"; do
  metadata_index=$((metadata_index + 1))
  progress_count "分析容器" "$metadata_index" "$metadata_total" "$id"
  jtmp="$(docker inspect "$id")"
  SELECTED_INSPECT_JSON["$id"]="$jtmp"
  projtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$jtmp")
  wdirtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$jtmp")
  # 兼容 v1：缺少 working_dir 时从 config_files 推断
  if [[ -z "$wdirtmp" && -n "$projtmp" ]]; then
    cfgstmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$jtmp")
    if [[ -n "$cfgstmp" ]]; then
      IFS=':' read -r -a cfgs_tmp <<<"$cfgstmp"
      for ct in "${cfgs_tmp[@]}"; do
        ct="${ct#./}"
        if [[ -n "$ct" ]]; then
          if [[ "$ct" == /* ]]; then wdirtmp="$(dirname "$ct")"; else wdirtmp="${PWD}/$(dirname "$ct")"; fi
          break
        fi
      done
    fi
  fi
  if [[ -n "$projtmp" && -n "$wdirtmp" ]]; then
    keytmp="${projtmp}|${wdirtmp}"
    SELECTED_COMPOSE_COUNT["$keytmp"]=$((${SELECTED_COMPOSE_COUNT["$keytmp"]:-0} + 1))
  fi
done

metadata_index=0
for id in "${IDS[@]}"; do
  metadata_index=$((metadata_index + 1))
  j="${SELECTED_INSPECT_JSON[$id]}"
  name=$(jq -r '.[0].Name | ltrimstr("/")' <<<"$j")
  progress_count "读取容器配置" "$metadata_index" "$metadata_total" "$name"
  img=$(jq -r '.[0].Config.Image' <<<"$j")
  CONTAINER_NAME["$id"]="$name"
  IMGSET["$img"]=1

  proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
  wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")
  cfgs=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$j")
  # 兼容 v1：缺少 working_dir 时从 config_files 推断
  if [[ -z "$wdir" && -n "$proj" ]]; then
    if [[ -n "$cfgs" ]]; then
      IFS=':' read -r -a cfgs_arr <<<"$cfgs"
      for cg in "${cfgs_arr[@]}"; do
        cg="${cg#./}"
        if [[ -n "$cg" ]]; then
          if [[ "$cg" == /* ]]; then wdir="$(dirname "$cg")"; else wdir="${PWD}/$(dirname "$cg")"; fi
          break
        fi
      done
    fi
  fi
  key=""
  if [[ -n "$proj" && -n "$wdir" ]]; then
    key="${proj}|${wdir}"
  fi

  if [[ -n "$key" && "${SELECTED_COMPOSE_COUNT[$key]:-0}" -gt 1 ]]; then
    COMPOSE_GROUP["$key"]=1
    [[ -n "$cfgs" ]] && COMPOSE_CFGS["$key"]="$cfgs"
    CONTAINER_IS_COMPOSE["$id"]=1
    compose_service="$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // empty' <<<"$j")"
    if [[ -n "$compose_service" ]]; then
      service_key="${key}|${compose_service}"
      COMPOSE_SERVICE_COUNT["$service_key"]=$((${COMPOSE_SERVICE_COUNT["$service_key"]:-0} + 1))
    else
      BACKUP_FAILURES+=("Compose 容器缺少 service 标签：$name")
    fi
  else
    CONTAINER_IS_COMPOSE["$id"]=0
  fi

  # 所有选中容器的非内置网络都要保存。多服务 Compose 的 external 网络
  # 也依赖这里的完整 driver/IPAM/options，不能只采集独立容器网络。
  mapfile -t nets < <(jq -r '.[0].NetworkSettings.Networks | keys[]?' <<<"$j" || true)
  for n in "${nets[@]}"; do
    case "$n" in bridge | host | none) : ;; *) NETWORKS["$n"]=1 ;; esac
  done

  echo "$j" >"${BUNDLE}/meta/${name}.inspect.json"
done

# 保存选中容器使用的自定义网络定义，而不只保存网络名称。
for network_name in "${!NETWORKS[@]}"; do
  network_id="$(printf '%s' "$network_name" | cksum | awk '{print $1}')"
  if ! docker network inspect "$network_name" | jq '.[0] | {
      name: .Name,
      driver: (.Driver // "bridge"),
      internal: (.Internal // false),
      attachable: (.Attachable // false),
      enable_ipv6: (.EnableIPv6 // false),
      options: (.Options // {}),
      labels: (.Labels // {}),
      ipam: {
        driver: (.IPAM.Driver // "default"),
        options: (.IPAM.Options // {}),
        config: (.IPAM.Config // [])
      }
    }' >"${BUNDLE}/networks/${network_id}.json"; then
    BACKUP_FAILURES+=("网络元数据采集失败：$network_name")
  fi
done

#####################################
# 打包 Compose 配置（绝对/相对路径）
#####################################
if ((${#COMPOSE_GROUP[@]})); then
  detail "打包 Docker Compose 项目配置"
  compose_total=${#COMPOSE_GROUP[@]}
  compose_index=0
  for key in "${!COMPOSE_GROUP[@]}"; do
    compose_index=$((compose_index + 1))
    proj="${key%%|*}"
    wdir="${key#*|}"
    progress_count "采集 Compose 配置" "$compose_index" "$compose_total" "$proj"
    dest="${BUNDLE}/compose/${proj}"
    mkdir -p "$dest"
    cfgs="${COMPOSE_CFGS[$key]:-}"
    declare -a CFG_SOURCE_ARGS=()

    if [[ -n "$cfgs" ]]; then
      IFS=':' read -r -a CFG_ARR <<<"$cfgs"
      for cfg in "${CFG_ARR[@]}"; do
        cfg="${cfg#./}"
        [[ -z "$cfg" ]] && continue
        src=""
        if [[ "$cfg" == /* ]]; then
          src="$cfg"
        elif [[ -n "$wdir" ]]; then
          src="${wdir}/${cfg}"
        else
          src="$cfg"
        fi
        if [[ -f "$src" ]]; then
          cp -a "$src" "$dest/"
          CFG_SOURCE_ARGS+=(-f "$src")
        else
          BACKUP_FAILURES+=("Compose 配置文件缺失：$src")
        fi
      done
    fi

    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env docker-compose.override.yml compose.override.yaml; do
      if [[ -n "$wdir" && -f "${wdir}/${f}" ]]; then
        cp -a "${wdir}/${f}" "$dest/" 2>/dev/null || true
      fi
    done

    # 使用全部 -f 文件生成规范配置，合并覆盖文件并解析 env_file。
    if ((${#CFG_SOURCE_ARGS[@]} > 0)); then
      resolved_tmp="${dest}/.resolved_config.yml.tmp"
      detail "解析 Compose 配置：$proj"
      compose_log="${DM_LOG_FILE:-/dev/null}"
      if docker compose version >/dev/null 2>&1 &&
        { docker compose --project-directory "$wdir" "${CFG_SOURCE_ARGS[@]}" config --no-path-resolution >"$resolved_tmp" 2>>"$compose_log" ||
          docker compose --project-directory "$wdir" "${CFG_SOURCE_ARGS[@]}" config >"$resolved_tmp" 2>>"$compose_log"; }; then
        mv "$resolved_tmp" "${dest}/_resolved_config.yml"
      elif command -v docker-compose >/dev/null 2>&1 &&
        (cd "$wdir" && docker-compose "${CFG_SOURCE_ARGS[@]}" config) >"$resolved_tmp" 2>>"$compose_log"; then
        mv "$resolved_tmp" "${dest}/_resolved_config.yml"
      else
        rm -f "$resolved_tmp"
        warn_user "Compose 项目 ${proj} 无法生成解析后的配置，将使用原始配置文件"
      fi
    fi

    # 原始配置回退：收集常见 env_file 语法并保留相对目录结构。
    for cfg in "$dest"/*.yml "$dest"/*.yaml; do
      [[ -f "$cfg" ]] || continue
      while IFS= read -r ef; do
        ef="${ef#./}"
        [[ -z "$ef" ]] && continue
        if [[ "$ef" == /* ]]; then
          if [[ -f "$ef" ]]; then
            env_id="$(printf '%s' "$ef" | cksum | awk '{print $1}')"
            stored="_env_files/${env_id}_$(basename "$ef")"
            mkdir -p "${dest}/$(dirname "$stored")"
            cp -a "$ef" "${dest}/${stored}"
            jq -cn --arg source "$ef" --arg stored "$stored" \
              '{source:$source,stored:$stored}' >>"${dest}/.env_file_map.jsonl"
          fi
        elif [[ -n "$wdir" && -f "${wdir}/${ef}" ]]; then
          mkdir -p "${dest}/$(dirname "$ef")"
          cp -a "${wdir}/${ef}" "${dest}/${ef}"
        fi
      done < <(compose_env_file_refs "$cfg" || true)
    done
  done
fi
