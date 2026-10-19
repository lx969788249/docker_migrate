#####################################
# 预拉取卷操作镜像，避免把下载时间计入后面的停机快照窗口
#####################################
BLUE "[INFO] 预拉取 alpine:3.20 镜像（用于卷操作）..."
if docker image inspect alpine:3.20 >/dev/null 2>&1; then
  OK "[OK] 已存在 alpine:3.20，跳过联网检查"
else
  run_with_activity "拉取卷操作镜像 alpine:3.20" docker pull alpine:3.20 ||
    YEL "[WARN] 无法拉取 alpine:3.20，卷操作可能失败"
fi

#####################################
# 检查未选中容器是否仍在写共享挂载
#####################################
declare -a SHARED_MOUNT_ROWS=()
mapfile -t SHARED_MOUNT_ROWS < <(
  run_with_activity "检查未选中容器的共享挂载写入" \
    collect_shared_running_containers "${IDS[@]}"
)
if ((${#SHARED_MOUNT_ROWS[@]} > 0)); then
  YEL "[WARN] 检测到未选中的运行容器正在使用相同 volume 或重叠 bind 路径："
  for shared_row in "${SHARED_MOUNT_ROWS[@]}"; do
    IFS=$'\t' read -r _ shared_name shared_reason <<<"$shared_row"
    YEL " - ${shared_name} (${shared_reason})"
  done

  if ((NO_STOP == 1)); then
    RED "[ERR] --no-stop 无法保证共享挂载一致性，已取消备份。"
    RED "[INFO] 请停止这些容器，或去掉 --no-stop 让脚本临时暂停并自动恢复。"
    exit 1
  fi

  stop_shared=0
  if [[ -t 0 ]]; then
    read -rp "是否临时停止这些共享挂载容器？备份结束会自动重启。[Y/n] " STOP_SHARED
    STOP_SHARED=${STOP_SHARED:-Y}
    [[ "$STOP_SHARED" =~ ^[Yy]$ ]] && stop_shared=1
  elif [[ "${STOP_SHARED_MOUNTS:-0}" == "1" ]]; then
    stop_shared=1
  fi
  if ((stop_shared == 0)); then
    RED "[ERR] 未获得停止共享挂载容器的许可，已取消备份以避免不一致数据。"
    RED "[INFO] 非交互模式可显式设置 STOP_SHARED_MOUNTS=1。"
    exit 1
  fi

  declare -a SHARED_STOP_NAMES=()
  for shared_row in "${SHARED_MOUNT_ROWS[@]}"; do
    IFS=$'\t' read -r _ shared_name _ <<<"$shared_row"
    shared_state="$(docker inspect -f '{{.State.Status}}' "$shared_name" 2>/dev/null || echo running)"
    printf "[停机-共享挂载] %s\n" "$shared_name"
    # Write-ahead：在 unpause/stop 前登记原状态；信号可在任意指令后安全恢复。
    STOPPED_ON_BACKUP+=("${shared_name}"$'\t'"${shared_state}")
    [[ "$shared_state" != "paused" ]] || docker unpause "$shared_name" >/dev/null 2>&1 || true
    SHARED_STOP_NAMES+=("$shared_name")
  done
  if ! docker_stop_batch_verified \
    "批量停止共享挂载容器（${#SHARED_STOP_NAMES[@]} 个）" "${SHARED_STOP_NAMES[@]}"; then
    BACKUP_FAILURES+=("共享挂载容器未能全部停止")
  fi
  if ((${#BACKUP_FAILURES[@]} > 0)); then
    RED "[ERR] 共享挂载容器未全部停止，已取消备份。"
    exit 1
  fi
fi

#####################################
# 停机窗口（可选）
#####################################
if ((NO_STOP == 1)); then
  YEL "[WARN] 使用 --no-stop：不停机备份，数据可能不一致（尤其数据库类容器）。"
else
  # 非交互运行（定时任务、nohup、管道）时 stdin 可能已关闭；read 读到 EOF
  # 不能触发 set -e 中止，按默认的一致性停机备份继续。
  STOPNOW=""
  read -rp "是否现在停机以确保一致性备份？[Y/n] " STOPNOW || true
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
        printf "[停机] (%d/%d) %s ... already stopped\n" "$idx" "$total_count" "$n"
        continue
      fi
      printf "[停机] (%d/%d) %s\n" "$idx" "$total_count" "$n"
      # Write-ahead：先登记再改变源容器状态，避免 TERM 落在 stop 与数组追加之间。
      STOPPED_ON_BACKUP+=("${n}"$'\t'"${source_state}")
      [[ "$source_state" != "paused" ]] || docker unpause "$n" >/dev/null 2>&1 || true
      SOURCE_STOP_NAMES+=("$n")
    done
    if ! docker_stop_batch_verified \
      "批量停止源容器（${#SOURCE_STOP_NAMES[@]} 个）" "${SOURCE_STOP_NAMES[@]}"; then
      BACKUP_FAILURES+=("源容器未能全部停止")
    fi
    if ((${#BACKUP_FAILURES[@]} > 0)); then
      RED "[ERR] 停机阶段失败，已取消备份以避免不一致数据。"
      exit 1
    fi
  else
    YEL "[WARN] 你选择了不停机备份。"
  fi
fi

#####################################
# 捕获容器 writable layer
#####################################
BLUE "[INFO] 捕获容器可写层快照 ..."
for service_key in "${!COMPOSE_SERVICE_COUNT[@]}"; do
  if ((${COMPOSE_SERVICE_COUNT[$service_key]} > 1)); then
    BACKUP_FAILURES+=("Compose 服务存在多个副本，无法逐容器保留可写层：${service_key##*|}")
  fi
done
if ((${#BACKUP_FAILURES[@]} > 0)); then
  RED "[ERR] 可写层快照预检查失败："
  for failure in "${BACKUP_FAILURES[@]}"; do RED " - $failure"; done
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
    printf " [IMAGE] (%d/%d) %s：可写层无改动，沿用原镜像 %s\n" \
      "$snapshot_index" "$snapshot_total" "$n" "$original_image"
    IMGSET["$original_image"]=1
    continue
  fi
  printf " [SNAPSHOT] (%d/%d) %s（%s）\n" "$snapshot_index" "$snapshot_total" "$n" "$snapshot_reason"
  if ! run_with_activity "创建容器可写层快照：$n" \
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
      YEL " [WARN] Compose 快照覆盖配置生成失败：$n"
      BACKUP_FAILURES+=("Compose 快照覆盖配置生成失败：$n")
      continue
    fi
  fi
done
if ((${#BACKUP_FAILURES[@]} > 0)); then
  RED "[ERR] 可写层快照不完整，已取消备份。"
  exit 1
fi

#####################################
# 备份卷与绑定目录
#####################################
BLUE "[INFO] 备份卷与绑定目录 ..."
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
        printf " [VOL] (%d/%d) %s :: %s -> %s\n" "$v_idx" "$vol_count" "$n" "$vname" "$dest"
        mkdir -p "${BUNDLE}/volumes"
        out="${BUNDLE}/volumes/vol_${vname}.tgz"
        if ! run_with_file_progress "打包命名卷：$vname" "$out" 0 \
          archive_volume_to_gzip "$vname" "$out"; then
          YEL " [WARN] 打包卷失败：$vname"
          BACKUP_FAILURES+=("命名卷备份失败：$vname")
          continue
        fi
        MAN_VOL+=("$(jq -cn --arg name "$vname" --arg dest "$dest" --arg driver "$v_driver" --argjson opts "$v_opts_json" '{name:$name,dest:$dest,driver:$driver,opts:$opts}')")
        ;;
      bind)
        src=$(jq -r '.Source' <<<"$m")
        # 过滤 Docker socket 等 Unix socket 文件，防止恢复时覆盖目标服务器 daemon
        case "$src" in
          */docker.sock | */podman.sock | */containerd.sock)
            YEL " [SKIP] 跳过 Docker socket bind mount：$src"
            continue
            ;;
        esac
        b_idx=$((b_idx + 1))
        if bind_path_is_system "$src"; then
          YEL " [SKIP] 宿主机系统路径只在新服务器重建挂载、不迁移内容：$src"
          continue
        fi
        # 软链接 bind 必须备份链接指向的真实数据；只打包链接本身会丢数据，
        # 恢复端也会拒绝以链接作为绑定根。恢复时在原路径重建同一个链接。
        bind_link=""
        real_src="$(bind_resolve_source "$src")"
        if [[ "$real_src" != "$src" ]]; then
          if bind_path_is_system "$real_src"; then
            YEL " [SKIP] 软链接指向宿主机系统路径，只重建挂载：$src -> $real_src"
            continue
          fi
          bind_link="$src"
          src="$real_src"
          YEL " [INFO] bind 源是软链接，备份真实目录：${bind_link} -> ${src}"
        fi
        [[ -z "${BACKED_BINDS[$src]:-}" ]] || continue
        BACKED_BINDS["$src"]=1
        esc="$(basename "$src" | tr -c 'A-Za-z0-9_.-' '_')"
        src_id="$(printf '%s' "$src" | cksum | awk '{print $1}')"
        out="${BUNDLE}/binds/bind_${esc}_${src_id}.tgz"
        printf " [BIND] (%d/%d) %s :: %s -> %s\n" "$b_idx" "$bind_count" "$n" "$src" "$dest"
        mkdir -p "${BUNDLE}/binds"
        if ! run_with_file_progress "打包绑定目录：$src" "$out" 0 \
          archive_bind_to_gzip "$src" "$out"; then
          YEL " [WARN] 跳过不可读路径：$src"
          BACKUP_FAILURES+=("绑定目录备份失败：$src")
          continue
        fi
        MAN_BIND+=("$(jq -cn --arg host "$src" --arg link "$bind_link" --arg dest "$dest" \
          --arg file "$(basename "$out")" \
          '{host:$host,dest:$dest,file:$file} + (if $link == "" then {} else {link:$link} end)')")
        ;;
      *)
        YEL " [SKIP] 未处理的 mount 类型：$t (dest=$dest)"
        ;;
    esac
  done < <(jq -c '.[0].Mounts[]?' <<<"$j")
done

if ((${#BACKUP_FAILURES[@]} > 0)); then
  RED "[ERR] 数据备份不完整，已取消生成迁移包："
  for failure in "${BACKUP_FAILURES[@]}"; do
    RED " - $failure"
  done
  exit 1
fi

# 容器可写层、volume 与 bind 数据现在都已经真正归档为同一停机快照；后续
# 镜像保存、压缩、加密和下载不再需要业务保持停止，立即恢复源端状态。
SOURCE_RESTORE_EXPECTED=${#STOPPED_ON_BACKUP[@]}
if ((SOURCE_RESTORE_EXPECTED > 0)); then
  BLUE "[INFO] 数据快照已完成，立即恢复源服务器容器状态 ..."
  if ! restart_source_containers; then
    RED "[ERR] 源容器未能全部恢复，已停止后续打包，请立即人工检查。"
    exit 1
  fi
fi
