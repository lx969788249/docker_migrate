transaction_path_is_safe() {
  local path="$1"
  [[ "$path" == /* && "$path" != "/" ]] || return 1
  case "$path" in *'/../'* | */..) return 1 ;; esac
}

transaction_acquire_lock() {
  local rollback_base="$1" owner_host owner_pid
  RESTORE_LOCK_FILE="${rollback_base}/migration.lock"
  RESTORE_LOCK_DIR="${RESTORE_LOCK_FILE}.d"
  if command -v flock >/dev/null 2>&1; then
    RESTORE_LOCK_METHOD="flock"
    exec 201>"$RESTORE_LOCK_FILE" || return 1
    if ! flock -n 201 2>/dev/null; then
      exec 201>&-
      RESTORE_LOCK_METHOD=""
      warn "另一个恢复任务正在运行，请等它结束后再试。"
      return 1
    fi
    return 0
  fi

  RESTORE_LOCK_METHOD="mkdir"
  if ! mkdir "$RESTORE_LOCK_DIR" 2>/dev/null; then
    if [[ -f "${RESTORE_LOCK_DIR}/owner" ]]; then
      IFS=$'\t' read -r owner_host owner_pid <"${RESTORE_LOCK_DIR}/owner" || true
      if [[ "$owner_host" == "$(hostname)" && "$owner_pid" =~ ^[0-9]+$ ]] &&
        ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -f "${RESTORE_LOCK_DIR}/owner" 2>/dev/null || true
        rmdir "$RESTORE_LOCK_DIR" 2>/dev/null || true
      fi
    fi
    if ! mkdir "$RESTORE_LOCK_DIR" 2>/dev/null; then
      RESTORE_LOCK_METHOD=""
      warn "另一个恢复任务正在运行，请等它结束后再试。"
      return 1
    fi
  fi
  if ! printf '%s\t%s\n' "$(hostname)" "$$" >"${RESTORE_LOCK_DIR}/owner"; then
    rm -f "${RESTORE_LOCK_DIR}/owner" 2>/dev/null || true
    rmdir "$RESTORE_LOCK_DIR" 2>/dev/null || true
    RESTORE_LOCK_METHOD=""
    return 1
  fi
}

transaction_release_lock() {
  case "${RESTORE_LOCK_METHOD:-}" in
    flock)
      flock -u 201 2>/dev/null || true
      { exec 201>&-; } 2>/dev/null || true
      ;;
    mkdir)
      rm -f "${RESTORE_LOCK_DIR}/owner" 2>/dev/null || true
      rmdir "$RESTORE_LOCK_DIR" 2>/dev/null || true
      ;;
  esac
  RESTORE_LOCK_METHOD=""
}

transaction_base64_encode() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

transaction_base64_decode() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s' "$1" | base64 -D
  else
    printf '%s' "$1" | base64 -d
  fi
}

transaction_preserve_file() {
  local destination="$1" encoded index backup existed=0
  transaction_path_is_safe "$destination" || return 1
  encoded="$(transaction_base64_encode "$destination")" || return 1
  if [[ -n "${PRESERVED_TRANSACTION_FILES[$encoded]:-}" ]]; then
    return 0
  fi
  PRESERVED_TRANSACTION_FILES["$encoded"]=1
  index="$(wc -l <"${RESTORE_TRANSACTION_DIR}/files.tsv" | tr -d ' ')"
  backup="${RESTORE_TRANSACTION_DIR}/file_backups/${index}"
  if root_exec test -e "$destination" || root_exec test -L "$destination"; then
    root_exec cp -a "$destination" "$backup" || return 1
    existed=1
  fi
  printf '%s\t%s\t%s\n' "$encoded" "$existed" "$backup" \
    >>"${RESTORE_TRANSACTION_DIR}/files.tsv"
}

transaction_install_file() {
  local source="$1" destination="$2"
  [[ -f "$source" ]] || return 1
  transaction_preserve_file "$destination" || return 1
  if root_exec test -e "$destination" || root_exec test -L "$destination"; then
    root_exec rm -rf "$destination" || return 1
  fi
  root_exec mkdir -p "$(dirname "$destination")" || return 1
  root_exec cp -a "$source" "$destination"
}

transaction_install_tree() {
  local source="$1" destination="$2" file rel
  [[ -d "$source" ]] || return 1
  transaction_path_is_safe "${destination}/.docker-migrate-path-check" || return 1
  while IFS= read -r -d '' file; do
    rel="${file#"${source}/"}"
    transaction_install_file "$file" "${destination}/${rel}" || return 1
  done < <(find "$source" -type f -print0)
}

transaction_restore_files() {
  local encoded existed backup destination rc=0 i
  local -a records=()
  [[ -f "${RESTORE_TRANSACTION_DIR}/files.tsv" ]] || return 0
  mapfile -t records <"${RESTORE_TRANSACTION_DIR}/files.tsv"
  for ((i = ${#records[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r encoded existed backup <<<"${records[$i]}"
    destination="$(transaction_base64_decode "$encoded")" || {
      rc=1
      continue
    }
    transaction_path_is_safe "$destination" || {
      rc=1
      continue
    }
    if root_exec test -e "$destination" || root_exec test -L "$destination"; then
      root_exec rm -rf "$destination" || {
        rc=1
        continue
      }
    fi
    if [[ "$existed" == "1" ]]; then
      root_exec mkdir -p "$(dirname "$destination")" || {
        rc=1
        continue
      }
      if ! root_exec cp -a "$backup" "$destination"; then
        warn " · Compose 配置文件回滚失败：$destination"
        rc=1
      fi
    fi
  done
  return "$rc"
}

transaction_normalize_path() {
  local path="$1" probe component suffix="" resolved parent base component_i last_index
  [[ -n "$path" ]] || return 1
  [[ "$path" == /* ]] || path="${PWD}/${path}"
  while [[ "$path" != "/" && "$path" == */ ]]; do path="${path%/}"; done

  # macOS realpath 没有 GNU -m。先向上寻找最近的已存在祖先，用普通
  # realpath/readlink/pwd -P 解析 symlink，再把不存在的尾部拼回并词法归一化。
  probe="$path"
  while [[ ! -e "$probe" && ! -L "$probe" ]]; do
    [[ "$probe" != "/" ]] || break
    component="${probe##*/}"
    suffix="${component}${suffix:+/${suffix}}"
    probe="${probe%/*}"
    [[ -n "$probe" ]] || probe="/"
  done

  resolved=""
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath "$probe" 2>/dev/null || true)"
  fi
  if [[ -z "$resolved" ]] && command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$probe" 2>/dev/null || true)"
  fi
  if [[ -z "$resolved" ]]; then
    if [[ -d "$probe" ]]; then
      resolved="$(cd -P "$probe" 2>/dev/null && pwd -P)" || return 1
    elif [[ -e "$probe" && ! -L "$probe" ]]; then
      parent="$(dirname "$probe")"
      base="$(basename "$probe")"
      parent="$(cd -P "$parent" 2>/dev/null && pwd -P)" || return 1
      resolved="${parent}/${base}"
    else
      # 无法可靠解析 broken symlink 时必须 fail closed，不能退回易绕过的字符串比较。
      return 1
    fi
  fi

  path="${resolved}${suffix:+/${suffix}}"
  local -a components=() normalized=()
  IFS='/' read -r -a components <<<"$path"
  for component in "${components[@]}"; do
    case "$component" in
      "" | .) ;;
      ..)
        if ((${#normalized[@]} > 0)); then
          last_index=$((${#normalized[@]} - 1))
          unset "normalized[$last_index]"
        fi
        ;;
      *) normalized+=("$component") ;;
    esac
  done
  if ((${#normalized[@]} == 0)); then
    printf '/\n'
  else
    printf '/%s' "${normalized[0]}"
    for ((component_i = 1; component_i < ${#normalized[@]}; component_i++)); do
      printf '/%s' "${normalized[$component_i]}"
    done
    printf '\n'
  fi
}

transaction_internal_paths_are_safe() {
  local rollback_base lock_base host normalized_host label protected normalized_protected protected_i
  rollback_base="${RESTORE_ROLLBACK_BASE:-${HOME:-${BUNDLE_DIR}}/.docker_migrate_rollback}"
  lock_base="${RESTORE_LOCK_BASE:-${HOME:-${BUNDLE_DIR}}/.docker_migrate_locks}"
  local -a protected_paths=(
    "迁移包所在目录" "$BUNDLE_DIR"
    "还原资料目录" "$rollback_base"
    "锁文件目录" "$lock_base"
  )
  if [[ -n "${RESTORE_SESSION_DIR:-}" ]]; then
    protected_paths+=("下载目录" "$RESTORE_SESSION_DIR")
  fi

  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    bind_path_is_system "$host" && continue
    normalized_host="$(transaction_normalize_path "$host")" || return 1
    for ((protected_i = 0; protected_i < ${#protected_paths[@]}; protected_i += 2)); do
      label="${protected_paths[$protected_i]}"
      protected="${protected_paths[$((protected_i + 1))]}"
      normalized_protected="$(transaction_normalize_path "$protected")" || return 1
      if mount_paths_overlap "$normalized_host" "$normalized_protected"; then
        warn "挂载目录 ${host} 和${label}重叠，为避免覆盖，已在改动数据前停止"
        warn "重叠的位置：$normalized_protected"
        warn "请把 RESTORE_BASE、RESTORE_ROLLBACK_BASE、RESTORE_LOCK_BASE 设置到这个目录之外后重试。"
        return 1
      fi
    done
  done < <(jq -r '.binds[] | .host, (.link // empty)' manifest.json)
}
