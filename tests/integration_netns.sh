#!/usr/bin/env bash
# 共享网络命名空间的独立容器 + 系统路径 bind 的恢复回归测试：
# - sidecar 使用 --network container:provider，inspect 中的 Hostname 是 provider 的值；
#   恢复时不能再传 --hostname，且必须在 provider 之后创建。
# - 旧迁移包可能记录了 /etc/localtime 这类系统路径 bind；恢复时必须跳过，
#   不能因缺少归档而失败，更不能覆盖目标端宿主机文件。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_MIGRATE_LIB_ONLY=1
# shellcheck source=../docker_migrate_perfect.sh
source "${ROOT_DIR}/docker_migrate_perfect.sh"

for bin in docker jq python3; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "skip: $bin is unavailable"
    exit 0
  }
done
docker info >/dev/null 2>&1 || {
  echo "skip: Docker daemon is unavailable"
  exit 0
}

suffix="dmnetns_${$}"
provider_name="${suffix}_provider"
sidecar_name="${suffix}_sidecar"
tmp="$(mktemp -d)"
export RESTORE_ROLLBACK_BASE="${tmp}/rollback"
export RESTORE_LOCK_BASE="${tmp}/locks"

cleanup() {
  docker rm -f "$sidecar_name" "$provider_name" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

localtime_before="$(ls -l /etc/localtime 2>/dev/null || true)"

docker pull alpine:3.20 >/dev/null
docker run -d --name "$provider_name" alpine:3.20 sleep 300 >/dev/null
docker run -d --name "$sidecar_name" --network "container:${provider_name}" \
  -v /etc/localtime:/etc/localtime:ro alpine:3.20 sleep 300 >/dev/null

bundle="${tmp}/bundle"
mkdir -p "${bundle}/runs" "${bundle}/meta"
for name in "$provider_name" "$sidecar_name"; do
  docker inspect "$name" >"${bundle}/meta/${name}.inspect.json"
  write_run_script "$name" "${bundle}/runs/${name}.sh"
done
# 依附者故意排在前面，验证恢复会按依赖排序。
jq -n \
  --arg sidecar "runs/${sidecar_name}.sh" \
  --arg provider "runs/${provider_name}.sh" \
  '{images:[],networks:[],projects:[],volumes:[],runs:[$sidecar,$provider],
    binds:[{host:"/etc/localtime",dest:"/etc/localtime",file:"bind_localtime_1.tgz"}]}' \
  >"${bundle}/manifest.json"
write_bundle_restore_script "${bundle}/restore.sh"

# 模拟全新的目标服务器。
docker rm -f "$sidecar_name" "$provider_name" >/dev/null

if ! bash "${bundle}/restore.sh" >"${tmp}/restore.log" 2>&1; then
  echo "namespace-sharing restore failed" >&2
  tail -n 80 "${tmp}/restore.log" >&2
  exit 1
fi

[[ "$(docker inspect -f '{{.State.Running}}' "$provider_name")" == "true" ]]
[[ "$(docker inspect -f '{{.State.Running}}' "$sidecar_name")" == "true" ]]
provider_id="$(docker inspect -f '{{.Id}}' "$provider_name")"
[[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$sidecar_name")" == "container:${provider_id}" ]]
grep -Fq '跳过宿主机系统路径' "${tmp}/restore.log"
[[ "$(ls -l /etc/localtime 2>/dev/null || true)" == "$localtime_before" ]]

echo "namespace-sharing and system bind restore: ok"
