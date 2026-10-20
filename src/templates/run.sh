#!/usr/bin/env bash
set -euo pipefail
umask 077

BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
META="${BUNDLE_DIR}/meta/__NAME__.inspect.json"

# @include lib/log.sh

# @include lib/screen.sh

# @include lib/errors.sh

# @include lib/progress.sh

# @include lib/containers.sh

# @include lib/decisions.sh

dm_capture_command() {
  local output_file="$1"
  shift
  "$@" >"$output_file" 2>&1
}

if [[ ! -f "$META" ]]; then
  error_user "迁移包缺少容器 __NAME__ 的配置文件" "请在旧服务器重新运行备份"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  error_user "恢复容器 __NAME__ 需要 jq" "安装 jq 后重试"
  exit 1
fi

resolve_container_mode() {
  local mode="$1"
  local ref f cid2 cname
  [[ "$mode" == container:* ]] || {
    printf '%s\n' "$mode"
    return 0
  }
  ref="${mode#container:}"
  [[ "$ref" =~ ^[0-9a-f]{12,}$ ]] || {
    printf '%s\n' "$mode"
    return 0
  }
  for f in "${BUNDLE_DIR}"/meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    cid2="$(jq -r '.[0].Id' "$f")"
    if [[ "$cid2" == "$ref" || "${cid2:0:12}" == "$ref" ]]; then
      cname="$(jq -r '.[0].Name | ltrimstr("/")' "$f")"
      printf 'container:%s\n' "$cname"
      return 0
    fi
  done
  log_line "依附的容器 ${ref:0:12} 不在迁移包中"
  fail_reason "依附的容器 ${ref:0:12} 不在迁移包中" "请在旧服务器把它和依附它的容器一起迁移"
  printf '%s\n' "$mode"
}

decode_base64() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    base64 -D
  else
    base64 -d
  fi
}

name="$(jq -r '.[0].Name | ltrimstr("/")' "$META")"
image="$(jq -r '.[0].Config.Image' "$META")"
if [[ -z "$name" || -z "$image" || "$image" == "null" ]]; then
  error_user "容器 __NAME__ 的配置文件无效" "请在旧服务器重新运行备份"
  exit 1
fi

replacement_backup_name=""
replacement_original_state=""
replacement_networks_file=""
replacement_active=0
transaction_mode=0
if [[ -n "${RESTORE_TRANSACTION_DIR:-}" && -d "${RESTORE_TRANSACTION_DIR}" ]]; then
  transaction_mode=1
fi

disconnect_container_networks() {
  local container="$1" metadata_file="$2" network
  while IFS= read -r network; do
    case "$network" in "" | host | none) continue ;; esac
    dm_quiet docker network disconnect -f "$network" "$container" || return 1
  done < <(jq -r 'keys[]?' "$metadata_file")
}

restore_previous_container() {
  ((replacement_active == 1)) || return 0
  log_line "新容器 ${name} 未能通过验证，删除它并还原旧容器"
  dm_quiet docker rm -f "$name" || true
  if ((transaction_mode == 1)); then
    # 数据必须先由主恢复脚本回滚；旧容器在那之后才会改回原名并恢复状态。
    replacement_active=0
    return 0
  fi
  if ! rename_container_with_retry "$replacement_backup_name" "$name"; then
    warn_user "旧容器自动还原失败，它目前的名称是 ${replacement_backup_name}"
    return 1
  fi
  if ! restore_container_networks "$name" "$replacement_networks_file"; then
    warn_user "旧容器 ${name} 已改回原名，但网络没有完全重新连接"
    return 1
  fi
  case "$replacement_original_state" in
    running | restarting)
      dm_quiet docker start "$name" || return 1
      ;;
    paused)
      dm_quiet docker start "$name" || return 1
      dm_quiet docker pause "$name" || return 1
      ;;
  esac
  replacement_active=0
  log_line "旧容器已还原：${name}"
}

replacement_exit_handler() {
  local rc=$?
  trap - EXIT
  if ((rc != 0 && replacement_active == 1)); then
    restore_previous_container || rc=1
  fi
  if ((transaction_mode == 0)) && [[ -n "$replacement_networks_file" ]]; then
    rm -f "$replacement_networks_file" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap replacement_exit_handler EXIT

if ! docker image inspect "$image" >/dev/null 2>&1; then
  detail "镜像 ${image} 不在本机，先在线拉取（此时还没有改动已有容器）"
  DM_PROGRESS_HINT="正在从镜像仓库下载，网络较慢时可能需要几分钟" \
    run_with_activity "拉取镜像 ${image}" dm_quiet docker pull "$image" || {
    fail_with_output "容器 ${name} 的镜像 ${image} 拉取失败（已有容器保持不变）" "$(log_tail_text 10)"
    exit 1
  }
fi

if docker container inspect "$name" >/dev/null 2>&1; then
  existing_state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
  if ((transaction_mode == 1)) && [[ -f "${RESTORE_TRANSACTION_DIR}/standalone.tsv" ]]; then
    transaction_state="$(awk -F '\t' -v name="$name" '$1 == name && $2 == "1" { print $3; exit }' \
      "${RESTORE_TRANSACTION_DIR}/standalone.tsv")"
    [[ -z "$transaction_state" ]] || existing_state="$transaction_state"
  fi
  case "${RESTORE_EXISTING:-replace}" in
    replace)
      detail "新服务器已有同名容器 ${name}，替换它以恢复完整配置（失败时会还原）"
      replacement_original_state="$existing_state"
      replacement_backup_name="${name}.docker-migrate-backup-$$"
      if docker container inspect "$replacement_backup_name" >/dev/null 2>&1; then
        error_user "回滚用的容器名 ${replacement_backup_name} 已被占用" "删除或重命名这个容器后重试"
        exit 1
      fi
      if ((transaction_mode == 1)); then
        mkdir -p "${RESTORE_TRANSACTION_DIR}/standalone_networks"
        replacement_networks_file="${RESTORE_TRANSACTION_DIR}/standalone_networks/${name}.json"
      else
        replacement_networks_file="$(mktemp "${TMPDIR:-/tmp}/docker-migrate-networks.XXXXXX")" || exit 1
      fi
      if ! docker inspect "$name" | jq '.[0].NetworkSettings.Networks // {}' \
        >"$replacement_networks_file"; then
        error_user "无法记录已有容器 ${name} 的网络配置（已有容器保持不变）"
        exit 1
      fi
      if ((transaction_mode == 1)); then
        # Write-ahead：旧容器 rename 前先登记回滚名称；登记失败时尚未改动目标。
        printf '%s\t%s\t%s\n' "$name" "$replacement_backup_name" "$replacement_original_state" \
          >>"${RESTORE_TRANSACTION_DIR}/standalone_backups.tsv" || exit 1
      fi
      [[ "$existing_state" == "paused" ]] && dm_quiet docker unpause "$name" || true
      case "$existing_state" in
        running | restarting | paused)
          run_with_activity "停止已有容器 ${name}" dm_quiet docker stop "$name" || {
            fail_with_output "无法停止已有容器 ${name}（它保持不变）" "$(log_tail_text 10)"
            exit 1
          }
          ;;
      esac
      dm_quiet docker rename "$name" "$replacement_backup_name" || {
        fail_with_output "无法先备份已有容器 ${name}（它保持不变）" "$(log_tail_text 10)"
        exit 1
      }
      replacement_active=1
      if ! disconnect_container_networks "$replacement_backup_name" "$replacement_networks_file"; then
        fail_with_output "无法释放已有容器 ${name} 占用的网络地址" "$(log_tail_text 10)"
        exit 1
      fi
      ;;
    skip)
      warn_user "容器 ${name} 已存在，按 RESTORE_EXISTING=skip 保持不变"
      exit 0
      ;;
    fail)
      error_user "容器 ${name} 已存在（RESTORE_EXISTING=fail 不允许替换）" "删除这个容器，或改用 RESTORE_EXISTING=replace"
      exit 1
      ;;
    *)
      error_user "RESTORE_EXISTING 的值无效：${RESTORE_EXISTING}" "可用的值是 replace、skip 或 fail"
      exit 1
      ;;
  esac
fi

original_running="$(jq -r '.[0].State.Running // false' "$META")"
original_paused="$(jq -r '.[0].State.Paused // false' "$META")"
if [[ "$original_running" == "true" ]]; then
  args=(docker run -d --name "$name")
else
  args=(docker create --name "$name")
fi
cmd_args=()

mapfile -t entrypoint < <(jq -r '.[0].Config.Entrypoint[]?' "$META")
mapfile -t cmd < <(jq -r '.[0].Config.Cmd[]?' "$META")
# docker run --entrypoint 只能写一段：多段的入口（如 dumb-init -- entrypoint.sh）
# 会被拆进命令里，配置就和原来不一样了，镜像更新后命令也会被固定住。
# 和镜像默认值相同的部分不传，由镜像自己提供。
image_entry_cmd="$(docker image inspect "$image" 2>/dev/null |
  jq -c '.[0].Config | [.Entrypoint // [], .Cmd // []]' 2>/dev/null || echo null)"
container_entry_cmd="$(jq -c '.[0].Config | [.Entrypoint // [], .Cmd // []]' "$META")"
if [[ "$image_entry_cmd" != "null" ]] &&
  [[ "$(jq -c '.[0]' <<<"$image_entry_cmd")" == "$(jq -c '.[0]' <<<"$container_entry_cmd")" ]]; then
  entrypoint=()
  if [[ "$(jq -c '.[1]' <<<"$image_entry_cmd")" == "$(jq -c '.[1]' <<<"$container_entry_cmd")" ]]; then
    cmd=()
  fi
fi
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

# 共享 host 或其他容器的网络命名空间时，hostname、DNS、hosts 与端口都继承自
# 宿主机/被依附容器：inspect 里记录的是对方的值，再传给 docker run 会被拒绝
# （conflicting options: hostname and the network mode）或在新服务器上失真。
raw_network_mode="$(jq -r '.[0].HostConfig.NetworkMode // empty' "$META")"
netns_shared=""
case "$raw_network_mode" in
  host) netns_shared="host" ;;
  container:*) netns_shared="container" ;;
esac

cid="$(jq -r '.[0].Id' "$META")"
default_host="${cid:0:12}"
hostname="$(jq -r '.[0].Config.Hostname // empty' "$META")"
if [[ -z "$netns_shared" && -n "$hostname" && "$hostname" != "$default_host" ]]; then
  args+=(--hostname "$hostname")
fi

domainname="$(jq -r '.[0].Config.Domainname // empty' "$META")"
[[ -n "$netns_shared" || -z "$domainname" ]] || args+=(--domainname "$domainname")

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

# --- 设备映射: --device ---
mapfile -t devices < <(jq -r '.[0].HostConfig.Devices[]? | "\(.PathOnHost):\(.PathInContainer)\(if .CgroupPermissions then ":\(.CgroupPermissions)" else "" end)"' "$META")
for d in "${devices[@]}"; do args+=(--device "$d"); done

# --- 资源限制: --memory, --cpus, --shm-size ---
shm_size="$(jq -r '.[0].HostConfig.ShmSize // 0' "$META")"
if [[ "$shm_size" != "0" && "$shm_size" != "null" ]]; then args+=(--shm-size "${shm_size}b"); fi

mem="$(jq -r '.[0].HostConfig.Memory // 0' "$META")"
if [[ "$mem" != "0" && "$mem" != "null" ]]; then args+=(--memory "$mem"); fi

mem_swap="$(jq -r '.[0].HostConfig.MemorySwap // 0' "$META")"
if [[ "$mem_swap" != "0" && "$mem_swap" != "null" ]]; then args+=(--memory-swap "$mem_swap"); fi

mem_res="$(jq -r '.[0].HostConfig.MemoryReservation // 0' "$META")"
if [[ "$mem_res" != "0" && "$mem_res" != "null" ]]; then args+=(--memory-reservation "$mem_res"); fi

nano_cpus="$(jq -r '.[0].HostConfig.NanoCpus // 0' "$META")"
if [[ "$nano_cpus" != "0" && "$nano_cpus" != "null" ]]; then
  cpus="$(awk -v n="$nano_cpus" 'BEGIN { printf "%.9g", n / 1000000000 }')"
  args+=(--cpus "$cpus")
fi

cpu_shares="$(jq -r '.[0].HostConfig.CpuShares // 0' "$META")"
if [[ "$cpu_shares" != "0" && "$cpu_shares" != "null" ]]; then args+=(--cpu-shares "$cpu_shares"); fi

cpu_period="$(jq -r '.[0].HostConfig.CpuPeriod // 0' "$META")"
if [[ "$cpu_period" != "0" && "$cpu_period" != "null" ]]; then args+=(--cpu-period "$cpu_period"); fi

cpu_quota="$(jq -r '.[0].HostConfig.CpuQuota // 0' "$META")"
if [[ "$cpu_quota" != "0" && "$cpu_quota" != "null" ]]; then args+=(--cpu-quota "$cpu_quota"); fi

cpuset_cpus="$(jq -r '.[0].HostConfig.CpusetCpus // empty' "$META")"
[[ -n "$cpuset_cpus" ]] && args+=(--cpuset-cpus "$cpuset_cpus")

cpuset_mems="$(jq -r '.[0].HostConfig.CpusetMems // empty' "$META")"
[[ -n "$cpuset_mems" ]] && args+=(--cpuset-mems "$cpuset_mems")

oom_kill_disable="$(jq -r '.[0].HostConfig.OomKillDisable // false' "$META")"
[[ "$oom_kill_disable" == "true" ]] && args+=(--oom-kill-disable)

# --- 命名空间模式: --pid, --ipc, --uts ---
pid_mode="$(jq -r '.[0].HostConfig.PidMode // empty' "$META")"
if [[ -n "$pid_mode" && "$pid_mode" != "null" ]]; then
  pid_mode="$(resolve_container_mode "$pid_mode")"
  args+=(--pid "$pid_mode")
fi

ipc_mode="$(jq -r '.[0].HostConfig.IpcMode // empty' "$META")"
if [[ -n "$ipc_mode" && "$ipc_mode" != "null" ]]; then
  ipc_mode="$(resolve_container_mode "$ipc_mode")"
  args+=(--ipc "$ipc_mode")
fi

uts_mode="$(jq -r '.[0].HostConfig.UTSMode // empty' "$META")"
if [[ -n "$uts_mode" && "$uts_mode" != "null" && "$uts_mode" != "default" ]]; then
  args+=(--uts "$uts_mode")
fi

# --- 健康检查: 正确区分 NONE / CMD / CMD-SHELL ---
# 镜像（含 docker commit 生成的快照镜像）已带有相同的健康检查时不再传参：
# docker run 只能表达 CMD-SHELL，把 exec 形式的 CMD 改写成 shell 形式会让
# 没有 /bin/sh 的镜像（如 distroless）健康检查永远失败。
hc_kind="$(jq -r '.[0].Config.Healthcheck.Test[0] // empty' "$META" 2>/dev/null || true)"
meta_hc="$(jq -cS '.[0].Config.Healthcheck // null' "$META" 2>/dev/null || echo null)"
image_hc="$(docker image inspect "$image" 2>/dev/null | jq -cS '.[0].Config.Healthcheck // null' 2>/dev/null || echo null)"
if [[ "$meta_hc" == "$image_hc" ]]; then
  :
elif [[ "$hc_kind" == "NONE" ]]; then
  args+=(--no-healthcheck)
elif [[ "$hc_kind" == "CMD" || "$hc_kind" == "CMD-SHELL" ]]; then
  if [[ "$hc_kind" == "CMD-SHELL" ]]; then
    hc_test="$(jq -r '.[0].Config.Healthcheck.Test[1] // empty' "$META")"
  else
    hc_test="$(jq -r '.[0].Config.Healthcheck.Test[1:] | map(@sh) | join(" ")' "$META")"
    warn_user "容器 ${name} 的健康检查改写为 shell 形式（镜像需要包含 /bin/sh）：${hc_test}"
  fi
  hc_interval="$(jq -r '.[0].Config.Healthcheck.Interval // 30000000000' "$META")"
  hc_timeout="$(jq -r '.[0].Config.Healthcheck.Timeout // 30000000000' "$META")"
  hc_retries="$(jq -r '.[0].Config.Healthcheck.Retries // 3' "$META")"
  hc_start_period="$(jq -r '.[0].Config.Healthcheck.StartPeriod // 0' "$META")"
  hc_start_interval="$(jq -r '.[0].Config.Healthcheck.StartInterval // 5000000000' "$META")"
  args+=(--health-cmd "$hc_test")
  args+=(--health-interval "${hc_interval}ns")
  args+=(--health-timeout "${hc_timeout}ns")
  args+=(--health-retries "$hc_retries")
  [[ "$hc_start_period" != "0" ]] && args+=(--health-start-period "${hc_start_period}ns")
  if [[ "$hc_start_interval" != "0" ]] && docker run --help 2>/dev/null | grep -q -- '--health-start-interval'; then
    args+=(--health-start-interval "${hc_start_interval}ns")
  fi
fi

# --- runtime: --runtime (例如 nvidia) ---
runtime="$(jq -r '.[0].HostConfig.Runtime // empty' "$META")"
if [[ -n "$runtime" && "$runtime" != "null" && "$runtime" != "runc" ]]; then
  args+=(--runtime "$runtime")
fi

# --- --group-add ---
mapfile -t group_add < <(jq -r '.[0].HostConfig.GroupAdd[]?' "$META")
for g in "${group_add[@]}"; do args+=(--group-add "$g"); done

# --- storage opt: --storage-opt ---
mapfile -t storage_opts < <(jq -r '.[0].HostConfig.StorageOpt // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for s in "${storage_opts[@]}"; do args+=(--storage-opt "$s"); done

if [[ "$netns_shared" != "container" ]]; then
  mapfile -t extra_hosts < <(jq -r '.[0].HostConfig.ExtraHosts[]?' "$META")
  for h in "${extra_hosts[@]}"; do args+=(--add-host "$h"); done

  mapfile -t dns_list < <(jq -r '.[0].HostConfig.Dns[]?' "$META")
  for d in "${dns_list[@]}"; do args+=(--dns "$d"); done
  mapfile -t dns_search < <(jq -r '.[0].HostConfig.DnsSearch[]?' "$META")
  for d in "${dns_search[@]}"; do args+=(--dns-search "$d"); done
  mapfile -t dns_opts < <(jq -r '.[0].HostConfig.DnsOptions[]?' "$META")
  for d in "${dns_opts[@]}"; do args+=(--dns-option "$d"); done
fi

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
if [[ "$publish_all" == "true" && -z "$netns_shared" ]]; then
  args+=(-P)
fi

# 关键修复：稳健还原 PortBindings。
# 旧脚本在 HostPort 为空或 IPv6 HostIp 场景下容易生成无效 -p；这里跳过空 HostPort，并给 IPv6 加 []。
port_bindings=()
# host 网络下端口直接暴露在宿主机，container 网络下端口属于被依附容器；
# 两种模式都不能（也无需）再 -p 发布。
if [[ -z "$netns_shared" ]]; then
  mapfile -t port_bindings < <(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[]? | .key as $c | .value[]? | "\(.HostIp // "")|\(.HostPort // "")|\($c)"' "$META")
fi
published_ports=()
for p in "${port_bindings[@]}"; do
  host_ip="${p%%|*}"
  rest="${p#*|}"
  host_port="${rest%%|*}"
  cont_port="${rest#*|}"

  # 空 HostPort 是 Docker 随机端口分配（如 -p 80 或 -p 0.0.0.0::80），保留空 HostPort 让 Docker 重新随机分配
  [[ -z "$cont_port" ]] && continue

  # 迁移前预检中选择了换端口或不对外开放时，按选择调整。
  if [[ -n "$host_port" ]] &&
    decided_port="$(decision_port "$name" "$host_ip" "$host_port" "${cont_port%%/*}" "$([[ "$cont_port" == */* ]] && echo "${cont_port#*/}" || echo tcp)")"; then
    if [[ -z "$decided_port" ]]; then
      detail "端口 ${host_port} 按预检时的选择不再对外开放"
      continue
    fi
    detail "端口按预检时的选择改为：${host_port} -> ${decided_port}"
    host_port="$decided_port"
  fi

  if [[ -z "$host_port" || "$host_port" == "null" ]]; then
    # 随机端口：格式为 -p [ip::]containerPort[/proto]
    host_port=""
  fi

  if [[ -n "$host_ip" && "$host_ip" != "0.0.0.0" ]]; then
    if [[ "$host_ip" == *:* ]]; then
      port_binding="[${host_ip}]:${host_port}:${cont_port}"
    else
      port_binding="${host_ip}:${host_port}:${cont_port}"
    fi
  else
    port_binding="${host_port}:${cont_port}"
  fi
  args+=(-p "$port_binding")
  published_ports+=("$port_binding")
  detail "端口映射：${host_ip:-0.0.0.0}:${host_port} -> ${cont_port}"
done

mapfile -t mounts < <(jq -r '.[0].Mounts[]? | @base64' "$META")
for m in "${mounts[@]}"; do
  _jq() { echo "$m" | decode_base64 | jq -r "$1"; }
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
    # Mode 里的 ro/rw 与 RW 字段重复；读写属性统一由 RW 决定，否则会生成
    # Docker 拒绝的 ro,ro。
    for part in "${mode_parts[@]}"; do
      case "$part" in "" | ro | rw) ;; *) opts+=("$part") ;; esac
    done
  fi
  [[ "$rw" != "true" ]] && opts+=(ro)
  if ((${#opts[@]})); then
    optstr="$(
      IFS=,
      echo "${opts[*]}"
    )"
    args+=(-v "${src}:${dest}:${optstr}")
  else
    args+=(-v "${src}:${dest}")
  fi
done

network_mode="$(jq -r '.[0].HostConfig.NetworkMode // empty' "$META")"
network_mode="$(resolve_container_mode "$network_mode")"

primary_net=""
if [[ -n "$network_mode" && "$network_mode" != "default" && "$network_mode" != "bridge" ]]; then
  args+=(--network "$network_mode")
  primary_net="$network_mode"
else
  primary_net="bridge"
fi

if [[ "$primary_net" != "bridge" && "$primary_net" != "host" &&
  "$primary_net" != "none" && "$primary_net" != container:* ]]; then
  # 只还原用户显式指定的静态 IP（IPAMConfig）。Docker 动态分配的地址若被
  # 固定下来，会与目标端同网络的其他容器冲突，也改变了原有配置。
  primary_ip="$(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].IPAMConfig.IPv4Address // empty' "$META")"
  primary_ip6="$(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].IPAMConfig.IPv6Address // empty' "$META")"
  if decision_auto_ip "$name" "$primary_net"; then
    detail "网络 ${primary_net} 中按预检时的选择改为自动分配 IP"
    primary_ip=""
    primary_ip6=""
  fi
  [[ -z "$primary_ip" ]] || args+=(--ip "$primary_ip")
  [[ -z "$primary_ip6" ]] || args+=(--ip6 "$primary_ip6")
  mapfile -t primary_aliases < <(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].Aliases[]? // empty' "$META")
  for primary_alias in "${primary_aliases[@]}"; do
    [[ -z "$primary_alias" || "$primary_alias" == "$name" ]] || args+=(--network-alias "$primary_alias")
  done
fi

args+=("$image")
if ((${#cmd_args[@]})); then
  args+=("${cmd_args[@]}")
fi

run_output=""
run_log="$(mktemp "${TMPDIR:-/tmp}/docker-migrate-run.XXXXXX")" || exit 1
set +e
log_line "\$ ${args[*]}"
run_with_activity "${name}" dm_capture_command "$run_log" "${args[@]}"
run_rc=$?
set -e
run_output="$(cat "$run_log")"
rm -f "$run_log"

if [[ $run_rc -ne 0 ]]; then
  log_line "容器 ${name} 创建失败（退出码 ${run_rc}）：${run_output}"
  ((${#published_ports[@]} == 0)) || log_line "本次尝试绑定的端口：${published_ports[*]}"
  fail_with_output "容器 ${name} 创建失败" "$run_output"
  exit "$run_rc"
fi

# 连接额外网络。
network_restore_failed=0
if [[ "$network_mode" != "host" && "$network_mode" != "none" && "$network_mode" != container:* ]]; then
  mapfile -t net_entries < <(jq -r '.[0].NetworkSettings.Networks | to_entries[]? | @base64' "$META")
  for entry in "${net_entries[@]}"; do
    _net() { echo "$entry" | decode_base64 | jq -r "$1"; }
    net_name="$(_net '.key')"
    [[ -z "$net_name" || "$net_name" == "$primary_net" || "$net_name" == "bridge" ]] && continue
    ip="$(_net '.value.IPAMConfig.IPv4Address // empty')"
    ip6="$(_net '.value.IPAMConfig.IPv6Address // empty')"
    aliases_raw="$(_net '.value.Aliases // empty | join(" ")')"
    conn_args=()
    if decision_auto_ip "$name" "$net_name"; then
      ip=""
      ip6=""
    fi
    [[ -n "$ip" && "$ip" != "null" ]] && conn_args+=(--ip "$ip")
    [[ -n "$ip6" && "$ip6" != "null" ]] && conn_args+=(--ip6 "$ip6")
    if [[ -n "$aliases_raw" && "$aliases_raw" != "null" ]]; then
      for a in $aliases_raw; do conn_args+=(--alias "$a"); done
    fi
    dm_quiet docker network connect "${conn_args[@]}" "$net_name" "$name" || {
      network_restore_failed=1
      fail_with_output "容器 ${name} 无法连接网络 ${net_name}" "$(log_tail_text 10)" \
        "macvlan、ipvlan、overlay 网络需要先在新服务器手动创建"
    }
  done
fi
if ((network_restore_failed == 1)); then
  exit 1
fi

# 运行中的源容器必须通过启动验证，避免“docker run -d 成功但进程随即退出”后
# 过早删除旧容器。显式 healthcheck 沿用完整健康等待；没有 healthcheck 时要求
# 容器在一个短暂窗口内持续为 running。
health_kind="$(jq -r '.[0].Config.Healthcheck.Test[0] // empty' "$META" 2>/dev/null || true)"
if [[ "$original_running" == "true" &&
  ("$health_kind" == "CMD" || "$health_kind" == "CMD-SHELL") ]]; then
  health_timeout="${RESTORE_HEALTH_TIMEOUT:-60}"
  if ! [[ "$health_timeout" =~ ^[1-9][0-9]*$ ]] || ((health_timeout > 3600)); then
    error_user "RESTORE_HEALTH_TIMEOUT 的值无效：$health_timeout" "请设置为 1 到 3600 之间的秒数"
    exit 1
  fi
  health_timeout="$(health_wait_seconds "$health_timeout" "$name")"
  health_deadline=$((SECONDS + health_timeout))
  health_started=$SECONDS
  health_next_report=0
  health_last_status=""
  while ((SECONDS < health_deadline)); do
    health_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)"
    health_elapsed=$((SECONDS - health_started))
    case "$health_status" in
      healthy)
        log_line "[完成] 容器健康检查：$name · ${health_elapsed}秒"
        break
        ;;
      unhealthy | exited | dead)
        error_user "容器 ${name} 健康检查没有通过（${health_status}）" "执行 docker logs ${name} 查看应用日志"
        exit 1
        ;;
    esac
    if [[ "$health_status" != "$health_last_status" ]] || ((health_elapsed >= health_next_report)); then
      log_line "[进度] 容器健康检查：$name · ${health_status:-未知} · ${health_elapsed}/${health_timeout}秒"
      health_last_status="$health_status"
      health_next_report=$((health_elapsed + 5))
    fi
    progress_note "${name} 健康检查 · ${health_status:-starting} · ${health_elapsed}/${health_timeout} 秒"
    sleep 1
  done
  if [[ "${health_status:-}" != "healthy" ]]; then
    error_user "容器 ${name} 健康检查超时（${health_timeout} 秒）" \
      "执行 docker logs ${name} 查看应用日志；启动较慢的服务可以调大 RESTORE_HEALTH_TIMEOUT"
    exit 1
  fi
elif [[ "$original_running" == "true" ]]; then
  startup_grace="${RESTORE_STARTUP_GRACE:-3}"
  if ! [[ "$startup_grace" =~ ^[1-9][0-9]*$ ]] || ((startup_grace > 300)); then
    error_user "RESTORE_STARTUP_GRACE 的值无效：$startup_grace" "请设置为 1 到 300 之间的秒数"
    exit 1
  fi
  startup_deadline=$((SECONDS + startup_grace))
  startup_started=$SECONDS
  startup_next_report=5
  while :; do
    startup_status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    case "$startup_status" in
      running) ;;
      *)
        error_user "容器 ${name} 启动后立即退出（${startup_status:-missing}）" "执行 docker logs ${name} 查看应用日志"
        exit 1
        ;;
    esac
    startup_elapsed=$((SECONDS - startup_started))
    if ((startup_elapsed >= startup_next_report)); then
      log_line "[进度] 容器启动验证：$name · running · ${startup_elapsed}/${startup_grace}秒"
      startup_next_report=$((startup_elapsed + 5))
    fi
    ((SECONDS >= startup_deadline)) && break
    sleep 1
  done
  log_line "[完成] 容器启动验证：$name · $((SECONDS - startup_started))秒"
fi

snapshot_original="$(jq -r '.[0].DockerMigrate.original_image // empty' "$META")"
if [[ -n "$snapshot_original" ]]; then
  warn_user "${name} 使用快照镜像保留了容器内的改动，以后升级请用原镜像 ${snapshot_original} 重建"
fi

if [[ "$original_paused" == "true" ]]; then
  dm_quiet docker pause "$name" || {
    error_user "无法把容器 ${name} 恢复为暂停状态"
    exit 1
  }
fi

if ((replacement_active == 1)); then
  if ((transaction_mode == 1)); then
    # 由全局事务在全部项目、数据和健康检查通过后统一删除回滚容器。
    replacement_active=0
    log_line "替换已验证，回滚容器 ${replacement_backup_name} 保留到事务提交"
  elif dm_quiet docker rm -f "$replacement_backup_name"; then
    replacement_active=0
    log_line "替换已验证，已删除回滚容器 ${replacement_backup_name}"
  else
    warn_user "新容器已运行，但回滚容器 ${replacement_backup_name} 没能删除，可以手动执行 docker rm -f ${replacement_backup_name}"
  fi
fi
