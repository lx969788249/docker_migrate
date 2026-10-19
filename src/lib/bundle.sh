# 迁移包结构：校验清单、manifest 与归档安全检查、恢复结果统计。

json_array_from_lines() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
    return 0
  fi
  # 过滤空行，避免空数组被序列化成 [""]。
  printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -cs .
}

generate_bundle_checksums() {
  local bundle_dir="$1"
  local manifest="${bundle_dir}/checksums.sha256"
  local file rel digest
  : >"$manifest"
  while IFS= read -r -d '' file; do
    rel="${file#"${bundle_dir}/"}"
    case "$rel" in checksums.sha256 | restore.sh | .docker_migrate_rollback/*) continue ;; esac
    digest="$(sha256_file "$file")" || {
      RED "[ERR] 系统缺少 SHA-256 工具（sha256sum/shasum/openssl）。"
      return 1
    }
    printf '%s\t%s\n' "$digest" "$rel" >>"$manifest"
  done < <(find "$bundle_dir" -type f -print0)
}

verify_bundle_checksums() {
  local bundle_dir="$1"
  local manifest="${bundle_dir}/checksums.sha256"
  local expected rel file actual count=0
  local -A verified_paths=()
  [[ -f "$manifest" ]] || {
    RED "[ERR] 迁移包缺少 checksums.sha256。"
    return 1
  }
  while IFS=$'\t' read -r expected rel; do
    [[ -n "$expected" && -n "$rel" ]] || continue
    case "$rel" in
      /* | .. | ../* | */../* | */..)
        RED "[ERR] 校验清单含危险路径：$rel"
        return 1
        ;;
    esac
    file="${bundle_dir}/${rel}"
    [[ -f "$file" ]] || {
      RED "[ERR] 迁移包缺少文件：$rel"
      return 1
    }
    actual="$(sha256_file "$file")" || return 1
    [[ "$actual" == "$expected" ]] || {
      RED "[ERR] 文件完整性校验失败：$rel"
      return 1
    }
    verified_paths["$rel"]=1
    count=$((count + 1))
  done <"$manifest"
  ((count > 0)) || {
    RED "[ERR] 校验清单为空。"
    return 1
  }
  while IFS= read -r -d '' file; do
    rel="${file#"${bundle_dir}/"}"
    case "$rel" in checksums.sha256 | restore.sh | .docker_migrate_rollback/*) continue ;; esac
    if [[ -z "${verified_paths["$rel"]+present}" ]]; then
      RED "[ERR] 迁移包含未纳入校验清单的文件：$rel"
      return 1
    fi
  done < <(find "$bundle_dir" -type f -print0)
}

bundle_manifest_is_safe() {
  local bundle_dir="$1" manifest run name metadata_name
  manifest="${bundle_dir}/manifest.json"
  [[ -f "$manifest" ]] || return 1
  jq -e '
    type == "object" and
    (.images | type == "array") and
    (.networks | type == "array") and
    (.projects | type == "array") and
    (.volumes | type == "array") and
    (.binds | type == "array") and
    (.runs | type == "array") and
    all(.networks[]; type == "object" and (.name | type == "string")) and
    all(.runs[]; type == "string" and test("^runs/[A-Za-z0-9][A-Za-z0-9_.-]*\\.sh$")) and
    all(.projects[];
      (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) and
      (.working_dir // "" | type == "string" and
        (. == "" or (startswith("/") and (test("(^|/)\\.\\.(/|$)") | not) and
          all(explode[]; . >= 32 and . != 127))))
    ) and
    all(.volumes[]; (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$"))) and
    all(.binds[];
      (.host | type == "string" and startswith("/") and . != "/" and
        (test("(^|/)\\.\\.(/|$)") | not) and
        all(explode[]; . >= 32 and . != 127)) and
      (.file | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*\\.tgz$")) and
      ((.link // null) == null or (.link | type == "string" and startswith("/") and . != "/" and
        (test("(^|/)\\.\\.(/|$)") | not) and
        all(explode[]; . >= 32 and . != 127)))
    )
  ' "$manifest" >/dev/null || return 1

  while IFS= read -r run; do
    [[ -f "${bundle_dir}/${run}" ]] || return 1
    name="${run#runs/}"
    name="${name%.sh}"
    [[ -f "${bundle_dir}/meta/${name}.inspect.json" ]] || return 1
    metadata_name="$(jq -r '.[0].Name | ltrimstr("/")' \
      "${bundle_dir}/meta/${name}.inspect.json" 2>/dev/null || true)"
    [[ "$metadata_name" == "$name" ]] || return 1
  done < <(jq -r '.runs[]' "$manifest")
}

archive_layout_is_safe() {
  local archive="$1"
  local entry
  # 在同一次成员列表扫描中同时确认归档可读并校验路径；pipefail 会保留 tar
  # 解压列表失败的状态，避免为了取得退出码再完整解压一遍 gzip 流。
  tar -tzf "$archive" 2>/dev/null |
    while IFS= read -r entry; do
      case "$entry" in
        /* | .. | ../* | */../* | */..) exit 1 ;;
      esac
    done || return 1
  # 顶层迁移包不需要符号链接或硬链接；拒绝它们可避免解压路径绕过。
  ! tar -tvzf "$archive" | awk 'substr($1,1,1) ~ /^[lh]$/ { bad=1 } END { exit bad ? 0 : 1 }'
}

restore_target_container_names() {
  local bundle_dir="$1" run project service found_service inspect_file
  [[ -f "${bundle_dir}/manifest.json" ]] || return 0
  while IFS= read -r run; do
    [[ -n "$run" ]] || continue
    basename "${run%.sh}"
  done < <(jq -r '.runs[]?' "${bundle_dir}/manifest.json" 2>/dev/null || true)
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    found_service=0
    for inspect_file in "${bundle_dir}"/meta/*.inspect.json; do
      [[ -f "$inspect_file" ]] || continue
      service="$(jq -r --arg project "$project" '
        if (.[0].Config.Labels["com.docker.compose.project"] // "") == $project
        then .[0].Config.Labels["com.docker.compose.service"] // empty
        else empty end
      ' "$inspect_file" 2>/dev/null || true)"
      [[ -n "$service" ]] || continue
      found_service=1
      docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --filter "label=com.docker.compose.service=${service}" \
        --format '{{.Names}}' 2>/dev/null || true
    done
    if ((found_service == 0)); then
      docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Names}}' 2>/dev/null || true
    fi
  done < <(jq -r '.projects[]?.name' "${bundle_dir}/manifest.json" 2>/dev/null || true)
}

collect_restore_result_metrics() {
  local bundle_dir="$1" name state
  local total=0 running=0 paused=0 stopped=0 missing=0 volumes=0 binds=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    total=$((total + 1))
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    case "$state" in
      running | restarting) running=$((running + 1)) ;;
      paused) paused=$((paused + 1)) ;;
      created | exited | dead | removing) stopped=$((stopped + 1)) ;;
      *) missing=$((missing + 1)) ;;
    esac
  done < <(restore_target_container_names "$bundle_dir" | awk 'NF && !seen[$0]++')
  if [[ -f "${bundle_dir}/manifest.json" ]]; then
    volumes="$(jq -r '.volumes | length' "${bundle_dir}/manifest.json" 2>/dev/null || echo 0)"
    binds="$(jq -r '.binds | length' "${bundle_dir}/manifest.json" 2>/dev/null || echo 0)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$total" "$running" "$paused" "$stopped" "$missing" "$volumes" "$binds"
}
