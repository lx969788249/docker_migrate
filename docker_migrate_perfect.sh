#!/usr/bin/env bash
# docker_migrate_perfect.sh — Docker 容器一键迁移（源服务器使用）
#
# 功能概要：
# 1. 自动检测并安装依赖（docker / jq / python3 / tar / gzip / curl）
# 2. 按“独立容器 / docker compose 容器组”展示并选择要迁移的容器
# 3. 打包：镜像、命名卷、绑定目录、（可用的）Compose 配置
# 4. 生成 manifest.json 和 restore.sh
# 5. 启动带安全随机路径的 HTTP 服务，输出下载链接；退出时关闭 HTTP、重启停机容器、清理临时文件
#
# 本版修复：
# - 恢复时同名容器已存在但端口绑定不同，会删除并重建容器，避免“恢复成功但端口丢失”。
# - 单容器 docker compose 项目按独立容器恢复，确保可以从 inspect 还原 -p 端口参数。
# - 端口绑定还原支持空 HostPort 跳过、IPv6 HostIp 加方括号。
# - 恢复已暂停容器时会先 unpause，再 start / remove。
#
# 环境变量：
# PORT=8080             默认 HTTP 端口（会询问你要不要改；被占用则向后尝试）
# ADVERTISE_HOST=IP     下载链接里使用的域名/IP（默认自动探测）
# RESTORE_KEEP=1        恢复后保留下载包与解压目录
# RESTORE_CLEAN_ALL=1   恢复失败也强制清理文件
# RESTORE_BASE=/path    新服务器恢复目录
#
# 参数：
# --no-stop             不停机备份（可能不一致，数据库慎用）
# --include=name1,name2 按容器名称精确匹配，只迁移指定容器（不使用分组菜单）

set -euo pipefail

declare -a IDS=()
declare -a RUNS=()

#####################################
# 基础函数 & 依赖管理
#####################################
BLUE(){ echo -e "\033[1;34m$*\033[0m"; }
YEL(){ echo -e "\033[1;33m$*\033[0m"; }
RED(){ echo -e "\033[1;31m$*\033[0m"; }
OK(){ echo -e "\033[1;32m$*\033[0m"; }

asudo() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
  if command -v apk >/dev/null 2>&1; then echo apk; return; fi
  echo none
}

pm_install() {
  local pm="$1"; shift
  case "$pm" in
    apt)
      asudo apt-get update -y
      asudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf) asudo dnf install -y "$@" ;;
    yum) asudo yum install -y "$@" ;;
    zypper) asudo zypper --non-interactive install -y "$@" ;;
    apk) asudo apk add --no-cache "$@" ;;
    *)
      RED "[ERR] 不支持的包管理器：$pm，请手动安装：$*"
      exit 1
      ;;
  esac
}

need_bin() {
  local bin="$1" pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[INFO] 安装依赖：$bin"
    pm_install "$PKGMGR" "$pkg"
  fi
}

ensure_docker_running() {
  if ! command -v docker >/dev/null 2>&1; then
    RED "[ERR] 未检测到 docker，请先安装 Docker 再运行本脚本。"
    exit 1
  fi

  if docker info >/dev/null 2>&1; then
    return 0
  fi

  YEL "[INFO] 尝试启动 Docker 服务..."
  if command -v systemctl >/dev/null 2>&1; then
    asudo systemctl enable --now docker || true
  fi
  if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    asudo service docker start || true
  fi
  if ! docker info >/dev/null 2>&1; then
    YEL "[WARN] 尝试后台直接启动 dockerd ..."
    if command -v dockerd >/dev/null 2>&1; then
      asudo nohup dockerd >/var/log/dockerd.migrate.log 2>&1 &
      sleep 3
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    RED "[ERR] Docker 仍未正常启动，请手动检查后重试。"
    exit 1
  fi
}

human() {
  local b="${1:-0}"
  local -a u=(B KB MB GB TB PB)
  local i=0
  while (( b >= 1024 && i < ${#u[@]} - 1 )); do
    b=$((b / 1024))
    i=$((i + 1))
  done
  echo "${b}${u[$i]}"
}

progress_docker_save() {
  local outfile="$1"; shift
  local rc=0
  if command -v pv >/dev/null 2>&1; then
    BLUE "[INFO] 保存镜像 images.tar（使用 pv 显示进度）..."
    if ! "$@" | pv -b > "$outfile"; then
      rc=$?
    fi
    local cur
    cur=$(stat -c %s "$outfile" 2>/dev/null || stat -f%z "$outfile" 2>/dev/null || echo 0)
    echo "[进度] images.tar 完成：$(human "$cur")"
  else
    BLUE "[INFO] 保存镜像 images.tar（此步骤可能较久，请耐心等待）..."
    "$@" > "$outfile" &
    local pid=$!
    printf "[进度] images.tar "
    # 把进度显示放到后台子 shell，避免 PID 竞态导致死循环。
    # wait 直接等待子进程，不受 OS 回收 PID 影响。
    (
      local last=0 cur=0
      local spin='-/|\' i=0
      while kill -0 "$pid" 2>/dev/null; do
        if [[ -f "$outfile" ]]; then
          cur=$(stat -c %s "$outfile" 2>/dev/null || stat -f%z "$outfile" 2>/dev/null || echo 0)
          if (( cur != last )); then
            printf "\r[进度] images.tar %c 已写入：%s" "${spin:$i:1}" "$(human "$cur")"
            last=$cur
          else
            printf "\r[进度] images.tar %c 写入中 ..." "${spin:$i:1}"
          fi
        else
          printf "\r[进度] images.tar %c 准备中 ..." "${spin:$i:1}"
        fi
        i=$(((i + 1) % 4))
        sleep 1
      done
    ) &
    local spinner_pid=$!
    if ! wait "$pid"; then
      rc=$?
    fi
    kill "$spinner_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true
    cur=$(stat -c %s "$outfile" 2>/dev/null || stat -f%z "$outfile" 2>/dev/null || echo 0)
    printf "\r%-80s\r" ""
    echo "[进度] images.tar 完成：$(human "$cur")"
  fi
  return "$rc"
}

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  [[ "$ip" =~ ^127\. ]] && return 0
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  return 1
}

get_public_ip_external() {
  local ip
  for svc in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
    ip="$(curl -fsS --max-time 2 "$svc" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

pick_advertise_url() {
  local port="$1"
  local host=""
  if [[ -n "${ADVERTISE_HOST:-}" ]]; then
    host="$ADVERTISE_HOST"
  else
    local via_route=""
    via_route="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if [[ -n "$via_route" ]] && ! is_private_ipv4 "$via_route"; then
      host="$via_route"
    fi
    [[ -z "$host" ]] && host="$(get_public_ip_external || true)"
    [[ -z "$host" ]] && host="$(ip -4 -o addr show 2>/dev/null | awk '!/ lo| docker| veth| br-| kube/ {print $4}' | cut -d/ -f1 | head -n1 || true)"
    : "${host:=127.0.0.1}"
  fi
  echo "http://${host}:${port}"
}

pick_free_port() {
  local p="${1:-8080}"
  local i
  for i in $(seq 0 50); do
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then echo "$p"; return 0; fi
    elif command -v netstat >/dev/null 2>&1; then
      if ! netstat -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then echo "$p"; return 0; fi
    else
      echo "$p"; return 0
    fi
    p=$((p + 1))
  done
  echo "${1:-8080}"
}

json_array_from_lines() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
    return 0
  fi
  # 过滤空行，避免空数组被序列化成 [""]。
  printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -cs .
}

#####################################
# 生成单容器恢复脚本
#####################################
write_run_script() {
  local name="$1"
  local out="$2"
  cat > "$out" <<'RUN_SH'
#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
META="${BUNDLE_DIR}/meta/__NAME__.inspect.json"

if [[ ! -f "$META" ]]; then
  echo "[WARN] missing metadata: $META" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[WARN] jq is required to restore container: __NAME__" >&2
  exit 1
fi

name="$(jq -r '.[0].Name | ltrimstr("/")' "$META")"
image="$(jq -r '.[0].Config.Image' "$META")"
if [[ -z "$name" || -z "$image" || "$image" == "null" ]]; then
  echo "[WARN] invalid container metadata for __NAME__" >&2
  exit 1
fi

# 关键修复：Docker 端口发布只能在创建容器时设置。
# 如果同名容器已存在但端口绑定与旧机元数据不同，不能只 docker start，必须重建。
desired_ports="$(jq -cS '.[0].HostConfig.PortBindings // {}' "$META" 2>/dev/null || echo '{}')"
desired_publish_all="$(jq -r '.[0].HostConfig.PublishAllPorts // false' "$META" 2>/dev/null || echo false)"

if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
  existing_ports="$(docker inspect "$name" 2>/dev/null | jq -cS '.[0].HostConfig.PortBindings // {}' 2>/dev/null || echo '{}')"
  existing_publish_all="$(docker inspect "$name" 2>/dev/null | jq -r '.[0].HostConfig.PublishAllPorts // false' 2>/dev/null || echo false)"
  existing_state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"

  if [[ "$existing_ports" == "$desired_ports" && "$existing_publish_all" == "$desired_publish_all" ]]; then
    echo "[INFO] container exists: $name; port bindings unchanged; start if stopped"
    [[ "$existing_state" == "paused" ]] && docker unpause "$name" >/dev/null 2>&1 || true
    docker start "$name" >/dev/null 2>&1 || true
    exit 0
  fi

  echo "[WARN] container exists but port bindings differ: $name"
  echo "[WARN] remove and recreate it to restore published ports"
  [[ "$existing_state" == "paused" ]] && docker unpause "$name" >/dev/null 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1 || {
    echo "[WARN] failed to remove existing container: $name" >&2
    exit 1
  }
fi

args=(docker run -d --name "$name")
cmd_args=()

mapfile -t entrypoint < <(jq -r '.[0].Config.Entrypoint[]?' "$META")
mapfile -t cmd < <(jq -r '.[0].Config.Cmd[]?' "$META")
if ((${#entrypoint[@]})); then
  args+=(--entrypoint "${entrypoint[0]}")
  if ((${#entrypoint[@]} > 1)); then
    cmd_args+=("${entrypoint[@]:1}")
  fi
fi
if ((${#cmd[@]})); then
  cmd_args+=("${cmd[@]}")
fi

user="$(jq -r '.[0].Config.User // empty' "$META")"
[[ -n "$user" ]] && args+=(-u "$user")

workdir="$(jq -r '.[0].Config.WorkingDir // empty' "$META")"
[[ -n "$workdir" ]] && args+=(-w "$workdir")

cid="$(jq -r '.[0].Id' "$META")"
default_host="${cid:0:12}"
hostname="$(jq -r '.[0].Config.Hostname // empty' "$META")"
if [[ -n "$hostname" && "$hostname" != "$default_host" ]]; then
  args+=(--hostname "$hostname")
fi

domainname="$(jq -r '.[0].Config.Domainname // empty' "$META")"
[[ -n "$domainname" ]] && args+=(--domainname "$domainname")

mapfile -t envs < <(jq -r '.[0].Config.Env[]?' "$META")
for e in "${envs[@]}"; do args+=(-e "$e"); done

mapfile -t labels < <(jq -r '.[0].Config.Labels // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for l in "${labels[@]}"; do args+=(--label "$l"); done

restart_name="$(jq -r '.[0].HostConfig.RestartPolicy.Name // empty' "$META")"
restart_max="$(jq -r '.[0].HostConfig.RestartPolicy.MaximumRetryCount // 0' "$META")"
if [[ -n "$restart_name" && "$restart_name" != "no" ]]; then
  if [[ "$restart_name" == "on-failure" && "$restart_max" -gt 0 ]]; then
    args+=(--restart "${restart_name}:${restart_max}")
  else
    args+=(--restart "$restart_name")
  fi
fi

jq -e '.[0].HostConfig.Privileged == true' "$META" >/dev/null 2>&1 && args+=(--privileged)
jq -e '.[0].HostConfig.ReadonlyRootfs == true' "$META" >/dev/null 2>&1 && args+=(--read-only)
jq -e '.[0].HostConfig.Init == true' "$META" >/dev/null 2>&1 && args+=(--init)

mapfile -t extra_hosts < <(jq -r '.[0].HostConfig.ExtraHosts[]?' "$META")
for h in "${extra_hosts[@]}"; do args+=(--add-host "$h"); done

mapfile -t dns_list < <(jq -r '.[0].HostConfig.Dns[]?' "$META")
for d in "${dns_list[@]}"; do args+=(--dns "$d"); done
mapfile -t dns_search < <(jq -r '.[0].HostConfig.DnsSearch[]?' "$META")
for d in "${dns_search[@]}"; do args+=(--dns-search "$d"); done
mapfile -t dns_opts < <(jq -r '.[0].HostConfig.DnsOptions[]?' "$META")
for d in "${dns_opts[@]}"; do args+=(--dns-option "$d"); done

mapfile -t cap_add < <(jq -r '.[0].HostConfig.CapAdd[]?' "$META")
for c in "${cap_add[@]}"; do args+=(--cap-add "$c"); done
mapfile -t cap_drop < <(jq -r '.[0].HostConfig.CapDrop[]?' "$META")
for c in "${cap_drop[@]}"; do args+=(--cap-drop "$c"); done
mapfile -t sec_opts < <(jq -r '.[0].HostConfig.SecurityOpt[]?' "$META")
for s in "${sec_opts[@]}"; do args+=(--security-opt "$s"); done
mapfile -t sysctls < <(jq -r '.[0].HostConfig.Sysctls // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for s in "${sysctls[@]}"; do args+=(--sysctl "$s"); done
mapfile -t ulimits < <(jq -r '.[0].HostConfig.Ulimits[]? | "\(.Name)=\(.Soft):\(.Hard)"' "$META")
for u in "${ulimits[@]}"; do args+=(--ulimit "$u"); done
mapfile -t tmpfs < <(jq -r '.[0].HostConfig.Tmpfs // {} | to_entries[]? | "\(.key):\(.value)"' "$META")
for t in "${tmpfs[@]}"; do args+=(--tmpfs "$t"); done

log_driver="$(jq -r '.[0].HostConfig.LogConfig.Type // empty' "$META")"
if [[ -n "$log_driver" && "$log_driver" != "json-file" ]]; then
  args+=(--log-driver "$log_driver")
fi
mapfile -t log_opts < <(jq -r '.[0].HostConfig.LogConfig.Config // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for o in "${log_opts[@]}"; do args+=(--log-opt "$o"); done

publish_all="$(jq -r '.[0].HostConfig.PublishAllPorts // false' "$META")"
if [[ "$publish_all" == "true" ]]; then
  args+=(-P)
fi

# 关键修复：稳健还原 PortBindings。
# 旧脚本在 HostPort 为空或 IPv6 HostIp 场景下容易生成无效 -p；这里跳过空 HostPort，并给 IPv6 加 []。
mapfile -t port_bindings < <(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[]? | .key as $c | .value[]? | "\(.HostIp // "")|\(.HostPort // "")|\($c)"' "$META")
for p in "${port_bindings[@]}"; do
  host_ip="${p%%|*}"
  rest="${p#*|}"
  host_port="${rest%%|*}"
  cont_port="${rest#*|}"

  [[ -z "$host_port" || "$host_port" == "null" || -z "$cont_port" ]] && continue

  if [[ -n "$host_ip" && "$host_ip" != "0.0.0.0" && "$host_ip" != "::" ]]; then
    if [[ "$host_ip" == *:* ]]; then
      args+=(-p "[${host_ip}]:${host_port}:${cont_port}")
    else
      args+=(-p "${host_ip}:${host_port}:${cont_port}")
    fi
  else
    args+=(-p "${host_port}:${cont_port}")
  fi
  echo "[INFO] restore port: ${host_ip:-0.0.0.0}:${host_port}->${cont_port}"
done

mapfile -t mounts < <(jq -r '.[0].Mounts[]? | @base64' "$META")
for m in "${mounts[@]}"; do
  _jq(){ echo "$m" | base64 -d | jq -r "$1"; }
  m_type="$(_jq '.Type')"
  dest="$(_jq '.Destination')"
  rw="$(_jq '.RW')"
  mode="$(_jq '.Mode // empty')"
  src=""
  case "$m_type" in
    volume) src="$(_jq '.Name')" ;;
    bind) src="$(_jq '.Source')" ;;
    tmpfs) continue ;;
    *) continue ;;
  esac
  [[ -z "$src" || -z "$dest" || "$src" == "null" || "$dest" == "null" ]] && continue

  opts=()
  if [[ -n "$mode" && "$mode" != "null" ]]; then
    IFS=',' read -r -a mode_parts <<<"$mode"
    for part in "${mode_parts[@]}"; do [[ -n "$part" ]] && opts+=("$part"); done
  fi
  [[ "$rw" != "true" ]] && opts+=(ro)
  if ((${#opts[@]})); then
    optstr="$(IFS=,; echo "${opts[*]}")"
    args+=(-v "${src}:${dest}:${optstr}")
  else
    args+=(-v "${src}:${dest}")
  fi
done

network_mode="$(jq -r '.[0].HostConfig.NetworkMode // empty' "$META")"
if [[ "$network_mode" == container:* ]]; then
  ref="${network_mode#container:}"
  if [[ "$ref" =~ ^[0-9a-f]{12,}$ ]]; then
    for f in "${BUNDLE_DIR}"/meta/*.inspect.json; do
      [[ -f "$f" ]] || continue
      cid2="$(jq -r '.[0].Id' "$f")"
      if [[ "$cid2" == "$ref" || "${cid2:0:12}" == "$ref" ]]; then
        cname="$(jq -r '.[0].Name | ltrimstr("/")' "$f")"
        network_mode="container:$cname"
        break
      fi
    done
  fi
fi

primary_net=""
if [[ -n "$network_mode" && "$network_mode" != "default" && "$network_mode" != "bridge" ]]; then
  args+=(--network "$network_mode")
  primary_net="$network_mode"
else
  primary_net="bridge"
fi

args+=("$image")
if ((${#cmd_args[@]})); then
  args+=("${cmd_args[@]}")
fi

"${args[@]}"

# 连接额外网络。
if [[ "$network_mode" != "host" && "$network_mode" != "none" && "$network_mode" != container:* ]]; then
  mapfile -t net_entries < <(jq -r '.[0].NetworkSettings.Networks | to_entries[]? | @base64' "$META")
  for entry in "${net_entries[@]}"; do
    _net(){ echo "$entry" | base64 -d | jq -r "$1"; }
    net_name="$(_net '.key')"
    [[ -z "$net_name" || "$net_name" == "$primary_net" || "$net_name" == "bridge" ]] && continue
    ip="$(_net '.value.IPAddress')"
    ip6="$(_net '.value.IPv6Address')"
    aliases_raw="$(_net '.value.Aliases // empty | join(" ")')"
    conn_args=()
    [[ -n "$ip" && "$ip" != "null" ]] && conn_args+=(--ip "$ip")
    [[ -n "$ip6" && "$ip6" != "null" ]] && conn_args+=(--ip6 "$ip6")
    if [[ -n "$aliases_raw" && "$aliases_raw" != "null" ]]; then
      for a in $aliases_raw; do conn_args+=(--alias "$a"); done
    fi
    docker network connect "${conn_args[@]}" "$net_name" "$name" >/dev/null 2>&1 || echo "[WARN] 连接额外网络失败：$net_name，容器可能缺少网络" >&2
  done
fi
RUN_SH
  # 安全转义容器名中的 \ / &，防止 sed 替换出错
  local escaped_name="$name"
  escaped_name="${escaped_name//\\/\\\\}"   # \ → \\
  escaped_name="${escaped_name//\//\\/}"    # / → \/
  escaped_name="${escaped_name//&/\\&}"     # & → \&
  sed -i "s/__NAME__/${escaped_name}/g" "$out"
  chmod +x "$out"
}

#####################################
# 生成恢复主脚本
#####################################
write_bundle_restore_script() {
  local out="$1"
  cat > "$out" <<'REST_SH'
#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BUNDLE_DIR"

say(){ echo -e "\033[1;34m$*\033[0m"; }
warn(){ echo -e "\033[1;33m$*\033[0m"; }

compose_run() {
  if [[ "${COMPOSE_IMPL:-}" == "plugin" ]]; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

compose_networks_from_meta_all() {
  [[ -d meta ]] || return 0
  local f proj
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$f" 2>/dev/null || true)"
    [[ -n "$proj" ]] || continue
    jq -r '.[0].NetworkSettings.Networks | keys[]?' "$f" 2>/dev/null || true
  done | awk '!/^(bridge|host|none)$/' | sort -u
}

compose_networks_from_meta_for_project() {
  local project="$1"
  [[ -d meta ]] || return 0
  local f proj
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$f" 2>/dev/null || true)"
    [[ "$proj" == "$project" ]] || continue
    jq -r '.[0].NetworkSettings.Networks | keys[]?' "$f" 2>/dev/null || true
  done | awk '!/^(bridge|host|none)$/' | sort -u
}

compose_cleanup_conflicting_network() {
  local project="$1" network_name="$2"
  [[ -n "$network_name" ]] || return 0
  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    return 0
  fi
  local proj_label net_label
  proj_label="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$network_name" 2>/dev/null || true)"
  net_label="$(docker network inspect -f '{{ index .Labels "com.docker.compose.network" }}' "$network_name" 2>/dev/null || true)"
  if [[ "$proj_label" != "$project" || -z "$net_label" ]]; then
    if docker network rm "$network_name" >/dev/null 2>&1; then
      echo " · 已删除冲突网络：$network_name"
    else
      warn " · 无法删除冲突网络：$network_name（可能仍被占用）"
    fi
  fi
}

compose_network_records() {
  local project="$1"
  local tmp_cfg=""
  if command -v mktemp >/dev/null 2>&1; then
    tmp_cfg="$(mktemp)"
  else
    tmp_cfg="/tmp/docker_migrate_compose_config_$$.json"
    : > "$tmp_cfg"
  fi

  if compose_run config --format json >"$tmp_cfg" 2>/dev/null; then
    jq -r '
      .name as $project |
      ((.networks // {"default": {}}) | to_entries[]) |
      [(.value.name // "\($project)_\(.key)"), ((.value.external // false) | tostring)] | @tsv
    ' "$tmp_cfg"
    rm -f "$tmp_cfg" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp_cfg" 2>/dev/null || true

  while IFS= read -r net; do
    [[ -n "$net" ]] || continue
    if [[ "$net" == "${project}_"* ]]; then
      printf '%s\tfalse\n' "$net"
    else
      printf '%s\tunknown\n' "$net"
    fi
  done < <(compose_networks_from_meta_for_project "$project")
}

compose_prepare_networks() {
  local project="$1"
  local seen=0 net external
  while IFS=$'\t' read -r net external; do
    [[ -n "$net" ]] || continue
    seen=1
    case "$external" in
      true)
        if ! docker network inspect "$net" >/dev/null 2>&1; then
          warn " · 检测到外部网络缺失，尝试创建：$net"
          docker network create "$net" >/dev/null 2>&1 || warn " · 创建外部网络失败：$net"
        fi
        ;;
      false)
        compose_cleanup_conflicting_network "$project" "$net"
        ;;
      *)
        if [[ "$net" == "${project}_"* ]]; then
          compose_cleanup_conflicting_network "$project" "$net"
        fi
        ;;
    esac
  done < <(compose_network_records "$project")

  if (( seen == 0 )); then
    while IFS= read -r net; do
      [[ -n "$net" ]] || continue
      if [[ "$net" == "${project}_"* ]]; then
        compose_cleanup_conflicting_network "$project" "$net"
      fi
    done < <(compose_networks_from_meta_for_project "$project")
  fi
}

say "[A] 加载镜像（如 images.tar 存在）"
if [[ -f images.tar ]]; then
  docker load -i images.tar
else
  warn "images.tar 不存在，将按需在线拉取镜像。"
fi

say "[B] 回灌命名卷"
docker pull alpine:3.20 >/dev/null 2>&1 || warn "无法拉取 alpine:3.20，卷恢复可能失败"
if jq -e '.volumes|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p volumes
  while IFS= read -r row; do
    vname=$(jq -r '.name' <<<"$row")
    file="vol_${vname}.tgz"
    if [[ ! -f "volumes/$file" ]]; then
      warn " 跳过 $vname（缺少 volumes/$file）"
      continue
    fi
    echo " - ${vname}"
    docker volume create "$vname" >/dev/null 2>&1 || true
    docker run --rm \
      -v "${vname}:/to" \
      -v "$PWD/volumes:/from" \
      alpine:3.20 sh -c "cd /to && tar -xzf /from/${file}"
  done < <(jq -c '.volumes[]' manifest.json)
fi

say "[C] 回灌绑定目录"
if jq -e '.binds|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p binds
  while IFS= read -r row; do
    host=$(jq -r '.host' <<<"$row")
    file=$(jq -r '.file' <<<"$row")
    if [[ ! -f "binds/$file" ]]; then
      warn " 跳过 $host（缺少 binds/$file）"
      continue
    fi
    echo " - ${host}"
    parent="$(dirname "$host")"
    sudo mkdir -p "$parent" 2>/dev/null || mkdir -p "$parent" 2>/dev/null || true
    sudo tar -C / -xzf "binds/${file}" 2>/dev/null || tar -C / -xzf "binds/${file}" 2>/dev/null || warn " 无法恢复绑定目录：$host（可能需要 root 权限）"
  done < <(jq -c '.binds[]' manifest.json)
fi

say "[D] 恢复 Compose 项目"
if jq -e '.projects|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p compose_restore
  while IFS= read -r row; do
    name=$(jq -r '.name' <<<"$row")
    wdir=$(jq -r '.working_dir // ""' <<<"$row")
    echo " - project: $name"
    mkdir -p "compose_restore/${name}"

    if ls compose/${name}/* >/dev/null 2>&1; then
      for f in compose/${name}/*; do
        [[ -f "$f" ]] || continue
        cp -a "$f" "compose_restore/${name}/$(basename "$f")" 2>/dev/null || true
      done
    fi
    if [[ -f "compose/${name}/.env" ]]; then
      cp -a "compose/${name}/.env" "compose_restore/${name}/.env" 2>/dev/null || true
    fi

    if [[ -n "$wdir" ]]; then
      echo " · 还原 compose 配置到原路径：$wdir"
      mkdir -p "$wdir" || true
      if ls compose/${name}/* >/dev/null 2>&1; then
        for f in compose/${name}/*; do
          [[ -f "$f" ]] || continue
          base="$(basename "$f")"
          cp -n "$f" "$wdir/$base" 2>/dev/null || cp "$f" "$wdir/$base" 2>/dev/null || true
        done
      fi
      if [[ -f "compose/${name}/.env" ]]; then
        cp -n "compose/${name}/.env" "$wdir/.env" 2>/dev/null || cp "compose/${name}/.env" "$wdir/.env" 2>/dev/null || true
      fi
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      (
        cd "compose_restore/${name}"
        COMPOSE_IMPL="plugin"
        if [[ -f .env ]]; then set -a; . ./.env; set +a; elif [[ -n "$wdir" && -f "$wdir/.env" ]]; then set -a; . "$wdir/.env"; set +a; fi
        compose_run down || true
        compose_prepare_networks "$name"
        compose_run up -d
      )
    elif command -v docker-compose >/dev/null 2>&1; then
      (
        cd "compose_restore/${name}"
        COMPOSE_IMPL="legacy"
        if [[ -f .env ]]; then set -a; . ./.env; set +a; elif [[ -n "$wdir" && -f "$wdir/.env" ]]; then set -a; . "$wdir/.env"; set +a; fi
        compose_run down || true
        compose_prepare_networks "$name"
        compose_run up -d
      )
    else
      warn " 新机未安装 docker compose/docker-compose，跳过该项目。"
    fi
  done < <(jq -c '.projects[]' manifest.json)
fi

say "[E] 创建独立容器自定义网络（非 Compose）"
declare -A COMPOSE_NETS=()
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  COMPOSE_NETS["$n"]=1
done < <(compose_networks_from_meta_all)

if jq -e '.networks|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r n; do
    case "$n" in bridge|host|none|"") continue ;; esac
    if [[ -n "${COMPOSE_NETS[$n]:-}" ]]; then
      continue
    fi
    docker network inspect "$n" >/dev/null 2>&1 || docker network create "$n" >/dev/null 2>&1 || true
  done < <(jq -r '.networks[]' manifest.json)
fi

say "[F] 恢复单容器（非 Compose）"
if jq -e '.runs|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    echo " - $r"
    bash "$r" || true
  done < <(jq -r '.runs[]' manifest.json)
fi

say "[G] 完成，当前容器："
docker ps --format ' {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "提示：若端口被占用，请释放端口后重新执行 restore.sh；本版会在端口绑定不一致时重建同名容器。"
REST_SH
  chmod +x "$out"
}

#####################################
# 恢复模式
#####################################
restore_prompt_url() {
  local u="${1:-}"
  if [[ -z "$u" ]]; then
    read -rp "请输入旧服务器“一键包下载链接”（以 .tar.gz 结尾）： " u
  fi
  if ! [[ "$u" =~ \.tar\.gz($|\?) ]]; then
    RED "[ERR] 链接必须以 .tar.gz 结尾。"
    exit 1
  fi
  echo "$u"
}

restore_find_bundle_dir() {
  local outdir="$1" rid="$2"
  if [[ -d "${outdir}/${rid}" && -f "${outdir}/${rid}/restore.sh" ]]; then
    echo "${outdir}/${rid}"
    return 0
  fi
  local first
  first="$(find "$outdir" -maxdepth 2 -type f -name restore.sh -print | head -n1 || true)"
  [[ -n "$first" ]] && dirname "$first"
}

restore_ensure_deps() {
  local pm
  pm="$(pm_detect)"
  local pair bin pkg
  for pair in "curl curl" "tar tar" "jq jq" "docker docker"; do
    bin="${pair%% *}"
    pkg="${pair##* }"
    if ! command -v "$bin" >/dev/null 2>&1; then
      if [[ "$pm" == "none" ]]; then
        RED "[ERR] 缺少命令：$bin，请在新服务器安装该命令后重试。"
        exit 1
      fi
      if [[ "$bin" == "docker" ]]; then
        YEL "[INFO] 安装依赖：$bin（以及 docker compose）"
        case "$pm" in
          apt) pm_install "$pm" docker.io ;;
          dnf|yum|zypper|apk) pm_install "$pm" docker ;;
          *) pm_install "$pm" docker || true ;;
        esac
        if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
          case "$pm" in
            apt) pm_install "$pm" docker-compose-plugin || pm_install "$pm" docker-compose || true ;;
            dnf|yum|zypper|apk) pm_install "$pm" docker-compose || true ;;
            *) pm_install "$pm" docker-compose || true ;;
          esac
        fi
      else
        YEL "[INFO] 安装依赖：$bin"
        pm_install "$pm" "$pkg"
      fi
    fi
  done
  ensure_docker_running
}

restore_main() {
  restore_ensure_deps
  local URL
  URL="$(restore_prompt_url "${1:-}")"
  local BASE="${RESTORE_BASE:-$HOME/docker_migrate_restore}"
  mkdir -p "$BASE"
  local RID
  RID="$(basename "$URL" | sed 's/\.tar\.gz.*$//' | tr -dc 'A-Za-z0-9_-')"
  [[ -n "$RID" ]] || RID="$(date +%s)"
  local TGZ="${BASE}/bundle.tar.gz"
  local OUTDIR="${BASE}/${RID}"

  BLUE "[INFO] 下载：$URL"
  if ! curl -fL --progress-bar "$URL" -o "$TGZ"; then
    RED "[ERR] 下载失败：$URL"
    exit 1
  fi
  OK "[OK] 保存路径：$TGZ"
  BLUE "[INFO] 文件大小：$(du -h "$TGZ" | awk '{print $1}')"
  BLUE "[INFO] 解压到：$OUTDIR"
  mkdir -p "$OUTDIR"
  BLUE "[INFO] 正在解压压缩包（根据文件大小可能需要一段时间，请不要中断）..."
  if ! tar -xzf "$TGZ" -C "$OUTDIR"; then
    RED "[ERR] 解压失败，请检查磁盘空间或确认文件是否完整。"
    exit 1
  fi

  local BUNDLE_DIR
  BUNDLE_DIR="$(restore_find_bundle_dir "$OUTDIR" "$RID" || true)"
  if [[ -z "$BUNDLE_DIR" || ! -f "${BUNDLE_DIR}/restore.sh" ]]; then
    RED "[ERR] 未找到 restore.sh，解压内容异常：$OUTDIR"
    exit 1
  fi

  # 使用当前脚本内置的修复版 restore.sh 覆盖包内旧 restore.sh。
  write_bundle_restore_script "${BUNDLE_DIR}/restore.sh"

  BLUE "[INFO] 执行恢复脚本：${BUNDLE_DIR}/restore.sh"
  BLUE "[INFO] 该步骤会加载镜像、回灌卷和绑定目录，并启动容器，可能需要数分钟，请耐心等待..."
  set +e
  bash "${BUNDLE_DIR}/restore.sh"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    OK "[OK] 恢复完成！当前容器："
    docker ps --format ' {{.Names}}\t{{.Status}}\t{{.Ports}}'
    if [[ "${RESTORE_KEEP:-0}" == "1" ]]; then
      YEL "[INFO] 已按 RESTORE_KEEP=1 保留文件：$TGZ 与 $OUTDIR"
    else
      rm -rf "$TGZ" "$OUTDIR" 2>/dev/null || true
      OK "[OK] 已清理下载文件与临时目录"
    fi
    exit 0
  else
    RED "[ERR] 恢复脚本返回非零：$rc"
    YEL "[INFO] 为便于排查，默认保留文件：$TGZ 与 $OUTDIR"
    if [[ "${RESTORE_CLEAN_ALL:-0}" == "1" ]]; then
      YEL "[WARN] RESTORE_CLEAN_ALL=1：仍将强制删除文件"
      rm -rf "$TGZ" "$OUTDIR" 2>/dev/null || true
      OK "[OK] 已清理下载文件与临时目录"
    fi
    exit "$rc"
  fi
}

#####################################
# 模式选择：1) 备份并传输 2) 下载并恢复
#####################################
if [[ -t 0 ]]; then
  echo "请选择功能："
  echo " 1) 备份容器并传输"
  echo " 2) 下载备份并恢复"
  read -rp "请输入序号 [回车=1]：" MODE_PICK || true
  MODE_PICK="${MODE_PICK:-1}"
else
  MODE_PICK=1
fi

case "$MODE_PICK" in
  1) : ;;
  2) restore_main "$@"; exit 0 ;;
  *) RED "[ERR] 无效选择：${MODE_PICK}"; exit 1 ;;
esac

#####################################
# 依赖检测 / 安装
#####################################
PKGMGR="$(pm_detect)"
if [[ "$PKGMGR" == "none" ]]; then
  RED "[ERR] 未检测到 apt/dnf/yum/zypper/apk，请手动安装：docker jq python3 tar gzip curl"
  exit 1
fi

case "$PKGMGR" in
  apt)
    need_bin curl curl
    need_bin jq jq
    need_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    need_bin docker docker.io
    ;;
  yum|dnf)
    need_bin curl curl
    need_bin jq jq
    need_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    if ! command -v docker >/dev/null 2>&1; then
      pm_install "$PKGMGR" docker || pm_install "$PKGMGR" docker-ce || true
    fi
    ;;
  zypper)
    need_bin curl curl
    need_bin jq jq
    need_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    need_bin docker docker
    ;;
  apk)
    need_bin curl curl
    need_bin jq jq
    need_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    need_bin docker docker
    ;;
esac
ensure_docker_running

#####################################
# 参数解析
#####################################
NO_STOP=0
INCLUDE_LIST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-stop) NO_STOP=1; shift ;;
    --include=*) INCLUDE_LIST="${1#*=}"; shift ;;
    --include) shift; INCLUDE_LIST="${1:-}"; [[ $# -gt 0 ]] && shift || true ;;
    -h|--help)
      cat <<'HLP'
用法: bash docker_migrate_perfect.sh [--no-stop] [--include=name1,name2]

环境变量:
  PORT=8080             HTTP 端口（默认 8080；被占用会自动递增）
  ADVERTISE_HOST=IP     下载链接中使用的主机名/IP
  RESTORE_KEEP=1        恢复后保留文件
  RESTORE_CLEAN_ALL=1   恢复失败也强制删除文件
  RESTORE_BASE=/path    自定义恢复目录

说明:
- 在旧服务器上运行本脚本并选择〖1 备份容器并传输〗。
- 如不指定 --include，将进入交互式菜单：
  * 独立 docker 容器：每个容器一个序号
  * docker compose 容器组：同一个 compose 项目中的多个容器共享一个序号
- 只有一个容器的 compose 项目会按独立容器迁移，用 inspect 元数据还原端口。
- 打包完成后会启动 HTTP 服务并给出下载链接（带安全随机路径）。
- 在新服务器上运行本脚本并选择〖2 下载备份并恢复〗即可完成回迁。
HLP
      exit 0
      ;;
    *) RED "[ERR] 未知参数：$1"; exit 1 ;;
  esac
done

#####################################
# Bundle 路径与 ID
#####################################
DEFAULT_PORT="${PORT:-8080}"
PORT="$(pick_free_port "$DEFAULT_PORT")"
WORKDIR="$(pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
RID="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 10)"
BUNDLE_ROOT="${WORKDIR}/bundle"
BUNDLE="${BUNDLE_ROOT}/${RID}"
mkdir -p "${BUNDLE}"/{runs,volumes,binds,compose,meta}
BLUE "[INFO] Bundle 目录：${BUNDLE}"

#####################################
# 容器选择（支持 compose 分组）
#####################################
if [[ -n "$INCLUDE_LIST" ]]; then
  mapfile -t ALL_IDS < <(docker ps --format '{{.ID}}')
  ((${#ALL_IDS[@]})) || { RED "[ERR] 没有运行中的容器"; exit 1; }
  IFS=',' read -r -a NAMES <<<"$INCLUDE_LIST"
  for n in "${NAMES[@]}"; do
    n="$(echo "$n" | xargs)"
    [[ -z "$n" ]] && continue
    id=$(docker ps --filter "name=^${n}$" --format '{{.ID}}' | head -n1 || true)
    if [[ -n "$id" ]]; then
      IDS+=("$id")
    else
      YEL "[WARN] 未找到容器：$n"
    fi
  done
  ((${#IDS[@]})) || { RED "[ERR] --include 未匹配到任何容器"; exit 1; }
else
  mapfile -t PS_LINES < <(docker ps --format '{{.ID}} {{.Names}}')
  ((${#PS_LINES[@]})) || { RED "[ERR] 没有运行中的容器"; exit 1; }

  declare -a STANDALONE_IDS=()
  declare -a STANDALONE_NAMES=()
  declare -A NAME_OF_ID=()
  declare -A GROUP_IDS=()
  declare -A GROUP_LABELS=()
  declare -A GROUP_SEEN=()
  declare -a GROUP_KEYS=()

  for line in "${PS_LINES[@]}"; do
    id="${line%% *}"
    cname="${line#* }"
    [[ -z "$cname" || "$cname" == "$id" ]] && cname="$id"
    NAME_OF_ID["$id"]="$cname"

    j="$(docker inspect "$id")"
    proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
    wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")
    if [[ -n "$proj" && -n "$wdir" ]]; then
      key="${proj}|${wdir}"
      if [[ -z "${GROUP_SEEN[$key]:-}" ]]; then
        GROUP_SEEN["$key"]=1
        GROUP_IDS["$key"]="$id"
        GROUP_LABELS["$key"]="$cname"
        GROUP_KEYS+=("$key")
      else
        GROUP_IDS["$key"]="${GROUP_IDS[$key]} $id"
        GROUP_LABELS["$key"]="${GROUP_LABELS[$key]} $cname"
      fi
    else
      STANDALONE_IDS+=("$id")
      STANDALONE_NAMES+=("$cname")
    fi
  done

  # 关键修复：只有一个容器的 compose 项目归类为“独立容器”。
  # 这样 danmu_api 这类单容器项目会走 docker run 恢复路径，从 inspect 还原 -p 端口。
  if ((${#GROUP_KEYS[@]})); then
    declare -a TRUE_GROUP_KEYS=()
    for key in "${GROUP_KEYS[@]}"; do
      cnt=0
      for cid in ${GROUP_IDS[$key]}; do cnt=$((cnt + 1)); done
      if (( cnt > 1 )); then
        TRUE_GROUP_KEYS+=("$key")
      else
        for cid in ${GROUP_IDS[$key]}; do
          STANDALONE_IDS+=("$cid")
          STANDALONE_NAMES+=("${NAME_OF_ID[$cid]}")
        done
      fi
    done
    GROUP_KEYS=("${TRUE_GROUP_KEYS[@]}")
  fi

  declare -a MENU_KIND=()
  declare -a MENU_VAL=()
  idx=0
  if ((${#STANDALONE_IDS[@]})); then
    BLUE "独立 docker 容器："
    for i in "${!STANDALONE_IDS[@]}"; do
      idx=$((idx + 1))
      id="${STANDALONE_IDS[$i]}"
      name="${STANDALONE_NAMES[$i]}"
      printf " %2d) %s\n" "$idx" "$name"
      MENU_KIND[$idx]="single"
      MENU_VAL[$idx]="$id"
    done
    echo ""
  fi

  if ((${#GROUP_KEYS[@]})); then
    BLUE "docker compose 容器组："
    for key in "${GROUP_KEYS[@]}"; do
      idx=$((idx + 1))
      label_display=""
      for cname in ${GROUP_LABELS[$key]}; do label_display+="〖${cname}〗"; done
      printf " %2d) %s\n" "$idx" "$label_display"
      MENU_KIND[$idx]="compose"
      MENU_VAL[$idx]="$key"
    done
    echo ""
  fi

  if (( idx == 0 )); then
    RED "[ERR] 没有运行中的容器"
    exit 1
  fi

  read -rp "请输入要迁移的序号 [回车=全部 / 逗号分隔，如 1,3]： " PICK
  if [[ -z "$PICK" ]]; then
    IDS=("${STANDALONE_IDS[@]}")
    for key in "${GROUP_KEYS[@]}"; do
      for cid in ${GROUP_IDS[$key]}; do IDS+=("$cid"); done
    done
  else
    IFS=',' read -r -a INDEX_LIST <<<"$PICK"
    declare -A SEEN_ID=()
    for t in "${INDEX_LIST[@]}"; do
      t="$(echo "$t" | xargs)"
      [[ -z "$t" ]] && continue
      if ! [[ "$t" =~ ^[0-9]+$ ]]; then
        YEL "[WARN] 非法序号：$t"
        continue
      fi
      num="$t"
      if (( num < 1 || num > idx )); then
        YEL "[WARN] 序号越界：$t"
        continue
      fi
      kind="${MENU_KIND[$num]}"
      val="${MENU_VAL[$num]}"
      if [[ "$kind" == "single" ]]; then
        cid="$val"
        if [[ -z "${SEEN_ID[$cid]:-}" ]]; then
          SEEN_ID["$cid"]=1
          IDS+=("$cid")
        fi
      elif [[ "$kind" == "compose" ]]; then
        for cid in ${GROUP_IDS[$val]}; do
          if [[ -z "${SEEN_ID[$cid]:-}" ]]; then
            SEEN_ID["$cid"]=1
            IDS+=("$cid")
          fi
        done
      fi
    done
    ((${#IDS[@]})) || { RED "[ERR] 未选择任何容器"; exit 1; }
  fi
fi

#####################################
# 元数据采集
#####################################
BLUE "[INFO] 采集容器元数据 ..."
declare -A IMGSET=()
declare -A NETWORKS=()
declare -A CONTAINER_NAME=()
declare -A CONTAINER_IS_COMPOSE=()
declare -A PROJECT_KEY_OF=()
declare -A COMPOSE_GROUP=()
declare -A COMPOSE_CFGS=()
declare -A SINGLETONS=()
declare -A SELECTED_COMPOSE_COUNT=()

# 关键修复：重新按最终选择的容器统计 compose 分组数量，避免菜单阶段归类为单容器，元数据阶段又被重新归为 compose。
for id in "${IDS[@]}"; do
  jtmp="$(docker inspect "$id")"
  projtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$jtmp")
  wdirtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$jtmp")
  if [[ -n "$projtmp" && -n "$wdirtmp" ]]; then
    keytmp="${projtmp}|${wdirtmp}"
    SELECTED_COMPOSE_COUNT["$keytmp"]=$(( ${SELECTED_COMPOSE_COUNT["$keytmp"]:-0} + 1 ))
  fi
done

for id in "${IDS[@]}"; do
  j="$(docker inspect "$id")"
  name=$(jq -r '.[0].Name | ltrimstr("/")' <<<"$j")
  img=$(jq -r '.[0].Config.Image' <<<"$j")
  CONTAINER_NAME["$id"]="$name"
  IMGSET["$img"]=1

  proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
  wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")
  cfgs=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$j")
  key=""
  if [[ -n "$proj" && -n "$wdir" ]]; then
    key="${proj}|${wdir}"
  fi

  if [[ -n "$key" && "${SELECTED_COMPOSE_COUNT[$key]:-0}" -gt 1 ]]; then
    COMPOSE_GROUP["$key"]=1
    [[ -n "$cfgs" ]] && COMPOSE_CFGS["$key"]="$cfgs"
    PROJECT_KEY_OF["$id"]="$key"
    CONTAINER_IS_COMPOSE["$id"]=1
  else
    PROJECT_KEY_OF["$id"]=""
    CONTAINER_IS_COMPOSE["$id"]=0
    SINGLETONS["$name"]=1
    mapfile -t nets < <(jq -r '.[0].NetworkSettings.Networks | keys[]?' <<<"$j" || true)
    for n in "${nets[@]}"; do
      case "$n" in bridge|host|none) : ;; *) NETWORKS["$n"]=1 ;; esac
    done
  fi

  echo "$j" > "${BUNDLE}/meta/${name}.inspect.json"
done

#####################################
# 打包 Compose 配置（绝对/相对路径）
#####################################
if ((${#COMPOSE_GROUP[@]})); then
  BLUE "[INFO] 打包 docker compose 项目配置 ..."
  for key in "${!COMPOSE_GROUP[@]}"; do
    proj="${key%%|*}"
    wdir="${key#*|}"
    dest="${BUNDLE}/compose/${proj}"
    mkdir -p "$dest"
    cfgs="${COMPOSE_CFGS[$key]:-}"

    if [[ -n "$cfgs" ]]; then
      IFS=':' read -r -a CFG_ARR <<<"$cfgs"
      for cfg in "${CFG_ARR[@]}"; do
        cfg="${cfg#./}"
        [[ -z "$cfg" ]] && continue
        src=""
        if [[ "$cfg" == /* ]]; then
          src="$cfg"
        elif [[ -n "$wdir" ]]; then
          src="${wdir}/${cfg}"
        else
          src="$cfg"
        fi
        [[ -f "$src" ]] && cp -a "$src" "$dest/" 2>/dev/null || true
      done
    fi

    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env docker-compose.override.yml compose.override.yaml; do
      if [[ -n "$wdir" && -f "${wdir}/${f}" ]]; then
        cp -a "${wdir}/${f}" "$dest/" 2>/dev/null || true
      fi
    done
  done
fi

#####################################
# 停机窗口（可选）
#####################################
declare -a STOPPED_ON_BACKUP=()
if (( NO_STOP == 1 )); then
  YEL "[WARN] 使用 --no-stop：不停机备份，数据可能不一致（尤其数据库类容器）。"
else
  read -rp "是否现在停机以确保一致性备份？[Y/n] " STOPNOW
  STOPNOW=${STOPNOW:-Y}
  if [[ "$STOPNOW" =~ ^[Yy]$ ]]; then
    total_count=${#IDS[@]}
    idx=0
    for id in "${IDS[@]}"; do
      idx=$((idx + 1))
      n="${CONTAINER_NAME[$id]}"
      printf "[停机] (%d/%d) %s ..." "$idx" "$total_count" "$n"
      if docker stop "$n" >/dev/null 2>&1; then
        STOPPED_ON_BACKUP+=("$n")
        printf " ok\n"
      else
        printf " fail\n"
      fi
    done
  else
    YEL "[WARN] 你选择了不停机备份。"
  fi
fi

#####################################
# 备份卷与绑定目录
#####################################
BLUE "[INFO] 备份卷与绑定目录 ..."
BLUE "[INFO] 预拉取 alpine:3.20 镜像（用于卷操作）..."
docker pull alpine:3.20 >/dev/null 2>&1 || YEL "[WARN] 无法拉取 alpine:3.20，卷操作可能失败"
declare -a MAN_VOL=()
declare -a MAN_BIND=()
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
        printf " [VOL] (%d/%d) %s :: %s -> %s\n" "$v_idx" "$vol_count" "$n" "$vname" "$dest"
        mkdir -p "${BUNDLE}/volumes"
        out="${BUNDLE}/volumes/vol_${vname}.tgz"
        docker run --rm \
          -v "${vname}:/from:ro" \
          -v "${BUNDLE}/volumes:/to" \
          alpine:3.20 sh -c "cd /from && tar -czf /to/$(basename "$out") ." || {
            YEL " [WARN] 打包卷失败：$vname"
            continue
          }
        MAN_VOL+=("$(jq -cn --arg name "$vname" --arg dest "$dest" '{name:$name,dest:$dest}')")
        ;;
      bind)
        b_idx=$((b_idx + 1))
        src=$(jq -r '.Source' <<<"$m")
        esc=$(echo "$src" | sed 's#/#_#g' | sed 's/^_//')
        out="${BUNDLE}/binds/bind_${esc}.tgz"
        printf " [BIND] (%d/%d) %s :: %s -> %s\n" "$b_idx" "$bind_count" "$n" "$src" "$dest"
        mkdir -p "${BUNDLE}/binds"
        if ! tar -C / -czf "$out" "${src#/}" 2>/dev/null; then
          YEL " [WARN] 跳过不可读路径：$src"
          continue
        fi
        MAN_BIND+=("$(jq -cn --arg host "$src" --arg dest "$dest" --arg file "$(basename "$out")" '{host:$host,dest:$dest,file:$file}')")
        ;;
      *)
        YEL " [SKIP] 未处理的 mount 类型：$t (dest=$dest)"
        ;;
    esac
  done < <(jq -c '.[0].Mounts[]?' <<<"$j")
done

#####################################
# 生成独立容器 run 脚本
#####################################
if ((${#IDS[@]})); then
  BLUE "[INFO] 生成独立容器 run 脚本 ..."
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
  if progress_docker_save "${OUT_IMG}" docker image save "${IMAGES[@]}"; then
    OK "[OK] images.tar 已生成，大小：$(du -h "${OUT_IMG}" | awk '{print $1}')"
  else
    RED "[ERR] docker image save 失败，请检查磁盘空间或 Docker 状态。"
  fi
else
  YEL "[WARN] 未收集到镜像名（可能是只用了本地 none 镜像）。"
fi

#####################################
# 生成 manifest.json 与 restore.sh
#####################################
generate_manifest_and_restore() {
  mapfile -t NETLIST2 < <(printf "%s\n" "${!NETWORKS[@]}" | awk 'NF' | sort -u)
  declare -a MAN_PROJECTS=()
  local key
  for key in "${!COMPOSE_GROUP[@]}"; do
    local proj="${key%%|*}"
    local wdir="${key#*|}"
    local files_json="[]"
    if [[ -d "${BUNDLE}/compose/${proj}" ]]; then
      mapfile -t FLS < <(find "${BUNDLE}/compose/${proj}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort || true)
      if ((${#FLS[@]})); then
        files_json="$(json_array_from_lines "${FLS[@]}")"
      fi
    fi
    MAN_PROJECTS+=("$(jq -cn --arg name "$proj" --arg working_dir "$wdir" --argjson files "$files_json" '{name:$name,working_dir:$working_dir,files:$files}')")
  done

  local images_json nets_json projects_json vols_json binds_json runs_json
  # 使用正确的 bash 数组展开语法，避免空数组产生空字符串参数
  images_json="$(json_array_from_lines ${IMAGES[@]+"${IMAGES[@]}"})"
  nets_json="$(json_array_from_lines ${NETLIST2[@]+"${NETLIST2[@]}"})"
  runs_json="$(json_array_from_lines ${RUNS[@]+"${RUNS[@]}"})"

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
    --arg script_version "direct-fixed-2026-05-11" \
    --argjson images "$images_json" \
    --argjson networks "$nets_json" \
    --argjson projects "$projects_json" \
    --argjson volumes "$vols_json" \
    --argjson binds "$binds_json" \
    --argjson runs "$runs_json" \
    '{created_at:$created_at,script_version:$script_version,images:$images,networks:$networks,projects:$projects,volumes:$volumes,binds:$binds,runs:$runs}' \
    > "${BUNDLE}/manifest.json"

  write_bundle_restore_script "${BUNDLE}/restore.sh"

  cat > "${BUNDLE}/README.txt" <<README
Docker 迁移包
生成时间：${STAMP}

恢复方法：
1. 新服务器运行同一份 docker_migrate_perfect.sh，选择 2，然后粘贴下载链接；或
2. 手动解压本包后，在包目录执行：bash restore.sh

本版修复端口丢失问题：
- 单容器 compose 项目会以独立容器方式迁移。
- 已存在同名容器但端口绑定不一致时，恢复脚本会删除并重建容器。
README
}

generate_manifest_and_restore

#####################################
# 打包成单文件 tar.gz
#####################################
BUNDLE_BASENAME="docker_migrate_${STAMP}_${RID}"
SINGLE_TAR_PATH="${BUNDLE_ROOT}/${BUNDLE_BASENAME}.tar.gz"
BLUE "[INFO] 打包一键迁移包：${SINGLE_TAR_PATH}"
(
  cd "$BUNDLE_ROOT"
  tar -czf "${BUNDLE_BASENAME}.tar.gz" "$RID"
)
OK "[OK] 一键迁移包已生成，大小：$(du -h "$SINGLE_TAR_PATH" | awk '{print $1}')"

#####################################
# HTTP 下载服务
#####################################
if [[ -t 0 ]]; then
  echo ""
  read -rp "HTTP 下载端口 [回车=${PORT}]： " IN_PORT || true
  if [[ -n "${IN_PORT:-}" ]]; then
    if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && (( IN_PORT >= 1 && IN_PORT <= 65535 )); then
      NEW_PORT="$(pick_free_port "$IN_PORT")"
      if [[ "$NEW_PORT" != "$IN_PORT" ]]; then
        YEL "[WARN] 端口 ${IN_PORT} 已占用，改用临近可用端口：${NEW_PORT}"
      fi
      PORT="$NEW_PORT"
    else
      YEL "[WARN] 输入端口无效，继续使用默认端口：${PORT}"
    fi
  fi
fi

SECRET_TOKEN="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
BASE_URL="$(pick_advertise_url "$PORT")"
FINAL_URL="${BASE_URL}/${SECRET_TOKEN}/${BUNDLE_BASENAME}.tar.gz"

BLUE "[INFO] 启动 HTTP 服务（端口 ${PORT}，仅允许路径 /${SECRET_TOKEN}/${BUNDLE_BASENAME}.tar.gz）"
SHPID=""

cleanup_http() {
  if [[ -n "${SHPID:-}" ]]; then
    kill "${SHPID}" 2>/dev/null || true
  fi
}

hard_clean() {
  rm -rf "${BUNDLE}" 2>/dev/null || true
  rm -f "${SINGLE_TAR_PATH}" 2>/dev/null || true
  OK "[OK] 已清理 bundle 目录及单文件包"
}

graceful_exit() {
  local rc="${1:-0}"
  echo ""
  YEL "[INFO] 即将退出，先关闭 HTTP 服务 ..."
  cleanup_http
  if ((${#STOPPED_ON_BACKUP[@]})); then
    BLUE "[INFO] 重启本次停机的容器（共 ${#STOPPED_ON_BACKUP[@]} 个） ..."
    local ok=0 fail=0 n
    for n in "${STOPPED_ON_BACKUP[@]}"; do
      printf " - starting: %s ... " "$n"
      if docker start "$n" >/dev/null 2>&1; then
        printf "ok\n"
        ok=$((ok + 1))
      else
        printf "fail\n"
        fail=$((fail + 1))
      fi
    done
    OK "[OK] 重启完成：成功 ${ok} / 失败 ${fail}"
  else
    YEL "[INFO] 本次未停任何容器，无需重启。"
  fi
  YEL "[INFO] 清理打包产物 ..."
  hard_clean
  exit "$rc"
}
trap 'graceful_exit 130' INT TERM

HTTP_LOG="${BUNDLE_ROOT}/http_server_${RID}.log"
cd "${BUNDLE_ROOT}" || exit 1
python3 - "$PORT" "$SECRET_TOKEN" "$BUNDLE_BASENAME" >"${HTTP_LOG}" 2>&1 <<'PY' &
import http.server
import os
import socketserver
import sys

port = int(sys.argv[1])
secret = sys.argv[2]
bundle_basename = sys.argv[3]
fname = bundle_basename + ".tar.gz"
allowed_path = "/" + secret + "/" + fname
root = os.getcwd()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        if path != allowed_path:
            self.send_response(404)
            self.end_headers()
            return
        fpath = os.path.join(root, fname)
        try:
            st = os.stat(fpath)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(st.st_size))
        self.end_headers()
        with open(fpath, "rb") as f:
            while True:
                chunk = f.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def log_message(self, format, *args):
        return

with socketserver.TCPServer(("", port), Handler) as httpd:
    httpd.serve_forever()
PY
SHPID=$!
cd "$WORKDIR"
sleep 1

if ! kill -0 "$SHPID" 2>/dev/null; then
  RED "[ERR] HTTP 服务启动失败，请检查端口 ${PORT}、防火墙或运行日志：${HTTP_LOG}"
  if [[ -f "${HTTP_LOG}" ]]; then tail -n 20 "${HTTP_LOG}" || true; fi
  graceful_exit 1
fi

OK "[OK] 一键迁移包下载链接：${FINAL_URL}"
YEL "[WARN] HTTP 为明文传输，请仅在可信网络使用。"
YEL "[INFO] HTTP 服务日志：${HTTP_LOG}"

if [[ -t 0 ]]; then
  read -rp $' 按回车键停止 HTTP 并退出（将自动重启停机容器并清理产物）...' _
  graceful_exit 0
else
  YEL "[INFO] 当前为非交互模式，HTTP 服务将保持运行；请在下载完成后手动结束本脚本。"
  wait "$SHPID" || true
  graceful_exit 0
fi
