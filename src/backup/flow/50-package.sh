#####################################
# 生成独立容器 run 脚本
#####################################
stage_begin 5 7 "保存镜像"
if ((${#IDS[@]})); then
  detail "生成单容器恢复脚本"
  for id in "${IDS[@]}"; do
    if [[ "${CONTAINER_IS_COMPOSE[$id]}" == "1" ]]; then
      continue
    fi
    n="${CONTAINER_NAME[$id]}"
    run_file="${BUNDLE}/runs/${n}.sh"
    write_run_script "$n" "$run_file"
    RUNS+=("runs/$(basename "$run_file")")
  done
fi

#####################################
# 保存镜像 images.tar
#####################################
mapfile -t IMAGES < <(printf "%s\n" "${!IMGSET[@]}" | awk 'NF' | sort -u)
if ((${#IMAGES[@]})); then
  OUT_IMG="${BUNDLE}/images.tar"
  IMAGES_TOTAL_BYTES="$(images_total_bytes "${IMAGES[@]}")"
  if progress_docker_save "${OUT_IMG}" "$IMAGES_TOTAL_BYTES" \
    docker image save "${IMAGES[@]}"; then
    detail "images.tar 已生成：$(human "$(progress_file_size "$OUT_IMG")")"
    if ! cleanup_snapshot_images; then
      detail "部分临时快照镜像暂未删除，退出清理时会自动重试"
    fi
  else
    rm -f "${OUT_IMG}" 2>/dev/null || true
    fail_with_output "保存镜像失败" "$(log_tail_text)" "执行 df -h 检查磁盘空间，并确认 Docker 运行正常"
    exit 1
  fi
else
  warn_user "没有找到需要保存的镜像，新服务器将尝试在线拉取"
fi
stage_end "${#IMAGES[@]} 个镜像 · $(human "$(progress_file_size "${OUT_IMG:-/dev/null}")")"

#####################################
# 生成 manifest.json 与 restore.sh
#####################################
generate_manifest_and_restore() {
  declare -a MAN_PROJECTS=()
  local key
  for key in "${!COMPOSE_GROUP[@]}"; do
    local proj="${key%%|*}"
    local wdir="${key#*|}"
    local files_json="[]"
    local cfgs_json="[]"
    if [[ -d "${BUNDLE}/compose/${proj}" ]]; then
      mapfile -t FLS < <(find "${BUNDLE}/compose/${proj}" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | sort || true)
      if ((${#FLS[@]})); then
        files_json="$(json_array_from_lines "${FLS[@]}")"
      fi
    fi
    # 解析后的单文件配置优先；否则保持原始 config_files 顺序。
    local cfs="${COMPOSE_CFGS[$key]:-}"
    if [[ -f "${BUNDLE}/compose/${proj}/_resolved_config.yml" ]]; then
      if [[ -f "${BUNDLE}/compose/${proj}/_migration_images.yml" ]]; then
        cfgs_json='["_resolved_config.yml","_migration_images.yml"]'
      else
        cfgs_json='["_resolved_config.yml"]'
      fi
    elif [[ -n "$cfs" ]]; then
      mapfile -t CFS_ARR < <(compose_config_files_split "$cfs")
      declare -a cfgs_abs
      cfgs_abs=()
      for c in "${CFS_ARR[@]}"; do
        c="${c#./}"
        [[ -z "$c" ]] && continue
        if [[ "$c" == /* ]]; then cfgs_abs+=("$c"); elif [[ -n "$wdir" ]]; then cfgs_abs+=("${wdir}/${c}"); else cfgs_abs+=("$c"); fi
      done
      if ((${#cfgs_abs[@]})); then
        if [[ -f "${BUNDLE}/compose/${proj}/_migration_images.yml" ]]; then
          cfgs_abs+=("_migration_images.yml")
        fi
        cfgs_json="$(json_array_from_lines "${cfgs_abs[@]}")"
      fi
    fi
    MAN_PROJECTS+=("$(jq -cn --arg name "$proj" --arg working_dir "$wdir" --argjson files "$files_json" --argjson config_files "$cfgs_json" '{name:$name,working_dir:$working_dir,files:$files,config_files:$config_files}')")
  done

  local images_json nets_json projects_json vols_json binds_json runs_json
  # 使用正确的 bash 数组展开语法，避免空数组产生空字符串参数
  images_json="$(json_array_from_lines ${IMAGES[@]+"${IMAGES[@]}"})"
  runs_json="$(json_array_from_lines ${RUNS[@]+"${RUNS[@]}"})"
  mapfile -t NETWORK_FILES < <(find "${BUNDLE}/networks" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort || true)
  if ((${#NETWORK_FILES[@]})); then
    nets_json="$(jq -s . "${NETWORK_FILES[@]}")"
  else
    nets_json='[]'
  fi

  if ((${#MAN_PROJECTS[@]})); then
    projects_json="$(printf '%s\n' "${MAN_PROJECTS[@]}" | jq -cs .)"
  else
    projects_json='[]'
  fi
  if ((${#MAN_VOL[@]})); then
    vols_json="$(printf '%s\n' "${MAN_VOL[@]}" | jq -cs .)"
  else
    vols_json='[]'
  fi
  if ((${#MAN_BIND[@]})); then
    binds_json="$(printf '%s\n' "${MAN_BIND[@]}" | jq -cs .)"
  else
    binds_json='[]'
  fi

  jq -n \
    --arg created_at "$STAMP" \
    --arg script_version "$SCRIPT_VERSION" \
    --argjson images "$images_json" \
    --argjson networks "$nets_json" \
    --argjson projects "$projects_json" \
    --argjson volumes "$vols_json" \
    --argjson binds "$binds_json" \
    --argjson runs "$runs_json" \
    '{created_at:$created_at,script_version:$script_version,images:$images,networks:$networks,projects:$projects,volumes:$volumes,binds:$binds,runs:$runs}' \
    >"${BUNDLE}/manifest.json"

  write_bundle_restore_script "${BUNDLE}/restore.sh"

  cat >"${BUNDLE}/README.txt" <<README
Docker 迁移包
生成时间：${STAMP}

恢复方法：
1. 新服务器运行同一份 docker_migrate_perfect.sh，选择 2，然后粘贴下载链接；或
2. 手动解压本包后，在包目录执行：bash restore.sh
README
}

stage_begin 6 7 "加密打包"
generate_manifest_and_restore
# 迁移计划：新服务器下载前据此预检（端口、磁盘、CPU 类型等）。
if ! plan_build "$BUNDLE" "${IMAGES_TOTAL_BYTES:-0}" >"${BUNDLE}/plan.json"; then
  rm -f "${BUNDLE}/plan.json"
  warn_user "迁移计划生成失败，新服务器将跳过迁移前预检"
fi
run_with_activity "计算文件校验值" generate_bundle_checksums "$BUNDLE"

#####################################
# 流式压缩并加密成单文件
#####################################
BUNDLE_BASENAME="docker_migrate_${STAMP}_${RID}"
SINGLE_TAR_PATH="${BUNDLE_ROOT}/${BUNDLE_BASENAME}.tar.gz"
BUNDLE_SECRET="$(openssl rand -hex 64)" || {
  error_user "无法生成迁移包加密密钥" "确认 openssl 可以正常运行"
  exit 1
}
BUNDLE_IV="$(openssl rand -hex 16)" || {
  error_user "无法生成迁移包加密 IV" "确认 openssl 可以正常运行"
  exit 1
}
valid_hex_length "$BUNDLE_SECRET" 128 && valid_hex_length "$BUNDLE_IV" 32 || {
  error_user "OpenSSL 返回了无效的随机密钥" "确认 openssl 可以正常运行"
  exit 1
}
BUNDLE_ENCRYPTION_KEY="$(bundle_secret_encryption_key "$BUNDLE_SECRET")"
BUNDLE_MAC_KEY="$(bundle_secret_mac_key "$BUNDLE_SECRET")"
ENCRYPTED_TAR_PATH="${SINGLE_TAR_PATH}.enc"
ENCRYPTED_PARTIAL_PATH="${ENCRYPTED_TAR_PATH}.partial.$$"
# 加密包最大约等于明文目录大小（镜像层通常已压缩）。
bundle_plain_bytes="$(du -sk "$BUNDLE" 2>/dev/null | awk '{ printf "%.0f\n", $1 * 1024 }')"
if ! ensure_free_space "$BUNDLE_ROOT" "${bundle_plain_bytes:-0}" "生成加密迁移包"; then
  exit 1
fi
PACK_COUNT_FILE="${ENCRYPTED_PARTIAL_PATH}.count"
if ! BUNDLE_DIGESTS="$(DM_PROGRESS_HINT="正在压缩，数据量大时需要几分钟" \
  run_with_progress "压缩并加密" "count:${PACK_COUNT_FILE}" "${bundle_plain_bytes:-0}" \
  bundle_pack_encrypt_directory \
  "$BUNDLE_ROOT" "$RID" "$ENCRYPTED_PARTIAL_PATH" \
  "$BUNDLE_ENCRYPTION_KEY" "$BUNDLE_MAC_KEY" "$BUNDLE_IV" "$PACK_COUNT_FILE")"; then
  rm -f "$PACK_COUNT_FILE"
  fail_with_output "压缩或加密迁移包失败" "$(log_tail_text)" "执行 df -h 检查磁盘空间后重试"
  exit 1
fi
rm -f "$PACK_COUNT_FILE"
IFS=$'\t' read -r BUNDLE_SHA256 BUNDLE_HMAC BUNDLE_DIGEST_EXTRA <<<"$BUNDLE_DIGESTS"
if [[ -n "$BUNDLE_DIGEST_EXTRA" ]] || ! valid_sha256 "$BUNDLE_SHA256" ||
  ! valid_sha256 "$BUNDLE_HMAC"; then
  error_user "无法生成加密迁移包的摘要"
  exit 1
fi
if ! mv "$ENCRYPTED_PARTIAL_PATH" "$ENCRYPTED_TAR_PATH"; then
  error_user "无法保存加密迁移包" "执行 df -h 检查磁盘空间后重试"
  exit 1
fi
# 迁移计划单独加密，与迁移包放在同一随机路径下，新服务器从同一个链接推算地址。
PLAN_NAME="${BUNDLE_BASENAME}.plan"
PLAN_PATH="${BUNDLE_ROOT}/${PLAN_NAME}"
if [[ -f "${BUNDLE}/plan.json" ]] && ! plan_encrypt "${BUNDLE}/plan.json" "$PLAN_PATH" \
  "$BUNDLE_ENCRYPTION_KEY" "$BUNDLE_MAC_KEY" "$BUNDLE_IV"; then
  rm -f "$PLAN_PATH"
  warn_user "迁移计划加密失败，新服务器将跳过迁移前预检"
fi
[[ -f "$PLAN_PATH" ]] || PLAN_PATH=""
# 明文目录已全部进入加密包：立即删除，释放磁盘并减少明文数据停留时间。
rm -rf "$BUNDLE" 2>/dev/null || detail "明文迁移目录暂未删除，退出时会再次清理：$BUNDLE"
TRANSFER_NAME="${BUNDLE_BASENAME}.tar.gz.enc"
TRANSFER_PATH="$ENCRYPTED_TAR_PATH"
TRANSFER_FRAGMENT="#sha256=${BUNDLE_SHA256}&enc=${BUNDLE_ENCRYPTION_SCHEME}&secret=${BUNDLE_SECRET}&iv=${BUNDLE_IV}&mac=${BUNDLE_HMAC}"
BUNDLE_ENCRYPTION_KEY=""
BUNDLE_MAC_KEY=""
BUNDLE_SECRET=""
SOURCE_PACKAGE_READY=1
stage_end "$(human "$(progress_file_size "$TRANSFER_PATH")")"
