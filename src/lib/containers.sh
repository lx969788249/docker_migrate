# 容器改名与网络重连：单容器恢复脚本与恢复事务共用，供失败时还原旧容器。

rename_container_with_retry() {
  local old_name="$1" new_name="$2"
  for _ in {1..20}; do
    if dm_quiet docker rename "$old_name" "$new_name"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

restore_container_networks() {
  local container="$1" metadata_file="$2" entry network ip ip6 alias
  local -a connect_args=()
  [[ -f "$metadata_file" ]] || return 1
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    network="$(jq -r '.key' <<<"$entry")"
    case "$network" in "" | host | none) continue ;; esac
    if docker inspect "$container" | jq -e --arg network "$network" \
      '.[0].NetworkSettings.Networks[$network] != null' >/dev/null 2>&1; then
      continue
    fi
    connect_args=()
    if [[ "$network" == "bridge" ]]; then
      dm_quiet docker network connect "$network" "$container" || return 1
      continue
    fi
    ip="$(jq -r '.value.IPAMConfig.IPv4Address // empty' <<<"$entry")"
    ip6="$(jq -r '.value.IPAMConfig.IPv6Address // empty' <<<"$entry")"
    [[ -z "$ip" ]] || connect_args+=(--ip "$ip")
    [[ -z "$ip6" ]] || connect_args+=(--ip6 "$ip6")
    while IFS= read -r alias; do
      [[ -z "$alias" ]] || connect_args+=(--alias "$alias")
    done < <(jq -r '.value.Aliases[]? // empty' <<<"$entry")
    dm_quiet docker network connect "${connect_args[@]}" "$network" "$container" || return 1
  done < <(jq -c 'to_entries[]?' "$metadata_file")
}

# Compose 在 com.docker.compose.project.config_files 标签里用逗号连接多个配置
# 文件（-f a.yml -f b.yml）。没有逗号时兼容按冒号分隔的旧写法（COMPOSE_FILE）。
compose_config_files_split() {
  local raw="$1" sep=","
  [[ -n "$raw" ]] || return 0
  [[ "$raw" == *,* ]] || sep=":"
  local -a parts=()
  IFS="$sep" read -r -a parts <<<"$raw"
  printf '%s\n' "${parts[@]}" | awk 'NF'
}

# 等待健康检查的最长时间：至少是 RESTORE_HEALTH_TIMEOUT（默认 60 秒），并且要
# 够容器自己的健康检查跑完第一次。有的镜像每 60 秒才检查一次（如 Vaultwarden），
# 固定等 60 秒会在第一次检查出结果之前就判定超时。
health_wait_seconds() {
  local base="${1:-60}" needed
  shift
  (($# > 0)) || {
    printf '%s\n' "$base"
    return 0
  }
  needed="$(docker inspect "$@" 2>/dev/null | jq '[.[] | .Config.Healthcheck // empty |
    select((.Test[0] // "") != "NONE") |
    ((.StartPeriod // 0) + (if (.Interval // 0) > 0 then .Interval else 30000000000 end) +
      (if (.Timeout // 0) > 0 then .Timeout else 30000000000 end)) / 1000000000 + 30 | floor] |
    max // 0' 2>/dev/null || echo 0)"
  [[ "$needed" =~ ^[0-9]+$ ]] || needed=0
  ((needed > base)) || needed="$base"
  ((needed <= 3600)) || needed=3600
  printf '%s\n' "$needed"
}
