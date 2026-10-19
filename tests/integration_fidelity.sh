#!/usr/bin/env bash
# 真实配置保真度测试：用一组常见的 docker run 参数组合创建容器，走完整的
# 备份 → HTTP 传输 → 删除（模拟新服务器）→ 恢复流程，再逐项对比恢复前后
# docker inspect 的关键字段。任何参数在“inspect → docker run”翻译中丢失或
# 变形（例如只读挂载生成 ro,ro）都会在这里以字段差异的形式暴露出来。
set -euo pipefail
# 断言失败时指出所在行，CI 日志里才能直接定位。
trap 'echo "${BASH_SOURCE[0]##*/}: 第 ${LINENO} 行失败（退出码 $?）" >&2' ERR

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

for bin in bash curl docker jq python3 openssl tar; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "skip: $bin is unavailable"
    exit 0
  }
done
docker info >/dev/null 2>&1 || {
  echo "skip: Docker daemon is unavailable"
  exit 0
}

suffix="dmfid_${$}"
full_name="${suffix}_full"
multinet_name="${suffix}_multinet"
health_name="${suffix}_health"
stopped_name="${suffix}_stopped"
paused_name="${suffix}_paused"
provider_name="${suffix}_provider"
sidecar_name="${suffix}_sidecar"
symlink_name="${suffix}_symlink"
all_names=("$full_name" "$multinet_name" "$health_name" "$stopped_name"
  "$paused_name" "$provider_name" "$sidecar_name" "$symlink_name")
volume_name="${suffix}_volume"
net_a="${suffix}_net_a"
net_b="${suffix}_net_b"
health_image="${suffix}_health:1"
third_octet=$((($$ % 180) + 20))
subnet_a="172.29.${third_octet}.0/24"
static_ip="172.29.${third_octet}.10"
port_base=$((20000 + ($$ % 5000) * 2))
tmp="$(mktemp -d)"
export RESTORE_ROLLBACK_BASE="${tmp}/rollback"
export RESTORE_LOCK_BASE="${tmp}/locks"
bind_ro="${tmp}/bind-ro"
bind_rw="${tmp}/bind-rw"
symlink_real="${tmp}/symlink-real"
symlink_path="${tmp}/symlink-link"
before_dir="${tmp}/before"
after_dir="${tmp}/after"
backup_log="${tmp}/backup.log"
restore_log="${tmp}/restore.log"
backup_pid=""
ignore_container=""

cleanup() {
  if [[ -n "$backup_pid" ]] && kill -0 "$backup_pid" 2>/dev/null; then
    kill -TERM "$backup_pid" 2>/dev/null || true
    wait "$backup_pid" 2>/dev/null || true
  fi
  docker rm -f "${all_names[@]}" "${suffix}_port_blocker" >/dev/null 2>&1 || true
  docker network rm "$net_a" "$net_b" >/dev/null 2>&1 || true
  docker volume rm "$volume_name" >/dev/null 2>&1 || true
  docker image rm "$health_image" >/dev/null 2>&1 || true
  if [[ -d "$tmp" ]]; then
    docker run --rm -v "${tmp}:/cleanup" alpine:3.20 \
      chmod -R a+rwX /cleanup >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

if docker inspect "$(hostname)" >/dev/null 2>&1; then
  ignore_container="$(docker inspect -f '{{.Name}}' "$(hostname)" | sed 's#^/##')"
fi

docker pull alpine:3.20 >/dev/null
# exec 形式健康检查只能写在镜像里；恢复后必须保持 exec 形式不被改写。
printf 'FROM alpine:3.20\nHEALTHCHECK --interval=2s --timeout=2s --retries=3 CMD ["/bin/true"]\n' |
  docker build -q -t "$health_image" - >/dev/null

mkdir -p "$bind_ro" "$bind_rw" "$symlink_real" "$before_dir" "$after_dir"
printf 'ro-data\n' >"${bind_ro}/config.txt"
printf 'rw-data\n' >"${bind_rw}/state.txt"
printf 'symlink-data\n' >"${symlink_real}/data.txt"
ln -s "$symlink_real" "$symlink_path"
docker volume create "$volume_name" >/dev/null
docker run --rm -v "${volume_name}:/to" alpine:3.20 sh -c 'printf "volume-data\n" >/to/data.txt'
docker network create --subnet "$subnet_a" "$net_a" >/dev/null
docker network create "$net_b" >/dev/null

docker run -d --name "$full_name" \
  --hostname fidelity-host --user 1000:1000 -w /tmp \
  -e FOO=bar -e 'WITH_SPACE=a b c' \
  --label app.tier=web --label 'app.note=hello world' \
  -p "${port_base}:80" -p "127.0.0.1:$((port_base + 1)):81/udp" \
  --restart unless-stopped --memory 64m --cpus 0.5 --cpu-shares 512 \
  --cap-add NET_ADMIN --cap-drop MKNOD --ulimit nofile=1024:2048 \
  --read-only --tmpfs /scratch:rw,size=8m \
  --add-host db.test:10.1.2.3 --dns 1.1.1.1 --dns-search example.test \
  -v /etc/localtime:/etc/localtime:ro \
  -v "${volume_name}:/data" \
  -v "${bind_ro}:/cfg:ro" \
  -v "${bind_rw}:/rw" \
  --entrypoint sh alpine:3.20 -c 'sleep 600' >/dev/null

docker run -d --name "$multinet_name" \
  --network "$net_a" --ip "$static_ip" --network-alias svc-a \
  alpine:3.20 sleep 600 >/dev/null
docker network connect --alias svc-b "$net_b" "$multinet_name"

docker run -d --name "$health_name" "$health_image" sleep 600 >/dev/null
docker create --name "$stopped_name" -e STOPPED=1 alpine:3.20 sleep 600 >/dev/null
docker run -d --name "$paused_name" alpine:3.20 sleep 600 >/dev/null
docker pause "$paused_name" >/dev/null
docker run -d --name "$provider_name" alpine:3.20 sleep 600 >/dev/null
docker run -d --name "$sidecar_name" --network "container:${provider_name}" \
  -v /etc/localtime:/etc/localtime:ro alpine:3.20 sleep 600 >/dev/null
docker run -d --name "$symlink_name" -v "${symlink_path}:/data" alpine:3.20 sleep 600 >/dev/null

for _ in $(seq 1 30); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "$health_name")" == "healthy" ]] && break
  sleep 1
done
[[ "$(docker inspect -f '{{.State.Health.Status}}' "$health_name")" == "healthy" ]]

# 只比较迁移承诺保留的字段；随机 ID、运行时间和动态分配的值不在比较范围内。
normalize() {
  jq -S '.[0] as $c | ($c.Id[0:12]) as $short | ($c.Name | ltrimstr("/")) as $name | {
    state: ($c.State.Status | if . == "exited" or . == "created" then "stopped" else . end),
    config: {
      Hostname: (if ($c.HostConfig.NetworkMode | startswith("container:")) or
          $c.HostConfig.NetworkMode == "host" or $c.Config.Hostname == $short
        then null else $c.Config.Hostname end),
      User: $c.Config.User,
      WorkingDir: $c.Config.WorkingDir,
      Env: ($c.Config.Env // [] | sort),
      Cmd: $c.Config.Cmd,
      Entrypoint: $c.Config.Entrypoint,
      Labels: ($c.Config.Labels // {}),
      Healthcheck: $c.Config.Healthcheck,
      ExposedPorts: ($c.Config.ExposedPorts // {} | keys)
    },
    host: {
      PortBindings: ($c.HostConfig.PortBindings // {}),
      RestartPolicy: $c.HostConfig.RestartPolicy.Name,
      Memory: $c.HostConfig.Memory,
      NanoCpus: $c.HostConfig.NanoCpus,
      CpuShares: $c.HostConfig.CpuShares,
      CapAdd: ($c.HostConfig.CapAdd // [] | sort),
      CapDrop: ($c.HostConfig.CapDrop // [] | sort),
      Ulimits: ($c.HostConfig.Ulimits // []),
      Tmpfs: ($c.HostConfig.Tmpfs // {}),
      ExtraHosts: ($c.HostConfig.ExtraHosts // []),
      Dns: ($c.HostConfig.Dns // []),
      DnsSearch: ($c.HostConfig.DnsSearch // []),
      ReadonlyRootfs: $c.HostConfig.ReadonlyRootfs,
      NetworkMode: ($c.HostConfig.NetworkMode |
        if startswith("container:") then "container" elif . == "default" then "bridge" else . end)
    },
    mounts: ([$c.Mounts[]? | {
      Type, Destination, RW,
      Name: (if .Type == "volume" then .Name else null end),
      Source: (if .Type == "bind" then .Source else null end)
    }] | sort_by(.Destination)),
    networks: ($c.NetworkSettings.Networks // {} | with_entries(.value = {
      static_ip: (.value.IPAMConfig.IPv4Address // null),
      aliases: ((.value.Aliases // []) - [$short, $name] | sort)
    }))
  }'
}

for name in "${all_names[@]}"; do
  docker inspect "$name" | normalize >"${before_dir}/${name}.json"
done
provider_id_before="$(docker inspect -f '{{.Id}}' "$provider_name")"
[[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$sidecar_name")" == "container:${provider_id_before}" ]]

include_list="$(
  IFS=,
  echo "${all_names[*]}"
)"
(
  cd "$tmp"
  exec env PORT=$((port_base + 2)) ADVERTISE_HOST=127.0.0.1 DOCKER_MIGRATE_VERBOSE=1 \
    STOP_SHARED_MOUNTS=1 \
    DOCKER_MIGRATE_LOCK_BASE="${tmp}/source-locks" \
    DOCKER_MIGRATE_IGNORE_CONTAINERS="$ignore_container" \
    bash "$ROOT_DIR/docker_migrate_perfect.sh" --backup --include="$include_list"
) </dev/null >"$backup_log" 2>&1 &
backup_pid=$!

download_url=""
for _ in $(seq 1 300); do
  download_url="$(sed -nE 's|.*(http://[^[:space:]]*\.tar\.gz\.enc#sha256=[[:xdigit:]]{64}&enc=aes-256-ctr-hmac-sha256-v1&secret=[[:xdigit:]]{128}&iv=[[:xdigit:]]{32}&mac=[[:xdigit:]]{64}).*|\1|p' \
    "$backup_log" | tail -n1)"
  [[ -z "$download_url" ]] || break
  if ! kill -0 "$backup_pid" 2>/dev/null; then
    echo "backup exited before publishing the URL" >&2
    tail -n 120 "$backup_log" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ -z "$download_url" ]]; then
  echo "timed out waiting for the migration download URL" >&2
  tail -n 120 "$backup_log" >&2 || true
  exit 1
fi

# 源端状态必须原样恢复（暂停的仍暂停、停止的仍停止）。
[[ "$(docker inspect -f '{{.State.Status}}' "$paused_name")" == "paused" ]]
[[ "$(docker inspect -f '{{.State.Status}}' "$stopped_name")" == "created" ]]
grep -Fq '宿主机系统路径只在新服务器重建挂载' "$backup_log"
grep -Fq '挂载路径是软链接，备份它指向的真实目录' "$backup_log"
grep -Fq "沿用原镜像" "$backup_log"

# 模拟全新的目标服务器：删除容器、网络、卷、镜像与宿主机目录。
docker rm -f "${all_names[@]}" >/dev/null
docker network rm "$net_a" "$net_b" >/dev/null
docker volume rm "$volume_name" >/dev/null
docker image rm "$health_image" >/dev/null
rm -rf "$bind_ro" "$bind_rw" "$symlink_real" "$symlink_path"

# 迁移前预检：先让别的容器占用 full 需要的端口，恢复必须在下载前停下并说明原因。
blocker_name="${suffix}_port_blocker"
docker run -d --name "$blocker_name" -p "${port_base}:80" alpine:3.20 sleep 600 >/dev/null
preflight_log="${tmp}/preflight.log"
if RESTORE_IGNORE_CONTAINERS="$ignore_container" RESTORE_BASE="${tmp}/restore-preflight" \
  bash "$ROOT_DIR/docker_migrate_perfect.sh" --restore="$download_url" \
  </dev/null >"$preflight_log" 2>&1; then
  echo "restore unexpectedly ignored an occupied port" >&2
  tail -n 60 "$preflight_log" >&2
  exit 1
fi
grep -Fq "端口 ${port_base} 已被容器 ${blocker_name} 占用，容器 ${full_name} 需要使用它" "$preflight_log"
grep -Fq '尚未下载或修改任何内容' "$preflight_log"
grep -Fq 'RESTORE_AUTO_RESOLVE=1' "$preflight_log"
[[ -z "$(find "${tmp}/restore-preflight" -name 'bundle.tar.gz.enc*' -print -quit 2>/dev/null)" ]]
docker rm -f "$blocker_name" >/dev/null

# 端口释放后，只预检（--check）应当通过且不下载任何内容。
check_log="${tmp}/check.log"
RESTORE_IGNORE_CONTAINERS="$ignore_container" RESTORE_BASE="${tmp}/restore-check" \
  bash "$ROOT_DIR/docker_migrate_perfect.sh" --check="$download_url" </dev/null >"$check_log" 2>&1
grep -Fq '预检通过，没有下载或修改任何内容' "$check_log"
grep -Eq '\[2/9\] 迁移前预检 ✓ 8 个容器' "$check_log"
[[ ! -d "${tmp}/restore-check" ]] || [[ -z "$(ls -A "${tmp}/restore-check")" ]]

if ! RESTORE_IGNORE_CONTAINERS="$ignore_container" RESTORE_BASE="${tmp}/restore" \
  bash "$ROOT_DIR/docker_migrate_perfect.sh" --restore="$download_url" \
  </dev/null >"$restore_log" 2>&1; then
  echo "restore failed" >&2
  tail -n 120 "$restore_log" >&2 || true
  exit 1
fi
grep -Fq '结果：✅ 恢复成功' "$restore_log"

for _ in $(seq 1 30); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "$health_name" 2>/dev/null)" == "healthy" ]] && break
  sleep 1
done

failures=0
for name in "${all_names[@]}"; do
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "missing after restore: $name" >&2
    failures=$((failures + 1))
    continue
  fi
  docker inspect "$name" | normalize >"${after_dir}/${name}.json"
  if ! diff -u "${before_dir}/${name}.json" "${after_dir}/${name}.json" >"${tmp}/${name}.diff"; then
    echo "configuration drift after restore: $name" >&2
    cat "${tmp}/${name}.diff" >&2
    failures=$((failures + 1))
  fi
done

provider_id_after="$(docker inspect -f '{{.Id}}' "$provider_name")"
[[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$sidecar_name")" == "container:${provider_id_after}" ]] || {
  echo "sidecar is not attached to the restored provider" >&2
  failures=$((failures + 1))
}
[[ "$(docker inspect -f '{{.State.Health.Status}}' "$health_name")" == "healthy" ]] || {
  echo "exec-form healthcheck is not healthy after restore" >&2
  failures=$((failures + 1))
}
check_data() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "data mismatch (${label}): got '${actual}', expected '${expected}'" >&2
    failures=$((failures + 1))
  fi
}
check_data volume "$(docker exec "$full_name" cat /data/data.txt 2>&1)" volume-data
check_data bind-ro "$(docker exec "$full_name" cat /cfg/config.txt 2>&1)" ro-data
check_data bind-rw "$(docker exec "$full_name" cat /rw/state.txt 2>&1)" rw-data
check_data symlink "$(docker exec "$symlink_name" cat /data/data.txt 2>&1)" symlink-data
[[ -L "$symlink_path" ]] || {
  echo "symlinked bind path was not recreated as a symlink" >&2
  failures=$((failures + 1))
}

kill -TERM "$backup_pid" 2>/dev/null || true
wait "$backup_pid" 2>/dev/null || true
backup_pid=""

if ((failures > 0)); then
  echo "fidelity test found ${failures} problem(s)" >&2
  echo "--- restore log (tail) ---" >&2
  tail -n 60 "$restore_log" >&2 || true
  exit 1
fi
echo "Real-world configuration fidelity test passed (${#all_names[@]} containers)"
