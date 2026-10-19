# 迁移计划（plan.json）：新服务器在下载迁移包之前用它做预检。
#
# 源端打包时根据迁移清单与容器配置生成，内容只有“迁移需要什么”：CPU 架构、
# 容器端口、网络网段、数据卷与目录大小等，没有任何业务数据。它既放进迁移包，
# 也单独加密后与迁移包一起提供下载；新服务器从同一个链接推算出它的地址，
# 用户只需要复制一个链接。

# 下载链接 → 迁移计划地址：同一随机路径下，把 .tar.gz.enc 换成 .plan。
plan_url_from_bundle_url() {
  local url="${1%%#*}"
  [[ "$url" == *.tar.gz.enc ]] || return 1
  printf '%s.plan\n' "${url%.tar.gz.enc}"
}

# 计划使用与迁移包不同的 IV：同一把 CTR 密钥绝不能重复使用同一个 IV。
plan_iv() {
  printf 'docker-migrate-plan:%s' "${1,,}" | openssl dgst -sha256 2>/dev/null | awk '{print substr($NF, 1, 32)}'
}

# 生成迁移计划（输出到标准输出）。
plan_build() {
  local bundle_dir="$1" images_bytes="${2:-0}" plain_bytes
  plain_bytes="$(path_size_bytes "$bundle_dir")"
  jq -n \
    --arg arch "$(docker info --format '{{.Architecture}}' 2>/dev/null || uname -m)" \
    --arg docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)" \
    --argjson images_bytes "${images_bytes:-0}" \
    --argjson plain_bytes "${plain_bytes:-0}" \
    --slurpfile manifest "${bundle_dir}/manifest.json" \
    --slurpfile metas <(cat "${bundle_dir}"/meta/*.inspect.json 2>/dev/null || true) '
    ($manifest[0]) as $m |
    ([$m.projects[]?.name]) as $projects |
    {
      version: 1,
      source: {arch: $arch, docker: $docker},
      sizes: {
        bundle: $plain_bytes,
        images: $images_bytes,
        volumes: ([$m.volumes[]?.bytes // 0] | add // 0),
        binds: ([$m.binds[]?.bytes // 0] | add // 0)
      },
      needs_compose: (($projects | length) > 0),
      projects: $projects,
      containers: [$metas[] | .[0] |
        (.Config.Labels["com.docker.compose.project"] // "") as $project |
        {
          name: (.Name | ltrimstr("/")),
          project: (if ($projects | index($project)) then $project else "" end),
          network_mode: (.HostConfig.NetworkMode // "default"),
          runtime: (.HostConfig.Runtime // ""),
          devices: [.HostConfig.Devices[]?.PathOnHost],
          memory: (.HostConfig.Memory // 0),
          ports: [(.HostConfig.PortBindings // {}) | to_entries[] | .key as $c | .value[]? |
            select((.HostPort // "") != "") |
            {host_ip: (.HostIp // ""), host_port: .HostPort,
             container_port: ($c | split("/")[0]), proto: ($c | split("/")[1] // "tcp")}],
          networks: [(.NetworkSettings.Networks // {}) | to_entries[] |
            {name: .key, ip: (.value.IPAMConfig.IPv4Address // "")}],
          volumes: [.Mounts[]? | select(.Type == "volume") | .Name],
          binds: [.Mounts[]? | select(.Type == "bind") | .Source]
        }],
      volumes: [$m.volumes[]? | {name, driver: (.driver // "local"), opts: (.opts // {}), bytes: (.bytes // 0)}],
      binds: [$m.binds[]? | {host, link: (.link // ""), bytes: (.bytes // 0)}],
      networks: [$m.networks[]? | {name, driver: (.driver // "bridge"),
        subnets: [.ipam.config[]?.Subnet // empty],
        compose: ((.labels // {})["com.docker.compose.network"] != null)}]
    }'
}

# 加密迁移计划：输出文件第一行是签名（HMAC），其后是密文。
plan_encrypt() {
  local input="$1" output="$2" encryption_key="$3" mac_key="$4" iv="$5" piv tmp mac
  piv="$(plan_iv "$iv")"
  valid_hex_length "$piv" 32 || return 1
  tmp="${output}.cipher.$$"
  openssl enc -aes-256-ctr -nosalt -K "$encryption_key" -iv "$piv" -in "$input" -out "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mac="$(bundle_hmac_sha256_file "$tmp" "$mac_key" "$piv")" || {
    rm -f "$tmp"
    return 1
  }
  {
    printf '%s\n' "$mac"
    cat "$tmp"
  } >"$output"
  rm -f "$tmp"
}

# 验证签名并解密迁移计划。签名不符时返回 2（文件被篡改或链接不完整）。
plan_decrypt() {
  local input="$1" output="$2" encryption_key="$3" mac_key="$4" iv="$5" piv tmp mac
  piv="$(plan_iv "$iv")"
  valid_hex_length "$piv" 32 || return 1
  mac="$(head -n1 "$input" 2>/dev/null || true)"
  valid_sha256 "$mac" || return 2
  tmp="${output}.cipher.$$"
  tail -c +66 "$input" >"$tmp" || return 1
  if [[ "$(bundle_hmac_sha256_file "$tmp" "$mac_key" "$piv" 2>/dev/null || true)" != "${mac,,}" ]]; then
    rm -f "$tmp"
    return 2
  fi
  openssl enc -d -aes-256-ctr -nosalt -K "$encryption_key" -iv "$piv" -in "$tmp" -out "$output" ||
    {
      rm -f "$tmp"
      return 1
    }
  rm -f "$tmp"
  jq -e '.version == 1' "$output" >/dev/null 2>&1 || return 1
}
