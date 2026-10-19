#####################################
# 预拉取卷操作镜像，避免把下载时间计入后面的停机快照窗口
#####################################
if docker image inspect alpine:3.20 >/dev/null 2>&1; then
  detail "卷操作镜像 alpine:3.20 已存在"
else
  DM_PROGRESS_HINT="正在从 Docker Hub 下载，网络较慢时可能需要几分钟" \
    run_with_activity "拉取卷操作镜像 alpine:3.20" dm_quiet docker pull alpine:3.20 ||
    warn_user "无法拉取 alpine:3.20，打包数据卷时可能失败"
fi

#####################################
# 检查未选中容器是否仍在写共享挂载
#####################################
declare -a SHARED_MOUNT_ROWS=()
mapfile -t SHARED_MOUNT_ROWS < <(
  run_with_activity "检查与其他容器共享的数据" \
    collect_shared_running_containers "${IDS[@]}"
)
if ((${#SHARED_MOUNT_ROWS[@]} > 0)); then
  stage_hold
  for shared_row in "${SHARED_MOUNT_ROWS[@]}"; do
    IFS=$'\t' read -r _ shared_name shared_reason <<<"$shared_row"
    warn_user "未选中的容器 ${shared_name} 正在使用相同的数据（${shared_reason}）"
  done

  if ((NO_STOP == 1)); then
    error_user "--no-stop 无法保证共享数据的一致性，已取消备份" \
      "停止这些容器，或去掉 --no-stop 让脚本临时停止并自动恢复它们"
    exit 1
  fi

  stop_shared=0
  if [[ -t 0 ]]; then
    read -rp "是否临时停止这些容器？备份完成后会自动恢复。[Y/n] " STOP_SHARED
    STOP_SHARED=${STOP_SHARED:-Y}
    [[ "$STOP_SHARED" =~ ^[Yy]$ ]] && stop_shared=1
  elif [[ "${STOP_SHARED_MOUNTS:-0}" == "1" ]]; then
    stop_shared=1
  fi
  if ((stop_shared == 0)); then
    error_user "未允许停止共享数据的容器，为避免备份出不一致的数据已取消" \
      "非交互模式可设置 STOP_SHARED_MOUNTS=1 允许临时停止它们"
    exit 1
  fi

  declare -a SHARED_STOP_NAMES=()
  for shared_row in "${SHARED_MOUNT_ROWS[@]}"; do
    IFS=$'\t' read -r _ shared_name _ <<<"$shared_row"
    shared_state="$(docker inspect -f '{{.State.Status}}' "$shared_name" 2>/dev/null || echo running)"
    detail "临时停止共享数据的容器：${shared_name}"
    # Write-ahead：在 unpause/stop 前登记原状态；信号可在任意指令后安全恢复。
    STOPPED_ON_BACKUP+=("${shared_name}"$'\t'"${shared_state}")
    [[ "$shared_state" != "paused" ]] || dm_quiet docker unpause "$shared_name" || true
    SHARED_STOP_NAMES+=("$shared_name")
  done
  if ! docker_stop_batch_verified \
    "停止共享数据的容器（${#SHARED_STOP_NAMES[@]} 个）" "${SHARED_STOP_NAMES[@]}"; then
    error_user "共享数据的容器没有全部停止，已取消备份" "执行 docker ps 检查这些容器的状态"
    exit 1
  fi
fi
stage_end "${#IDS[@]} 个容器"

#####################################
# 停机窗口（可选）
#####################################
stage_begin 4 7 "停机并打包数据"
DOWNTIME_STARTED=$SECONDS
if ((NO_STOP == 1)); then
  warn_user "使用 --no-stop 不停机备份，数据库等有状态服务的数据可能不一致"
else
  # 非交互运行（定时任务、nohup、管道）时 stdin 可能已关闭；read 读到 EOF
  # 不能触发 set -e 中止，按默认的一致性停机备份继续。
  STOPNOW=""
  if [[ -t 0 ]]; then
    stage_hold
    read -rp "是否临时停止所选容器以保证数据一致？完成打包后会立即恢复。[Y/n] " STOPNOW || true
  fi
  STOPNOW=${STOPNOW:-Y}
  if [[ "$STOPNOW" =~ ^[Yy]$ ]]; then
    total_count=${#IDS[@]}
    idx=0
    declare -a SOURCE_STOP_NAMES=()
    for id in "${IDS[@]}"; do
      idx=$((idx + 1))
      n="${CONTAINER_NAME[$id]}"
      source_state_row="$(docker inspect -f '{{.State.Running}} {{.State.Status}}' \
        "$id" 2>/dev/null || echo 'false missing')"
      read -r was_running source_state <<<"$source_state_row"
      if [[ "$was_running" != "true" ]]; then
        detail "停机 ${idx}/${total_count}：${n} 原本就已停止"
        continue
      fi
      detail "停机 ${idx}/${total_count}：${n}"
      # Write-ahead：先登记再改变源容器状态，避免 TERM 落在 stop 与数组追加之间。
      STOPPED_ON_BACKUP+=("${n}"$'\t'"${source_state}")
      [[ "$source_state" != "paused" ]] || dm_quiet docker unpause "$n" || true
      SOURCE_STOP_NAMES+=("$n")
    done
    DOWNTIME_STARTED=$SECONDS
    if ! docker_stop_batch_verified \
      "停止所选容器（${#SOURCE_STOP_NAMES[@]} 个）" "${SOURCE_STOP_NAMES[@]}"; then
      error_user "所选容器没有全部停止，为避免备份出不一致的数据已取消" "执行 docker ps 检查容器状态"
      exit 1
    fi
  else
    warn_user "选择了不停机备份，数据库等有状态服务的数据可能不一致"
  fi
fi

#####################################
# 捕获容器 writable layer
#####################################
detail "检查容器可写层"
for service_key in "${!COMPOSE_SERVICE_COUNT[@]}"; do
  if ((${COMPOSE_SERVICE_COUNT[$service_key]} > 1)); then
    BACKUP_FAILURES+=("Compose 服务存在多个副本，无法逐容器保留可写层：${service_key##*|}")
  fi
done
if ((${#BACKUP_FAILURES[@]} > 0)); then
  error_user "${BACKUP_FAILURES[0]}" "请只迁移单副本的 Compose 服务，或先把副本数缩减为 1"
  exit 1
fi

# 后续只需保存临时快照镜像；其父镜像层会由 docker image save 自动包含。
IMGSET=()
snapshot_total=${#IDS[@]}
snapshot_index=0
for id in "${IDS[@]}"; do
  snapshot_index=$((snapshot_index + 1))
  n="${CONTAINER_NAME[$id]}"
  snapshot_image="$(snapshot_image_ref "$RID" "$id")"
  snapshot_reason="$(container_snapshot_reason "$id" "${BUNDLE}/meta/${n}.inspect.json")"
  if [[ -z "$snapshot_reason" ]]; then
    original_image="$(jq -r '.[0].Config.Image' "${BUNDLE}/meta/${n}.inspect.json")"
    detail "可写层 ${snapshot_index}/${snapshot_total}：${n} 没有改动，沿用原镜像 ${original_image}"
    IMGSET["$original_image"]=1
    continue
  fi
  detail "可写层 ${snapshot_index}/${snapshot_total}：${n} 创建快照（${snapshot_reason}）"
  if ! run_with_activity "快照 ${n}" \
    snapshot_container_image "$id" "${BUNDLE}/meta/${n}.inspect.json" "$snapshot_image"; then
    BACKUP_FAILURES+=("容器可写层快照失败：$n")
    continue
  fi
  IMGSET["$snapshot_image"]=1

  if [[ "${CONTAINER_IS_COMPOSE[$id]}" == "1" ]]; then
    j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")"
    compose_service="$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // empty' <<<"$j")"
    if ! write_compose_snapshot_override \
      "${BUNDLE}/compose/${proj}/_migration_images.yml" "$compose_service" "$snapshot_image"; then
      BACKUP_FAILURES+=("Compose 快照覆盖配置生成失败：$n")
      continue
    fi
  fi
done
if ((${#BACKUP_FAILURES[@]} > 0)); then
  fail_with_output "${BACKUP_FAILURES[0]}" "$(log_tail_text)"
  exit 1
fi

#####################################
# 备份卷与绑定目录
#####################################
detail "打包数据卷与挂载目录"
declare -a MAN_VOL=()
declare -a MAN_BIND=()
declare -A BACKED_VOLUMES=()
declare -A BACKED_BINDS=()
vol_count=0
bind_count=0
for id in "${IDS[@]}"; do
  n="${CONTAINER_NAME[$id]}"
  j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
  vc=$(jq -r '.[0].Mounts[]? | select(.Type=="volume") | 1' <<<"$j" | wc -l || echo 0)
  bc=$(jq -r '.[0].Mounts[]? | select(.Type=="bind") | 1' <<<"$j" | wc -l || echo 0)
  vol_count=$((vol_count + vc))
  bind_count=$((bind_count + bc))
done

v_idx=0
b_idx=0
for id in "${IDS[@]}"; do
  n="${CONTAINER_NAME[$id]}"
  j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    t=$(jq -r '.Type' <<<"$m")
    dest=$(jq -r '.Destination' <<<"$m")
    case "$t" in
      volume)
        v_idx=$((v_idx + 1))
        vname=$(jq -r '.Name' <<<"$m")
        [[ -z "${BACKED_VOLUMES[$vname]:-}" ]] || continue
        BACKED_VOLUMES["$vname"]=1
        # 捕获卷的 driver 和 options，用于恢复时精确还原
        if v_inspect="$(docker volume inspect "$vname" 2>/dev/null)"; then
          v_driver="$(jq -r '.[0].Driver // "local"' <<<"$v_inspect")"
          v_opts_json="$(jq -c '.[0].Options // {}' <<<"$v_inspect")"
        else
          v_driver="local"
          v_opts_json='{}'
        fi
        detail "数据卷 ${v_idx}/${vol_count}：${n} 的 ${vname} -> ${dest}"
        mkdir -p "${BUNDLE}/volumes"
        out="${BUNDLE}/volumes/vol_${vname}.tgz"
        if ! run_with_progress "卷 ${vname}" "count:${out}.count" "$(volume_size_bytes "$vname")" \
          archive_volume_to_gzip "$vname" "$out" "${out}.count"; then
          rm -f "${out}.count"
          BACKUP_FAILURES+=("数据卷 ${vname} 打包失败")
          continue
        fi
        item_bytes="$(progress_current "count:${out}.count")"
        PACKED_BYTES=$((${PACKED_BYTES:-0} + item_bytes))
        rm -f "${out}.count"
        MAN_VOL+=("$(jq -cn --arg name "$vname" --arg dest "$dest" --arg driver "$v_driver" \
          --argjson opts "$v_opts_json" --argjson bytes "$item_bytes" \
          '{name:$name,dest:$dest,driver:$driver,opts:$opts,bytes:$bytes}')")
        ;;
      bind)
        src=$(jq -r '.Source' <<<"$m")
        # 过滤 Docker socket 等 Unix socket 文件，防止恢复时覆盖目标服务器 daemon
        case "$src" in
          */docker.sock | */podman.sock | */containerd.sock)
            detail "跳过 Docker socket 挂载：$src（新服务器会挂载自己的 Docker）"
            continue
            ;;
        esac
        b_idx=$((b_idx + 1))
        if bind_path_is_system "$src"; then
          detail "宿主机系统路径只在新服务器重建挂载、不迁移内容：$src"
          continue
        fi
        # 软链接 bind 必须备份链接指向的真实数据；只打包链接本身会丢数据，
        # 恢复端也会拒绝以链接作为绑定根。恢复时在原路径重建同一个链接。
        bind_link=""
        real_src="$(bind_resolve_source "$src")"
        if [[ "$real_src" != "$src" ]]; then
          if bind_path_is_system "$real_src"; then
            detail "软链接指向宿主机系统路径，只在新服务器重建挂载：$src -> $real_src"
            continue
          fi
          bind_link="$src"
          src="$real_src"
          detail "挂载路径是软链接，备份它指向的真实目录：${bind_link} -> ${src}"
        fi
        [[ -z "${BACKED_BINDS[$src]:-}" ]] || continue
        BACKED_BINDS["$src"]=1
        esc="$(basename "$src" | tr -c 'A-Za-z0-9_.-' '_')"
        src_id="$(printf '%s' "$src" | cksum | awk '{print $1}')"
        out="${BUNDLE}/binds/bind_${esc}_${src_id}.tgz"
        detail "挂载目录 ${b_idx}/${bind_count}：${n} 的 ${src} -> ${dest}"
        mkdir -p "${BUNDLE}/binds"
        if ! run_with_progress "目录 ${src}" "count:${out}.count" "$(path_size_bytes "$src")" \
          archive_bind_to_gzip "$src" "$out" "${out}.count"; then
          rm -f "${out}.count"
          BACKUP_FAILURES+=("挂载目录 ${src} 打包失败")
          continue
        fi
        item_bytes="$(progress_current "count:${out}.count")"
        PACKED_BYTES=$((${PACKED_BYTES:-0} + item_bytes))
        rm -f "${out}.count"
        MAN_BIND+=("$(jq -cn --arg host "$src" --arg link "$bind_link" --arg dest "$dest" \
          --arg file "$(basename "$out")" --argjson bytes "$item_bytes" \
          '{host:$host,dest:$dest,file:$file,bytes:$bytes} + (if $link == "" then {} else {link:$link} end)')")
        ;;
      *)
        detail "跳过不需要迁移的挂载类型：$t（$dest）"
        ;;
    esac
  done < <(jq -c '.[0].Mounts[]?' <<<"$j")
done

if ((${#BACKUP_FAILURES[@]} > 0)); then
  fail_with_output "${BACKUP_FAILURES[0]}" "$(log_tail_text)"
  exit 1
fi

# 容器可写层、volume 与 bind 数据现在都已经真正归档为同一停机快照；后续
# 镜像保存、压缩、加密和下载不再需要业务保持停止，立即恢复源端状态。
SOURCE_RESTORE_EXPECTED=${#STOPPED_ON_BACKUP[@]}
if ((SOURCE_RESTORE_EXPECTED > 0)); then
  detail "数据快照已完成，立即恢复源服务器容器状态"
  if ! run_with_activity "恢复源容器运行" restart_source_containers; then
    exit 1
  fi
fi
packed_summary="${#MAN_VOL[@]} 个卷 · ${#MAN_BIND[@]} 个目录 · $(human "${PACKED_BYTES:-0}")"
if ((SOURCE_RESTORE_EXPECTED > 0)); then
  packed_summary+=" · 停机 $(format_elapsed "$((SECONDS - DOWNTIME_STARTED))")"
fi
stage_end "$packed_summary"
