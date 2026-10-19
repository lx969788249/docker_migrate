# 容器改名与网络重连：单容器恢复脚本与恢复事务共用，供失败时还原旧容器。

rename_container_with_retry() {
  local old_name="$1" new_name="$2"
  for _ in {1..20}; do
    if docker rename "$old_name" "$new_name" >/dev/null 2>&1; then
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
      docker network connect "$network" "$container" >/dev/null 2>&1 || return 1
      continue
    fi
    ip="$(jq -r '.value.IPAMConfig.IPv4Address // empty' <<<"$entry")"
    ip6="$(jq -r '.value.IPAMConfig.IPv6Address // empty' <<<"$entry")"
    [[ -z "$ip" ]] || connect_args+=(--ip "$ip")
    [[ -z "$ip6" ]] || connect_args+=(--ip6 "$ip6")
    while IFS= read -r alias; do
      [[ -z "$alias" ]] || connect_args+=(--alias "$alias")
    done < <(jq -r '.value.Aliases[]? // empty' <<<"$entry")
    docker network connect "${connect_args[@]}" "$network" "$container" >/dev/null 2>&1 || return 1
  done < <(jq -c 'to_entries[]?' "$metadata_file")
}
