#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_MIGRATE_LIB_ONLY=1
# shellcheck source=../docker_migrate_perfect.sh
source "${ROOT_DIR}/docker_migrate_perfect.sh"

for bin in docker jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "skip: $bin is unavailable"
    exit 0
  }
done
docker info >/dev/null 2>&1 || {
  echo "skip: Docker daemon is unavailable"
  exit 0
}

suffix="dmtest_${$}"
container_name="${suffix}_container"
stopped_container_name="${suffix}_stopped"
network_name="${suffix}_network"
blocker_name="${suffix}_blocker"
data_volume_name="${suffix}_data_volume"
shared_selected_name="${suffix}_shared_selected"
shared_writer_name="${suffix}_shared_writer"
host_port=$((30000 + ($$ % 10000)))
third_octet=$((($$ % 180) + 20))
subnet="172.30.${third_octet}.0/24"
container_ip="172.30.${third_octet}.10"
tmp="$(mktemp -d)"
compose_project="${suffix}_compose"
compose_work="${tmp}/compose-work"

cleanup() {
  if [[ -f "${compose_work}/_resolved_config.yml" ]] &&
    docker compose version >/dev/null 2>&1; then
    docker compose -f "${compose_work}/_resolved_config.yml" down -v >/dev/null 2>&1 || true
  fi
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  docker rm -f "$stopped_container_name" >/dev/null 2>&1 || true
  docker rm -f "$blocker_name" >/dev/null 2>&1 || true
  docker rm -f "$shared_selected_name" "$shared_writer_name" >/dev/null 2>&1 || true
  [[ -z "${snapshot_image:-}" ]] || docker image rm "$snapshot_image" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  docker volume rm "$data_volume_name" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

docker pull alpine:3.20 >/dev/null
docker network create --driver bridge --subnet "$subnet" "$network_name" >/dev/null
docker create \
  --name "$container_name" \
  -p "${host_port}:80" \
  --cpus 0.5 \
  --network "$network_name" \
  --ip "$container_ip" \
  --health-cmd 'test -f /etc/alpine-release' \
  --health-interval 5s \
  alpine:3.20 sleep 300 >/dev/null
printf 'writable-layer-state\n' >"${tmp}/writable-state.txt"
docker cp "${tmp}/writable-state.txt" "${container_name}:/writable-state.txt"
docker start "$container_name" >/dev/null

bundle="${tmp}/bundle"
mkdir -p "${bundle}/runs" "${bundle}/meta" "${bundle}/volumes" \
  "${bundle}/binds" "${bundle}/compose"
docker inspect "$container_name" >"${bundle}/meta/${container_name}.inspect.json"
snapshot_image="$(snapshot_image_ref "$suffix" "$(docker inspect -f '{{.Id}}' "$container_name")")"
snapshot_container_image "$container_name" "${bundle}/meta/${container_name}.inspect.json" "$snapshot_image"
write_run_script "$container_name" "${bundle}/runs/${container_name}.sh"

network_json="$(docker network inspect "$network_name" | jq '.[0] | {
  name: .Name,
  driver: .Driver,
  internal: .Internal,
  attachable: .Attachable,
  enable_ipv6: .EnableIPv6,
  options: (.Options // {}),
  labels: (.Labels // {}),
  ipam: {
    driver: (.IPAM.Driver // "default"),
    options: (.IPAM.Options // {}),
    config: (.IPAM.Config // [])
  }
}')"
jq -n \
  --arg run "runs/${container_name}.sh" \
  --argjson network "$network_json" \
  '{images:[],networks:[$network],projects:[],volumes:[],binds:[],runs:[$run]}' \
  >"${bundle}/manifest.json"
write_bundle_restore_script "${bundle}/restore.sh"
generate_bundle_checksums "$bundle"

docker rm -f "$container_name" >/dev/null
docker network rm "$network_name" >/dev/null

# replace 必须先保留旧容器；新容器因端口冲突失败后，应自动恢复旧容器及运行状态。
docker run -d --name "$container_name" alpine:3.20 sleep 300 >/dev/null
previous_id="$(docker inspect -f '{{.Id}}' "$container_name")"
docker run -d --name "$blocker_name" -p "${host_port}:80" alpine:3.20 sleep 300 >/dev/null
if RESTORE_EXISTING=replace bash "${bundle}/runs/${container_name}.sh" >/dev/null 2>&1; then
  echo "replace unexpectedly succeeded while the port was occupied" >&2
  exit 1
fi
[[ "$(docker inspect -f '{{.Id}}' "$container_name")" == "$previous_id" ]]
[[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "true" ]]
docker rm -f "$blocker_name" >/dev/null

(cd "$bundle" && bash restore.sh >/dev/null)

[[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "true" ]]
[[ "$(docker exec "$container_name" cat /writable-state.txt)" == "writable-layer-state" ]]
[[ "$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$container_name")" == "500000000" ]]
[[ "$(docker inspect -f "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "$container_name")" == "$container_ip" ]]
docker inspect "$container_name" | jq -e '.[0].Config.Healthcheck.Test[0] == "CMD-SHELL"' >/dev/null

first_id="$(docker inspect -f '{{.Id}}' "$container_name")"
RESTORE_EXISTING=skip bash "${bundle}/runs/${container_name}.sh" >/dev/null
[[ "$(docker inspect -f '{{.Id}}' "$container_name")" == "$first_id" ]]

if RESTORE_EXISTING=fail bash "${bundle}/runs/${container_name}.sh" >/dev/null 2>&1; then
  echo "RESTORE_EXISTING=fail unexpectedly succeeded" >&2
  exit 1
fi

RESTORE_EXISTING=replace bash "${bundle}/runs/${container_name}.sh" >/dev/null
[[ "$(docker inspect -f '{{.Id}}' "$container_name")" != "$first_id" ]]

# 原本停止的独立容器必须只创建，不能在目标端短暂启动。
docker create --name "$stopped_container_name" alpine:3.20 sleep 300 >/dev/null
docker inspect "$stopped_container_name" >"${bundle}/meta/${stopped_container_name}.inspect.json"
write_run_script "$stopped_container_name" "${bundle}/runs/${stopped_container_name}.sh"
docker rm "$stopped_container_name" >/dev/null
bash "${bundle}/runs/${stopped_container_name}.sh" >/dev/null
[[ "$(docker inspect -f '{{.State.Running}}' "$stopped_container_name")" == "false" ]]

# volume 与 bind 必须精确恢复；目标端多余旧文件不能在重复恢复后残留。
data_bundle="${tmp}/data-bundle"
bind_target="${tmp}/bind-target"
bind_archive_root="${tmp}/bind-archive-root"
mkdir -p "${data_bundle}/volumes" "${data_bundle}/binds" "${data_bundle}/meta" \
  "${tmp}/volume-source" "$bind_target" "${bind_archive_root}${bind_target}"
printf 'new-volume-data\n' >"${tmp}/volume-source/new.txt"
tar -czf "${data_bundle}/volumes/vol_${data_volume_name}.tgz" \
  -C "${tmp}/volume-source" .
printf 'new-bind-data\n' >"${bind_archive_root}${bind_target}/new.txt"
tar -czf "${data_bundle}/binds/bind_test.tgz" -C "$bind_archive_root" "${bind_target#/}"
printf 'old-bind-data\n' >"${bind_target}/old.txt"
printf 'stale-bind-data\n' >"${bind_target}/stale.txt"

docker volume create "$data_volume_name" >/dev/null
docker run --rm -v "${data_volume_name}:/to" alpine:3.20 sh -c \
  'printf old >/to/old.txt; printf stale >/to/stale.txt'
docker run -d --name "$shared_selected_name" -v "${data_volume_name}:/data" \
  alpine:3.20 sleep 300 >/dev/null
docker run -d --name "$shared_writer_name" -v "${data_volume_name}:/data" \
  alpine:3.20 sleep 300 >/dev/null
selected_probe_id="$(docker inspect -f '{{.Id}}' "$shared_selected_name")"
collect_shared_running_containers "$selected_probe_id" |
  awk -F '\t' -v expected="$shared_writer_name" '$2 == expected { found=1 } END { exit found ? 0 : 1 }'
docker rm -f "$shared_selected_name" "$shared_writer_name" >/dev/null
jq -n --arg volume "$data_volume_name" --arg host "$bind_target" '{
  images:[], networks:[], projects:[], runs:[],
  volumes:[{name:$volume,dest:"/data",driver:"local",opts:{}}],
  binds:[{host:$host,dest:"/bind",file:"bind_test.tgz"}]
}' >"${data_bundle}/manifest.json"
write_bundle_restore_script "${data_bundle}/restore.sh"
generate_bundle_checksums "$data_bundle"
(cd "$data_bundle" && bash restore.sh >/dev/null)
docker run --rm -v "${data_volume_name}:/to:ro" alpine:3.20 sh -ec \
  'test "$(cat /to/new.txt)" = new-volume-data; test ! -e /to/old.txt; test ! -e /to/stale.txt'
[[ "$(cat "${bind_target}/new.txt")" == "new-bind-data" ]]
[[ ! -e "${bind_target}/old.txt" && ! -e "${bind_target}/stale.txt" ]]

docker run --rm -v "${data_volume_name}:/to" alpine:3.20 sh -c 'printf stale >/to/stale.txt'
printf 'stale-bind-data\n' >"${bind_target}/stale.txt"
(cd "$data_bundle" && bash restore.sh >/dev/null)
docker run --rm -v "${data_volume_name}:/to:ro" alpine:3.20 test ! -e /to/stale.txt
[[ ! -e "${bind_target}/stale.txt" ]]

if docker compose version >/dev/null 2>&1; then
  compose_bundle="${tmp}/compose-bundle"
  mkdir -p "${compose_bundle}/compose/${compose_project}" "${compose_bundle}/meta" \
    "${compose_bundle}/volumes" "${compose_bundle}/binds"
  cat >"${compose_bundle}/compose/${compose_project}/_resolved_config.yml" <<YAML
name: ${compose_project}
services:
  first:
    image: alpine:3.20
    command: ["sleep", "300"]
    environment:
      MIGRATION_TEST: merged-config
  second:
    image: alpine:3.20
    command: ["sleep", "300"]
YAML
  jq -n \
    --arg name "$compose_project" \
    --arg working_dir "$compose_work" \
    '{
      images:[], networks:[], volumes:[], binds:[], runs:[],
      projects:[{
        name:$name,
        working_dir:$working_dir,
        files:["_resolved_config.yml"],
        config_files:["_resolved_config.yml"]
      }]
    }' >"${compose_bundle}/manifest.json"
  jq -n --arg project "$compose_project" '{
    State:{Running:true,Paused:false},
    Config:{Labels:{
      "com.docker.compose.project":$project,
      "com.docker.compose.service":"first"
    }}
  } | [.]
  ' >"${compose_bundle}/meta/first.inspect.json"
  jq -n --arg project "$compose_project" '{
    State:{Running:false,Paused:false},
    Config:{Labels:{
      "com.docker.compose.project":$project,
      "com.docker.compose.service":"second"
    }}
  } | [.]
  ' >"${compose_bundle}/meta/second.inspect.json"
  write_bundle_restore_script "${compose_bundle}/restore.sh"
  generate_bundle_checksums "$compose_bundle"

  # 先运行目标端旧项目，再用一个必定不健康的新配置触发 Compose 自动回滚。
  mkdir -p "$compose_work"
  cat >"${compose_work}/_resolved_config.yml" <<YAML
name: ${compose_project}
services:
  first:
    image: alpine:3.20
    command: ["sleep", "300"]
    environment:
      MIGRATION_TEST: old-config
  second:
    image: alpine:3.20
    command: ["sleep", "300"]
YAML
  docker compose -f "${compose_work}/_resolved_config.yml" up -d >/dev/null

  failed_compose_bundle="${tmp}/compose-bundle-failing"
  cp -a "$compose_bundle" "$failed_compose_bundle"
  cat >"${failed_compose_bundle}/compose/${compose_project}/_resolved_config.yml" <<YAML
name: ${compose_project}
services:
  first:
    image: alpine:3.20
    command: ["sleep", "300"]
    healthcheck:
      test: ["CMD", "false"]
      interval: 1s
      timeout: 1s
      retries: 1
  second:
    image: alpine:3.20
    command: ["sleep", "300"]
YAML
  generate_bundle_checksums "$failed_compose_bundle"
  if (cd "$failed_compose_bundle" && RESTORE_HEALTH_TIMEOUT=5 bash restore.sh >/dev/null 2>&1); then
    echo "unhealthy Compose replacement unexpectedly succeeded" >&2
    exit 1
  fi
  docker inspect "${compose_project}-first-1" |
    jq -e '.[0].Config.Env | index("MIGRATION_TEST=old-config") != null' >/dev/null
  [[ "$(docker inspect -f '{{.State.Running}}' "${compose_project}-first-1")" == "true" ]]

  (cd "$compose_bundle" && bash restore.sh >/dev/null)
  docker inspect "${compose_project}-first-1" |
    jq -e '.[0].Config.Env | index("MIGRATION_TEST=merged-config") != null' >/dev/null
  [[ "$(docker inspect -f '{{.State.Running}}' "${compose_project}-first-1")" == "true" ]]
  [[ "$(docker inspect -f '{{.State.Running}}' "${compose_project}-second-1")" == "false" ]]
else
  echo "skip: Docker Compose integration subtest is unavailable"
fi

echo "Docker integration test passed"
