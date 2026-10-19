volume_clear_and_extract() {
  local volume="$1" archive_dir="$2" archive_file="$3" prechecked="${4:-0}"
  # 来自恢复入口的归档已经在停机前预检；本地回滚包仍须先验证再清空卷。
  [[ "$prechecked" == "1" ]] || archive_members_safe "${archive_dir}/${archive_file}" || return 1
  printf '清空并解压命名卷：%s（归档：%s）\n' "$volume" "$archive_file" >&2
  if ! archive_normalized_stream "${archive_dir}/${archive_file}" |
    docker run --rm -i --read-only --network none \
    --security-opt no-new-privileges --cap-drop MKNOD \
    -v "${volume}:/to" \
    alpine:3.20 sh -eu -c '
      find /to -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
      tar -xf - -C /to
    ' sh "$archive_file"; then
    return 1
  fi
  return 0
}

restore_volume_exact() {
  local volume="$1" archive_dir="$2" archive_file="$3" rollback_dir="$4" existed="$5"
  local prechecked="${6:-0}"
  local rollback_file="rollback_${volume}.tgz"
  [[ "$prechecked" == "1" ]] || archive_members_safe "${archive_dir}/${archive_file}" || return 1
  mkdir -p "$rollback_dir"
  if ((existed == 1)); then
    printf '备份目标端原卷数据：%s\n' "$volume" >&2
    if ! docker run --rm \
      -v "${volume}:/from:ro" \
      -v "${rollback_dir}:/rollback" \
      alpine:3.20 sh -eu -c 'tar -czf "/rollback/$1" -C /from .' sh "$rollback_file"; then
      return 1
    fi
  fi

  # Write-ahead：清空卷之前先持久化回滚记录。即使此后收到 TERM，EXIT trap
  # 也能知道该卷必须恢复；日志写入失败时目标数据仍未改动。
  if [[ -n "${RESTORE_TRANSACTION_DIR:-}" ]]; then
    printf '%s\t%s\t%s\n' "$volume" "$existed" "${rollback_dir}/${rollback_file}" \
      >>"${RESTORE_TRANSACTION_DIR}/volumes.tsv" || return 1
  fi

  if volume_clear_and_extract "$volume" "$archive_dir" "$archive_file" 1; then
    if [[ -z "${RESTORE_TRANSACTION_DIR:-}" ]]; then
      rm -f "${rollback_dir}/${rollback_file}"
    fi
    return 0
  fi

  warn " 卷恢复失败，正在回滚目标端原数据：$volume"
  if [[ -n "${RESTORE_TRANSACTION_DIR:-}" ]]; then
    # 全局事务持有回滚包；不要提前删除，让统一回滚按确定顺序处理。
    return 1
  fi
  if ((existed == 1)); then
    volume_clear_and_extract "$volume" "$rollback_dir" "$rollback_file" 0 || return 1
    rm -f "${rollback_dir}/${rollback_file}"
  else
    docker volume rm "$volume" >/dev/null 2>&1 || true
  fi
  return 1
}

restore_data_with_diagnostics() {
  # RESTORE_ACTIVE_DATA_LOG 必须是全局变量：bash 4.0/4.1 在函数内 exit 时会先
  # 撤销 local 再执行 EXIT trap，trap 将读不到日志路径。
  local label="$1" logfile rc
  shift
  # 日志置于迁移包旁，不混入包内校验清单，也不随事务回滚点一起删除。
  # mktemp + umask 077 防止覆盖已有路径或泄露数据库文件信息。
  logfile="$(mktemp "${BUNDLE_DIR}/../docker-migrate-data.XXXXXX")" || {
    warn "无法创建恢复诊断日志，尚未执行：$label"
    return 1
  }
  RESTORE_ACTIVE_DATA_LOG="$logfile"
  if "$@" >"$logfile" 2>&1; then
    RESTORE_ACTIVE_DATA_LOG=""
    rm -f "$logfile" || true
    return 0
  else
    rc=$?
  fi
  RESTORE_ACTIVE_DATA_LOG=""
  printf '\n[错误详情] %s（退出码：%s）\n' "$label" "$rc" >&2
  tail -n 20 "$logfile" >&2
  printf '详细日志：%s\n' "$logfile" >&2
  return "$rc"
} 202>&1 203>&2

restore_diagnostic_output() {
  # 数据操作中收到信号时，EXIT trap 仍处于日志重定向内。切回调用前的
  # 输出，确保手动恢复模式下也能看见回滚进度和最终结果。
  if [[ -n "${RESTORE_ACTIVE_DATA_LOG:-}" ]]; then
    exec 1>&202 2>&203
    printf '详细日志：%s\n' "$RESTORE_ACTIVE_DATA_LOG" >&2
  fi
}

root_exec() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n "$@"
  else
    "$@"
  fi
}

restore_bind_exact() {
  local host="$1" archive="$2" prechecked="${3:-0}"
  local parent base stage old staged had_old=0
  [[ "$host" == /* && "$host" != "/" ]] || return 1
  [[ "$prechecked" == "1" ]] || archive_members_safe "$archive" "${host#/}" || return 1
  parent="$(dirname "$host")"
  base="$(basename "$host")"
  stage="${parent}/.${base}.docker-migrate-stage-$$"
  old="${parent}/.${base}.docker-migrate-old-$$"

  root_exec mkdir -p "$parent" || return 1
  root_exec rm -rf "$stage" "$old" || return 1
  root_exec mkdir -p "$stage" || return 1
  # 结构预检保证成员不穿过链接写入；仅目标 staging 可写，容器根只读。
  printf '解压绑定目录：%s（归档：%s）\n' "$host" "$archive" >&2
  if ! archive_normalized_stream "$archive" |
    docker run --rm -i --read-only --network none \
    --security-opt no-new-privileges --cap-drop MKNOD \
    -v "${stage}:/stage" \
    alpine:3.20 tar -C /stage -xf -; then
    root_exec rm -rf "$stage" || true
    return 1
  fi
  staged="${stage}/${host#/}"
  if ! root_exec test -e "$staged" && ! root_exec test -L "$staged"; then
    warn "归档中缺少绑定目录：$host"
    root_exec rm -rf "$stage" || true
    return 1
  fi
  # bind 根本身若是链接，移动出 staging 后其相对语义会改变；拒绝这种歧义结构。
  if root_exec test -L "$staged"; then
    warn "拒绝使用符号链接作为绑定目录根：$host"
    root_exec rm -rf "$stage" || true
    return 1
  fi
  if root_exec test -e "$host" || root_exec test -L "$host"; then
    had_old=1
  fi
  # Write-ahead：rename 旧路径之前先记下旧路径位置。回滚会以 old 是否存在
  # 判断 rename 是否已经发生，因此“已记日志但尚未改动”也是安全状态。
  if [[ -n "${RESTORE_TRANSACTION_DIR:-}" ]]; then
    printf '%s\t%s\t%s\n' "$host" "$had_old" "$old" \
      >>"${RESTORE_TRANSACTION_DIR}/binds.tsv" || {
      root_exec rm -rf "$stage" || true
      return 1
    }
  fi
  if ((had_old == 1)); then
    root_exec mv "$host" "$old" || {
      root_exec rm -rf "$stage" || true
      return 1
    }
  fi
  if ! root_exec mv "$staged" "$host"; then
    if ((had_old == 1)); then root_exec mv "$old" "$host" || true; fi
    root_exec rm -rf "$stage" || true
    return 1
  fi
  root_exec rm -rf "$stage" || true
  if [[ -z "${RESTORE_TRANSACTION_DIR:-}" && $had_old -eq 1 ]]; then
    root_exec rm -rf "$old" || true
  fi
}

# 与主脚本 bind_path_is_system 保持一致：旧版迁移包可能仍记录了系统路径，
# 恢复时一律跳过，绝不覆盖目标端宿主机文件。
RESTORE_SYSTEM_BIND_PREFIXES=(
  /proc /sys /dev /run /var/run /boot /lib/modules /usr/lib/modules
  /var/lib/docker /var/lib/containerd /var/log /etc/docker /etc/systemd
  /lib/systemd /usr/lib/systemd /etc/localtime /etc/timezone /usr/share/zoneinfo
  /etc/hostname /etc/hosts /etc/resolv.conf /etc/machine-id /etc/os-release
  /usr/lib/os-release /etc/passwd /etc/group /etc/shadow /etc/gshadow
  /etc/ssl /etc/pki /etc/ca-certificates
)
RESTORE_SYSTEM_BIND_EXACT=(
  / /etc /usr /usr/lib /usr/bin /usr/local /var /var/lib /lib /lib64 /bin /sbin
  /opt /home /root /srv /mnt /media /tmp
)

restore_bind_is_system() {
  local path="$1" prefix
  [[ "$path" == "/" ]] || path="${path%/}"
  for prefix in "${RESTORE_SYSTEM_BIND_EXACT[@]}"; do
    [[ "$path" != "$prefix" ]] || return 0
  done
  for prefix in "${RESTORE_SYSTEM_BIND_PREFIXES[@]}"; do
    [[ "$path" != "$prefix" && "$path" != "${prefix}/"* ]] || return 0
  done
  return 1
}

# 源端 bind 是软链接时，数据已恢复到真实路径；在原路径重建同一个链接，
# 让容器按原挂载路径看到数据。新建的链接登记进 binds.tsv，回滚时删除。
restore_bind_link() {
  local link="$1" host="$2" current
  [[ -n "$link" ]] || return 0
  if root_exec test -L "$link"; then
    current="$(root_exec readlink "$link" 2>/dev/null || true)"
    [[ "$current" != "$host" ]] || return 0
    current="$(root_exec readlink -f "$link" 2>/dev/null || true)"
    [[ -z "$current" || "$current" != "$(root_exec readlink -f "$host" 2>/dev/null || true)" ]] ||
      return 0
    warn " 目标端已有同名软链接但指向不同：$link -> ${current:-未知}（期望 $host）"
    return 1
  fi
  if root_exec test -e "$link"; then
    warn " 目标端 $link 已存在且不是软链接，无法指向迁移的数据目录：$host"
    return 1
  fi
  if [[ -n "${RESTORE_TRANSACTION_DIR:-}" ]]; then
    printf '%s\t0\t\n' "$link" >>"${RESTORE_TRANSACTION_DIR}/binds.tsv" || return 1
  fi
  root_exec mkdir -p "$(dirname "$link")" || return 1
  root_exec ln -s "$host" "$link"
}

