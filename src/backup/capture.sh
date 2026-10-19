# 源端数据采集：共享挂载检测、卷与目录归档、停机与可写层快照。

compose_env_file_refs() {
  # Best-effort fallback parser for common Compose env_file scalar/list/long syntax.
  # 正常情况下恢复使用 `docker compose config` 生成的已解析配置。
  awk '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      return v
    }
    /^[[:space:]]*env_file[[:space:]]*:/ {
      in_env = 1
      value = $0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      value = trim(value)
      if (value != "") {
        print value
        in_env = 0
      }
      next
    }
    in_env && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      if (value ~ /^path[[:space:]]*:/) {
        sub(/^path[[:space:]]*:[[:space:]]*/, "", value)
      }
      value = trim(value)
      if (value != "" && value !~ /^(required|format)[[:space:]]*:/) print value
      next
    }
    in_env && /^[[:space:]]*path[[:space:]]*:/ {
      value = $0
      sub(/^[[:space:]]*path[[:space:]]*:[[:space:]]*/, "", value)
      value = trim(value)
      if (value != "") print value
      next
    }
    in_env && /^[^[:space:]#]/ { in_env = 0 }
  ' "$1"
}

collect_shared_running_containers() {
  local selected_id selected_full_id id name inspect mount type source selected_path reason
  declare -A selected_ids=() selected_volumes=()
  local -a selected_binds=()

  for selected_id in "$@"; do
    selected_ids["$selected_id"]=1
    if declare -p SELECTED_INSPECT_JSON >/dev/null 2>&1 &&
      [[ -n "${SELECTED_INSPECT_JSON[$selected_id]+cached}" ]]; then
      inspect="${SELECTED_INSPECT_JSON[$selected_id]}"
    else
      inspect="$(docker inspect "$selected_id")" || return 1
    fi
    selected_full_id="$(jq -r '.[0].Id' <<<"$inspect")"
    selected_ids["$selected_full_id"]=1
    selected_ids["${selected_full_id:0:12}"]=1
    while IFS= read -r source; do
      [[ -n "$source" ]] && selected_volumes["$source"]=1
    done < <(jq -r '.[0].Mounts[]? | select(.Type == "volume") | .Name' <<<"$inspect")
    while IFS= read -r source; do
      # 系统路径不迁移数据，共享它们的容器（如都挂载 /etc/localtime）无需停机。
      if [[ -n "$source" ]] && ! bind_path_is_system "$source"; then
        selected_binds+=("$(bind_resolve_source "$source")")
      fi
    done < <(jq -r '.[0].Mounts[]? | select(.Type == "bind") | .Source' <<<"$inspect")
  done

  while IFS=$'\t' read -r id name; do
    [[ -n "$id" && -z "${selected_ids[$id]:-}" ]] || continue
    case ",${DOCKER_MIGRATE_IGNORE_CONTAINERS:-}," in
      *,"$name",*) continue ;;
    esac
    inspect="$(docker inspect "$id")" || return 1
    reason=""
    while IFS= read -r mount; do
      type="$(jq -r '.Type' <<<"$mount")"
      case "$type" in
        volume)
          source="$(jq -r '.Name' <<<"$mount")"
          if [[ -n "${selected_volumes[$source]:-}" ]]; then
            reason="volume:${source}"
            break
          fi
          ;;
        bind)
          source="$(jq -r '.Source' <<<"$mount")"
          bind_path_is_system "$source" && continue
          source="$(bind_resolve_source "$source")"
          for selected_path in "${selected_binds[@]}"; do
            if mount_paths_overlap "$source" "$selected_path"; then
              reason="bind:${source}"
              break 2
            fi
          done
          ;;
      esac
    done < <(jq -c '.[0].Mounts[]?' <<<"$inspect")
    [[ -z "$reason" ]] || printf '%s\t%s\t%s\n' "$id" "$name" "$reason"
  done < <(docker ps --format '{{.ID}}\t{{.Names}}')
}

# 估算数据卷大小（字节），用于显示进度百分比；无法读取挂载点时输出 0。
volume_size_bytes() {
  local mountpoint
  mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$1" 2>/dev/null || true)"
  [[ -n "$mountpoint" && -d "$mountpoint" ]] || {
    echo 0
    return 0
  }
  path_size_bytes "$mountpoint"
}

path_size_bytes() {
  du -sk "$1" 2>/dev/null | awk '{ printf "%.0f\n", $1 * 1024 } END { if (NR == 0) print 0 }'
}

# count_file 非空时统计打包的原始字节数，供进度显示使用。
archive_volume_to_gzip() {
  local volume="$1" output="$2" count_file="${3:-/dev/null}" rc=0
  rm -f -- "$output"
  if docker run --rm -v "${volume}:/from:ro" alpine:3.20 \
    tar -C /from -cf - . 2>>"${DM_LOG_FILE:-/dev/null}" |
    progress_meter "$count_file" | gzip_compress_stream >"$output"; then
    return 0
  else
    rc=$?
  fi
  rm -f -- "$output"
  return "$rc"
}

archive_bind_to_gzip() {
  local source="$1" output="$2" count_file="${3:-/dev/null}" rc=0
  rm -f -- "$output"
  if tar -C / -cf - "${source#/}" 2>>"${DM_LOG_FILE:-/dev/null}" |
    progress_meter "$count_file" | gzip_compress_stream >"$output"; then
    return 0
  else
    rc=$?
  fi
  rm -f -- "$output"
  return "$rc"
}

docker_stop_batch_verified() {
  local label="$1"
  shift
  local name running stop_rc=0 verify_rc=0
  (($# > 0)) || return 0

  DM_PROGRESS_HINT="容器正在处理退出信号，最长等待约 10 秒后会被强制停止" \
    run_with_activity "$label" dm_quiet docker stop "$@" || stop_rc=$?
  # Docker CLI 的聚合退出码无法指出具体失败项；以 daemon 的最终状态为准，
  # 同时逐个确认，避免部分停止后误以为已经取得一致性快照。
  for name in "$@"; do
    if ! running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)"; then
      log_line "停机后无法确认容器状态：$name"
      verify_rc=1
    elif [[ "$running" != "false" ]]; then
      log_line "容器仍在运行：$name"
      verify_rc=1
    fi
  done
  ((verify_rc == 0)) || return 1
  if ((stop_rc != 0)); then
    log_line "docker stop 返回异常，但已逐个确认所有目标容器停止"
  fi
  return 0
}

# 保存镜像到 images.tar，按镜像层总大小显示进度。
progress_docker_save() {
  local outfile="$1" total="$2"
  shift 2
  DM_PROGRESS_HINT="镜像较大时需要几分钟，请耐心等待" \
    run_with_progress "保存镜像" "$outfile" "$total" \
    progress_capture_stdout "$outfile" dm_logged "$@"
}

# 镜像大小之和，作为 docker save 输出大小的估算值。
images_total_bytes() {
  (($# > 0)) || {
    echo 0
    return 0
  }
  docker image inspect -f '{{.Size}}' "$@" 2>/dev/null | awk '{ s += $1 } END { printf "%.0f\n", s }'
}

snapshot_image_ref() {
  local rid="$1" container_id="$2"
  printf 'docker-migrate-snapshot:%s-%s\n' "${rid,,}" "${container_id:0:12}"
}

snapshot_container_image() {
  local container_id="$1" metadata_file="$2" snapshot_image="$3"
  local original_image running tmp
  local -a commit_args=(docker commit)

  original_image="$(jq -r '.[0].Config.Image' "$metadata_file")"
  # 这里必须读取临近 commit 的实时状态；--no-stop 模式下容器可能在元数据采集后启动。
  running="$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || echo false)"
  # 用户选择不停机时不偷偷暂停业务；这种模式本身已明确提示快照可能不一致。
  [[ "$running" != "true" ]] || commit_args+=(--pause=false)
  if ! dm_quiet "${commit_args[@]}" "$container_id" "$snapshot_image"; then
    return 1
  fi
  TEMP_IMAGES+=("$snapshot_image")

  tmp="${metadata_file}.snapshot.tmp"
  if ! jq --arg original "$original_image" --arg snapshot "$snapshot_image" '
      .[0].Config.Image = $snapshot |
      .[0].DockerMigrate = ((.[0].DockerMigrate // {}) + {
        original_image: $original,
        snapshot_image: $snapshot,
        writable_layer_captured: true
      })
    ' "$metadata_file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$metadata_file"
}

# docker diff 中是否有值得迁移的可写层改动。只列出因子项变化而被标记为
# C 的父目录、以及运行时临时目录，都不算改动。无法判断时保守地返回“有改动”。
container_writable_layer_changed() {
  local container_id="$1" diff_output
  diff_output="$(docker diff "$container_id" 2>/dev/null)" || return 0
  awk '
    NF >= 2 {
      kind[NR] = $1
      path = substr($0, index($0, " ") + 1)
      paths[NR] = path
      parent = path
      while (sub(/\/[^\/]*$/, "", parent) && parent != "") parents[parent] = 1
    }
    END {
      for (i in paths) {
        p = paths[i]
        if (kind[i] == "C" && (p in parents)) continue
        if (p ~ /^\/(tmp|var\/tmp|run|var\/run|var\/cache|root\/\.cache|dev|proc|sys)(\/|$)/) continue
        found = 1
        exit
      }
      exit found ? 0 : 1
    }
  ' <<<"$diff_output"
}

# 输出需要为容器创建可写层快照的原因；无需快照时输出为空。默认只在可写层
# 确有改动、或原镜像标签已指向别的版本时快照，其余容器保留原镜像名，便于
# 之后用 docker pull / compose pull / watchtower 正常升级。
# DOCKER_MIGRATE_SNAPSHOT=always 恢复旧行为；never 放弃可写层改动。
container_snapshot_reason() {
  local container_id="$1" metadata_file="$2" mode="${DOCKER_MIGRATE_SNAPSHOT:-auto}"
  local original_image container_image_id tag_id
  original_image="$(jq -r '.[0].Config.Image' "$metadata_file")"
  container_image_id="$(jq -r '.[0].Image // empty' "$metadata_file")"
  tag_id="$(docker image inspect -f '{{.Id}}' "$original_image" 2>/dev/null || true)"
  if [[ -z "$tag_id" || "$tag_id" != "$container_image_id" ]]; then
    printf '原镜像标签已不存在或指向其他版本\n'
    return 0
  fi
  case "$mode" in
    always)
      printf 'DOCKER_MIGRATE_SNAPSHOT=always\n'
      return 0
      ;;
    never) return 0 ;;
  esac
  if container_writable_layer_changed "$container_id"; then
    printf '可写层有改动\n'
  fi
}

write_compose_snapshot_override() {
  local file="$1" service="$2" image="$3" tmp
  if [[ ! -f "$file" ]]; then
    printf '{"services":{}}\n' >"$file"
  fi
  tmp="${file}.tmp"
  jq --arg service "$service" --arg image "$image" \
    '.services[$service].image = $image' "$file" >"$tmp"
  mv "$tmp" "$file"
}

cleanup_snapshot_images() {
  local image rc=0
  local -a remaining=()
  for image in "${TEMP_IMAGES[@]}"; do
    if dm_quiet docker image rm "$image"; then
      continue
    fi
    # rm 失败后，只有在 Docker daemon 可用且明确查不到镜像时才视为已清理；
    # daemon/权限异常必须保留记录，供退出清理重试并反映在最终结果中。
    if docker info >/dev/null 2>&1 &&
      ! docker image inspect "$image" >/dev/null 2>&1; then
      continue
    fi
    remaining+=("$image")
    rc=1
  done
  TEMP_IMAGES=("${remaining[@]}")
  return "$rc"
}
