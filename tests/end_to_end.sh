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
backup_pid=""
ignore_container=""
confidential_marker="docker-migrate-e2e-confidential-${suffix}"
wire_payload="${tmp}/wire-bundle.tar.gz.enc"

cleanup() {
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

(
  cd "$source_work"
  exec env PORT=18880 ADVERTISE_HOST=127.0.0.1 \
    STOP_SHARED_MOUNTS=1 \
    DOCKER_MIGRATE_LOCK_BASE="${tmp}/source-locks" \
    DOCKER_MIGRATE_IGNORE_CONTAINERS="$ignore_container" \
    bash "$ROOT_DIR/docker_migrate_perfect.sh" --backup \
    --include="$container_name"
) <<<"Y" >"$backup_log" 2>&1 &
backup_pid=$!

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
docker rm "$container_name" >/dev/null
docker run --rm -v "${volume_name}:/to" alpine:3.20 \
  sh -c 'find /to -mindepth 1 -maxdepth 1 -exec rm -rf -- {} \;; printf "stale\n" >/to/stale.txt'
printf 'stale\n' >"${bind_path}/stale.txt"

RESTORE_IGNORE_CONTAINERS="$ignore_container" RESTORE_BASE="$restore_base" \
  bash "$ROOT_DIR/docker_migrate_perfect.sh" \
  --restore="$download_url" >/dev/null

[[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "true" ]]
[[ "$(docker exec "$container_name" cat /writable.txt)" == "source-writable-data" ]]
[[ "$(docker exec "$container_name" cat /confidential-marker.txt)" == "$confidential_marker" ]]
[[ "$(docker exec "$container_name" cat /volume/data.txt)" == "source-volume-data" ]]
[[ "$(docker exec "$container_name" cat /bind/data.txt)" == "source-bind-data" ]]
[[ ! -e "${bind_path}/stale.txt" ]]
[[ "$(docker inspect -f "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "$container_name")" == "$container_ip" ]]

kill -TERM "$backup_pid" 2>/dev/null || true
wait "$backup_pid" 2>/dev/null || true
backup_pid=""
[[ "$(docker inspect -f '{{.State.Paused}}' "$paused_shared_name")" == "true" ]]

echo "End-to-end encrypted backup, HTTP transfer, and restore test passed"
