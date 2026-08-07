#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
suffix="dme2e_${$}"
container_name="${suffix}_container"
volume_name="${suffix}_volume"
network_name="${suffix}_network"
paused_shared_name="${suffix}_paused_shared"
third_octet=$((($$ % 180) + 20))
subnet="172.31.${third_octet}.0/24"
container_ip="172.31.${third_octet}.10"
tmp="$(mktemp -d)"
export RESTORE_ROLLBACK_BASE="${tmp}/rollback"
export RESTORE_LOCK_BASE="${tmp}/locks"
source_work="${tmp}/source-work"
bind_path="${tmp}/bind-data"
restore_base="${tmp}/restore"
backup_log="${tmp}/backup.log"
restore_log="${tmp}/restore.log"
http_failure_log="${tmp}/http-failure.log"
backup_pid=""
ignore_container=""
confidential_marker="docker-migrate-e2e-confidential-${suffix}"
wire_payload="${tmp}/wire-bundle.tar.gz.enc"
docker_proxy_dir="${tmp}/docker-proxy"
archive_started="${tmp}/archive-started"
archive_release="${tmp}/archive-release"
bind_archive_started="${tmp}/bind-archive-started"
bind_archive_release="${tmp}/bind-archive-release"
http_failure_proxy_dir="${tmp}/http-failure-proxy"

cleanup() {
  touch "$archive_release" 2>/dev/null || true
  touch "$bind_archive_release" 2>/dev/null || true
  if [[ -n "$backup_pid" ]] && kill -0 "$backup_pid" 2>/dev/null; then
    kill -TERM "$backup_pid" 2>/dev/null || true
    wait "$backup_pid" 2>/dev/null || true
  fi
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  docker rm -f "$paused_shared_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  docker volume rm "$volume_name" >/dev/null 2>&1 || true
  if [[ -d "$tmp" ]]; then
    docker run --rm -v "${tmp}:/cleanup" alpine:3.20 \
      chmod -R a+rwX /cleanup >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

for bin in bash curl docker grep jq openssl python3 sha256sum tar; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "skip: $bin is unavailable"
    exit 0
  }
done
docker info >/dev/null 2>&1 || {
  echo "skip: Docker daemon is unavailable"
  exit 0
}
if docker inspect "$(hostname)" >/dev/null 2>&1; then
  ignore_container="$(docker inspect -f '{{.Name}}' "$(hostname)" | sed 's#^/##')"
fi

mkdir -p "$source_work" "$bind_path" "$restore_base"
printf 'source-bind-data\n' >"${bind_path}/data.txt"
docker pull alpine:3.20 >/dev/null
docker volume create "$volume_name" >/dev/null
docker run --rm -v "${volume_name}:/to" alpine:3.20 \
  sh -c 'printf "source-volume-data\n" >/to/data.txt'
docker network create --subnet "$subnet" "$network_name" >/dev/null
docker run -d \
  --name "$container_name" \
  --network "$network_name" \
  --ip "$container_ip" \
  -v "${volume_name}:/volume" \
  -v "${bind_path}:/bind" \
  alpine:3.20 sleep 300 >/dev/null
docker exec "$container_name" sh -c 'printf "source-writable-data\n" >/writable.txt'
docker exec "$container_name" sh -c 'printf "%s\n" "$1" >/confidential-marker.txt' sh \
  "$confidential_marker"
docker run -d --name "$paused_shared_name" -v "${volume_name}:/shared" \
  alpine:3.20 sleep 300 >/dev/null
docker pause "$paused_shared_name" >/dev/null

# 在真正开始归档命名卷前暂停一次 docker run，让测试能确定源容器在整个
# writable layer + volume/bind 快照窗口内保持停止，而不是只在 URL 发布后检查。
mkdir -p "$docker_proxy_dir"
real_docker="$(command -v docker)"
cat >"${docker_proxy_dir}/docker" <<'SH'
#!/bin/sh
case "$*" in
  *"${SOURCE_ARCHIVE_VOLUME}:/from:ro"*"tar -C /from -cf - ."*)
    : >"${SOURCE_ARCHIVE_STARTED}"
    while [ ! -e "${SOURCE_ARCHIVE_RELEASE}" ]; do sleep 0.1; done
    ;;
esac
exec "$REAL_DOCKER" "$@"
SH
chmod +x "${docker_proxy_dir}/docker"
real_tar="$(command -v tar)"
cat >"${docker_proxy_dir}/tar" <<'SH'
#!/bin/sh
case "$*" in
  *"-C / -cf - ${SOURCE_BIND_PATH#/}"*)
    : >"${SOURCE_BIND_ARCHIVE_STARTED}"
    while [ ! -e "${SOURCE_BIND_ARCHIVE_RELEASE}" ]; do sleep 0.1; done
    ;;
esac
exec "$REAL_TAR" "$@"
SH
chmod +x "${docker_proxy_dir}/tar"

(
  cd "$source_work"
  exec env PATH="${docker_proxy_dir}:$PATH" REAL_DOCKER="$real_docker" REAL_TAR="$real_tar" \
    SOURCE_ARCHIVE_VOLUME="$volume_name" \
    SOURCE_ARCHIVE_STARTED="$archive_started" \
    SOURCE_ARCHIVE_RELEASE="$archive_release" \
    SOURCE_BIND_ARCHIVE_STARTED="$bind_archive_started" \
    SOURCE_BIND_ARCHIVE_RELEASE="$bind_archive_release" \
    SOURCE_BIND_PATH="$bind_path" \
    PORT=18880 ADVERTISE_HOST=127.0.0.1 \
    STOP_SHARED_MOUNTS=1 \
    DOCKER_MIGRATE_LOCK_BASE="${tmp}/source-locks" \
    DOCKER_MIGRATE_IGNORE_CONTAINERS="$ignore_container" \
    bash "$ROOT_DIR/docker_migrate_perfect.sh" --backup \
    --include="$container_name"
) <<<"Y" >"$backup_log" 2>&1 &
backup_pid=$!

# Docker 不保证 Mounts 的遍历顺序；哪个归档先开始就先验证并释放，避免测试
# 把“volume 必须早于 bind”误当成产品契约。
volume_released=0
bind_released=0
for _ in $(seq 1 240); do
  if ((volume_released == 0)) && [[ -e "$archive_started" ]]; then
    grep -Fq "[进度] 打包命名卷：${volume_name}：开始；此步骤可能耗时较长，脚本正在正常执行，无需按键" \
      "$backup_log"
    [[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "false" ]]
    [[ "$(docker inspect -f '{{.State.Running}}' "$paused_shared_name")" == "false" ]]
    touch "$archive_release"
    volume_released=1
  fi
  if ((bind_released == 0)) && [[ -e "$bind_archive_started" ]]; then
    grep -Fq "[进度] 打包绑定目录：${bind_path}：开始；此步骤可能耗时较长，脚本正在正常执行，无需按键" \
      "$backup_log"
    [[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "false" ]]
    [[ "$(docker inspect -f '{{.State.Running}}' "$paused_shared_name")" == "false" ]]
    touch "$bind_archive_release"
    bind_released=1
  fi
  ((volume_released == 0 || bind_released == 0)) || break
  if ! kill -0 "$backup_pid" 2>/dev/null; then
    echo "backup process exited before both data archives completed" >&2
    tail -n 80 "$backup_log" >&2 || true
    exit 1
  fi
  sleep 1
done
if ((volume_released == 0 || bind_released == 0)); then
  echo "timed out waiting for volume/bind archives" >&2
  tail -n 80 "$backup_log" >&2 || true
  exit 1
fi

download_url=""
for _ in $(seq 1 180); do
  download_url="$(sed -nE 's|.*(http://[^[:space:]]*\.tar\.gz\.enc#sha256=[[:xdigit:]]{64}&enc=aes-256-ctr-hmac-sha256-v1&secret=[[:xdigit:]]{128}&iv=[[:xdigit:]]{32}&mac=[[:xdigit:]]{64}).*|\1|p' \
    "$backup_log" | tail -n1)"
  [[ -z "$download_url" ]] || break
  if ! kill -0 "$backup_pid" 2>/dev/null; then
    echo "backup process exited before publishing the URL" >&2
    tail -n 80 "$backup_log" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ -z "$download_url" ]]; then
  echo "timed out waiting for the migration download URL" >&2
  tail -n 80 "$backup_log" >&2 || true
  exit 1
fi

# 数据快照完成后源容器应立即恢复，不能为了等待下载而持续停机。
[[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "true" ]]
[[ "$(docker inspect -f '{{.State.Paused}}' "$paused_shared_name")" == "true" ]]

# URL fragment 中的密钥不会发送到 HTTP 服务；先直接下载一次，确认线上载荷只有密文。
wire_url="${download_url%%#*}"
expected_wire_sha="${download_url#*#sha256=}"
expected_wire_sha="${expected_wire_sha%%&*}"
[[ "$wire_url" == *.tar.gz.enc ]]
curl -fL --silent --show-error "$wire_url" -o "$wire_payload"
[[ -s "$wire_payload" ]]
[[ "$(sha256sum "$wire_payload" | awk '{print $1}')" == "$expected_wire_sha" ]]
if LC_ALL=C grep -aFq -- "$confidential_marker" "$wire_payload"; then
  echo "encrypted HTTP payload exposed the confidential marker" >&2
  exit 1
fi
if tar -tzf "$wire_payload" >/dev/null 2>&1; then
  echo "encrypted HTTP payload was unexpectedly readable as a gzip archive" >&2
  exit 1
fi

# 同一 Docker daemon 模拟两台主机：删除源容器，并破坏目标数据，确保恢复来自迁移包。
docker rm -f "$container_name" >/dev/null
docker run --rm -v "${volume_name}:/to" alpine:3.20 \
  sh -c 'find /to -mindepth 1 -maxdepth 1 -exec rm -rf -- {} \;; printf "stale\n" >/to/stale.txt'
printf 'stale\n' >"${bind_path}/stale.txt"

RESTORE_IGNORE_CONTAINERS="$ignore_container" RESTORE_BASE="$restore_base" \
  bash "$ROOT_DIR/docker_migrate_perfect.sh" \
  --restore="$download_url" >"$restore_log" 2>&1

[[ "$(grep -Fc 'Docker 迁移结果' "$restore_log")" -eq 1 ]]
[[ "$(grep -Fc '结果：' "$restore_log")" -eq 1 ]]
grep -Fq '结果：✅ 恢复成功' "$restore_log"
grep -Fq '容器：1 个（运行 1 / 暂停 0 / 停止 0）' "$restore_log"
! grep -Fq '若端口被占用' "$restore_log"

[[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "true" ]]
[[ "$(docker exec "$container_name" cat /writable.txt)" == "source-writable-data" ]]
[[ "$(docker exec "$container_name" cat /confidential-marker.txt)" == "$confidential_marker" ]]
[[ "$(docker exec "$container_name" cat /volume/data.txt)" == "source-volume-data" ]]
[[ "$(docker exec "$container_name" cat /bind/data.txt)" == "source-bind-data" ]]
[[ ! -e "${bind_path}/stale.txt" ]]
[[ "$(docker inspect -f "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "$container_name")" == "$container_ip" ]]

kill -TERM "$backup_pid" 2>/dev/null || true
if ! wait "$backup_pid" 2>/dev/null; then
  echo "source task reported success but returned a nonzero exit code" >&2
  tail -n 80 "$backup_log" >&2 || true
  exit 1
fi
backup_pid=""
[[ "$(docker inspect -f '{{.State.Paused}}' "$paused_shared_name")" == "true" ]]
[[ "$(grep -Fc 'Docker 迁移结果' "$backup_log")" -eq 1 ]]
[[ "$(grep -Fc '结果：' "$backup_log")" -eq 1 ]]
grep -Fq '结果：✅ 源端任务已安全结束' "$backup_log"
grep -Fq 'HTTP 服务：已停止' "$backup_log"
grep -Fq '源容器：已恢复 2/2' "$backup_log"
grep -Fq '清理：临时迁移文件已删除' "$backup_log"
if curl -fsS --max-time 2 "$wire_url" -o /dev/null 2>/dev/null; then
  echo "HTTP transfer service remained reachable after source cleanup" >&2
  exit 1
fi

# HTTP 子进程通过初始存活检查后若自行崩溃，源端必须返回非零并明确报告失败。
mkdir -p "$http_failure_proxy_dir"
cat >"${http_failure_proxy_dir}/python3" <<'SH'
#!/bin/sh
if [ "${1:-}" = "-" ]; then
  sleep 2
  exit 42
fi
exec "$REAL_PYTHON3" "$@"
SH
chmod +x "${http_failure_proxy_dir}/python3"
real_python3="$(command -v python3)"
http_failure_rc=0
(
  cd "$source_work"
  env PATH="${http_failure_proxy_dir}:$PATH" REAL_PYTHON3="$real_python3" \
    PORT=18881 ADVERTISE_HOST=127.0.0.1 \
    STOP_SHARED_MOUNTS=1 \
    DOCKER_MIGRATE_LOCK_BASE="${tmp}/source-locks" \
    DOCKER_MIGRATE_IGNORE_CONTAINERS="$ignore_container" \
    bash "$ROOT_DIR/docker_migrate_perfect.sh" --backup \
    --include="$container_name"
) <<<"Y" >"$http_failure_log" 2>&1 || http_failure_rc=$?
[[ "$http_failure_rc" -ne 0 ]]
[[ "$(grep -Fc 'Docker 迁移结果' "$http_failure_log")" -eq 1 ]]
[[ "$(grep -Fc '结果：' "$http_failure_log")" -eq 1 ]]
grep -Fq '结果：❌ 源端任务失败，清理流程已执行' "$http_failure_log"
grep -Fq 'HTTP 服务：异常退出' "$http_failure_log"
grep -Fq '源容器：已恢复 2/2' "$http_failure_log"
grep -Fq '清理：临时迁移文件已删除' "$http_failure_log"
! grep -Fq '结果：✅ 源端任务已安全结束' "$http_failure_log"
[[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "true" ]]
[[ "$(docker inspect -f '{{.State.Paused}}' "$paused_shared_name")" == "true" ]]

echo "End-to-end encrypted backup, HTTP transfer, and restore test passed"
