# 恢复决定：迁移前预检中用户（或 RESTORE_AUTO_RESOLVE）做出的选择，由
# DM_RESTORE_DECISIONS 指向的 JSON 文件传给恢复脚本与单容器恢复脚本。
# 没有这个文件时所有查询都返回“没有特别决定”，恢复按原配置进行。

decisions_present() {
  [[ -n "${DM_RESTORE_DECISIONS:-}" && -s "${DM_RESTORE_DECISIONS}" ]]
}

# decision_listed 列表名 值：值是否在决定文件的某个列表里（如 skip_projects）。
decision_listed() {
  decisions_present || return 1
  jq -e --arg k "$1" --arg v "$2" '(.[$k] // []) | index($v) != null' \
    "$DM_RESTORE_DECISIONS" >/dev/null 2>&1
}

# 容器在某个网络中是否改为自动分配 IP（单独选择、网段改为自动或沿用已有网络时都是）。
decision_auto_ip() {
  local container="$1" network="$2"
  decisions_present || return 1
  jq -e --arg c "$container" --arg n "$network" '(.auto_ip // []) | any(.container == $c and .network == $n)' \
    "$DM_RESTORE_DECISIONS" >/dev/null 2>&1 ||
    decision_listed auto_subnet "$network" || decision_listed reuse_network "$network"
}

# 端口映射的新宿主机端口；输出为空表示不再对外开放；没有调整时返回 1。
decision_port() {
  local container="$1" host_ip="$2" host_port="$3" container_port="$4" proto="$5"
  decisions_present || return 1
  jq -er --arg c "$container" --arg ip "$host_ip" --arg hp "$host_port" \
    --arg cp "$container_port" --arg proto "$proto" '
    [(.port_map // [])[] | select(.container == $c and .host_ip == $ip and .host_port == $hp and
      .container_port == $cp and .proto == $proto) | .new_port] | first // empty | tostring' \
    "$DM_RESTORE_DECISIONS" 2>/dev/null || {
    jq -e --arg c "$container" --arg ip "$host_ip" --arg hp "$host_port" \
      --arg cp "$container_port" --arg proto "$proto" '
      (.port_map // []) | any(.container == $c and .host_ip == $ip and .host_port == $hp and
        .container_port == $cp and .proto == $proto and .new_port == "")' \
      "$DM_RESTORE_DECISIONS" >/dev/null 2>&1 || return 1
    printf '\n'
  }
}
