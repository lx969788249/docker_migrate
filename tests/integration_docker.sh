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
crash_container_name="${suffix}_crash"
network_name="${suffix}_network"
blocker_name="${suffix}_blocker"
data_volume_name="${suffix}_data_volume"
compose_data_volume_name="${suffix}_compose_data_volume"
compose_external_network_name="${suffix}_compose_external"
standalone_tx_volume_name="${suffix}_standalone_tx_volume"
shared_selected_name="${suffix}_shared_selected"
shared_writer_name="${suffix}_shared_writer"
compose_shared_writer_name="${suffix}_compose_shared_writer"
host_port=$((30000 + ($$ % 10000)))
ipv6_host_port=$((host_port + 1))
third_octet=$((($$ % 180) + 20))
subnet="172.30.${third_octet}.0/24"
container_ip="172.30.${third_octet}.10"
tmp="$(mktemp -d)"
export RESTORE_ROLLBACK_BASE="${tmp}/rollback"
export RESTORE_LOCK_BASE="${tmp}/locks"
compose_project="${suffix}_compose"
compose_work="${tmp}/compose-work"
lock_holder_pid=""

cleanup() {
  if [[ -n "$lock_holder_pid" ]] && kill -0 "$lock_holder_pid" 2>/dev/null; then
    kill "$lock_holder_pid" 2>/dev/null || true
    wait "$lock_holder_pid" 2>/dev/null || true
  fi
  if [[ -f "${compose_work}/_resolved_config.yml" ]] &&
    docker compose version >/dev/null 2>&1; then
    docker compose -f "${compose_work}/_resolved_config.yml" down -v >/dev/null 2>&1 || true
  fi
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  while IFS= read -r rollback_container; do
    [[ -n "$rollback_container" ]] || continue
    docker rm -f "$rollback_container" >/dev/null 2>&1 || true
  done < <(docker ps -a --format '{{.Names}}' | awk -v prefix="${container_name}.docker-migrate-backup-" \
    'index($0, prefix) == 1')
  docker rm -f "$stopped_container_name" >/dev/null 2>&1 || true
  docker rm -f "$crash_container_name" >/dev/null 2>&1 || true
  docker rm -f "$blocker_name" >/dev/null 2>&1 || true
  docker rm -f "$shared_selected_name" "$shared_writer_name" \
    "$compose_shared_writer_name" >/dev/null 2>&1 || true
  [[ -z "${snapshot_image:-}" ]] || docker image rm "$snapshot_image" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  docker network rm "$compose_external_network_name" >/dev/null 2>&1 || true
  docker volume rm "$data_volume_name" >/dev/null 2>&1 || true
  docker volume rm "$compose_data_volume_name" >/dev/null 2>&1 || true
  docker volume rm "$standalone_tx_volume_name" >/dev/null 2>&1 || true
  # 恢复流程会以 root 精确保留文件权限；CI runner 是普通用户，先在一次性
  # 容器内放宽这个测试专用临时树，避免功能测试通过后仅因清理权限而失败。
  if [[ -d "$tmp" ]]; then
    docker run --rm -v "${tmp}:/cleanup" alpine:3.20 \
      chmod -R a+rwX /cleanup >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

docker pull alpine:3.20 >/dev/null
docker network create --driver bridge --subnet "$subnet" "$network_name" >/dev/null
docker create \
  --name "$container_name" \
  --label "com.docker.compose.project=${suffix}_single" \
  --label "com.docker.compose.service=app" \
  -p "${host_port}:80" \
  -p "[::]:${ipv6_host_port}:81" \
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

# replace 必须释放旧容器仍保留的静态 IP endpoint；新容器因端口冲突失败后，
# 又必须把旧容器原网络、IP 与运行状态一并恢复。
docker network create --driver bridge --subnet "$subnet" "$network_name" >/dev/null
docker run -d --name "$container_name" --network "$network_name" --ip "$container_ip" \
  alpine:3.20 sleep 300 >/dev/null
previous_id="$(docker inspect -f '{{.Id}}' "$container_name")"
docker run -d --name "$blocker_name" -p "${host_port}:80" alpine:3.20 sleep 300 >/dev/null
if RESTORE_EXISTING=replace bash "${bundle}/runs/${container_name}.sh" >/dev/null 2>&1; then
  echo "replace unexpectedly succeeded while the port was occupied" >&2
  exit 1
fi
[[ "$(docker inspect -f '{{.Id}}' "$container_name")" == "$previous_id" ]]
[[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "true" ]]
[[ "$(docker inspect -f "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "$container_name")" == "$container_ip" ]]
docker rm -f "$blocker_name" >/dev/null

initial_restore_output="$(cd "$bundle" && bash restore.sh 2>&1)"
[[ "$(grep -Fc 'Docker 迁移结果' <<<"$initial_restore_output")" -eq 1 ]]
[[ "$(grep -Fc '结果：' <<<"$initial_restore_output")" -eq 1 ]]
grep -Fq '结果：✅ 恢复成功' <<<"$initial_restore_output"
grep -Fq '容器：1 个（运行 1 / 暂停 0 / 停止 0）' <<<"$initial_restore_output"
! grep -Fq '若端口被占用' <<<"$initial_restore_output"

[[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" == "true" ]]
[[ "$(docker exec "$container_name" cat /writable-state.txt)" == "writable-layer-state" ]]
[[ "$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$container_name")" == "500000000" ]]
[[ "$(docker inspect -f "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "$container_name")" == "$container_ip" ]]
docker inspect "$container_name" | jq -e '.[0].Config.Healthcheck.Test[0] == "CMD-SHELL"' >/dev/null
docker inspect "$container_name" | jq -e --arg port "$ipv6_host_port" '
  .[0].HostConfig.PortBindings["81/tcp"][0] |
  .HostIp == "::" and .HostPort == $port
' >/dev/null

# 同名网络核心参数一致而 labels 不同时只告警并复用，不能阻断恢复或篡改目标标签。
label_bundle="${tmp}/network-label-bundle"
mkdir -p "${label_bundle}/meta"
jq -n --argjson network "$(jq '.labels = {"migration.expected":"source"}' <<<"$network_json")" \
  '{images:[],networks:[$network],projects:[],volumes:[],binds:[],runs:[]}' \
  >"${label_bundle}/manifest.json"
write_bundle_restore_script "${label_bundle}/restore.sh"
generate_bundle_checksums "$label_bundle"
label_restore_output="$(cd "$label_bundle" && bash restore.sh)"
grep -Fq 'labels 与迁移记录不同，继续复用且不修改' <<<"$label_restore_output"
[[ -z "$(docker network inspect -f '{{ index .Labels "migration.expected" }}' "$network_name")" ]]

# 同一 Docker 目标只允许一个恢复事务；第二个实例必须在任何资源变更前退出。
if command -v flock >/dev/null 2>&1; then
  lock_bundle="${tmp}/lock-bundle"
  mkdir -p "$lock_bundle" "$RESTORE_LOCK_BASE"
  printf '{"images":[],"networks":[],"projects":[],"volumes":[],"binds":[],"runs":[]}\n' \
    >"${lock_bundle}/manifest.json"
  write_bundle_restore_script "${lock_bundle}/restore.sh"
  generate_bundle_checksums "$lock_bundle"
  lock_ready="${tmp}/lock-ready"
  (
    exec 9>"${RESTORE_LOCK_BASE}/migration.lock"
    flock 9
    : >"$lock_ready"
    sleep 30
  ) &
  lock_holder_pid=$!
  for _ in {1..50}; do
    [[ -f "$lock_ready" ]] && break
    sleep 0.1
  done
  [[ -f "$lock_ready" ]]
  if (cd "$lock_bundle" && bash restore.sh >/dev/null 2>&1); then
    echo "concurrent restore unexpectedly acquired the transaction lock" >&2
    exit 1
  fi
  kill "$lock_holder_pid" 2>/dev/null || true
  wait "$lock_holder_pid" 2>/dev/null || true
  lock_holder_pid=""
fi

# bind 不能覆盖迁移包、事务 WAL 或锁目录；必须在改动任何目标数据前拒绝。
overlap_bundle="${tmp}/overlap-bundle"
overlap_target="${tmp}/overlap-target"
overlap_archive_root="${tmp}/overlap-archive-root"
mkdir -p "${overlap_bundle}/binds" "${overlap_bundle}/meta" \
  "$overlap_target" "${overlap_archive_root}${overlap_target}"
printf 'old-overlap-data\n' >"${overlap_target}/old.txt"
printf 'new-overlap-data\n' >"${overlap_archive_root}${overlap_target}/new.txt"
tar -czf "${overlap_bundle}/binds/overlap.tgz" -C "$overlap_archive_root" \
  "${overlap_target#/}"
jq -n --arg host "$overlap_target" '{
  images:[], networks:[], projects:[], volumes:[], runs:[],
  binds:[{host:$host,dest:"/data",file:"overlap.tgz"}]
}' >"${overlap_bundle}/manifest.json"
write_bundle_restore_script "${overlap_bundle}/restore.sh"
generate_bundle_checksums "$overlap_bundle"
if overlap_output="$(
  cd "$overlap_bundle" &&
    RESTORE_ROLLBACK_BASE="${overlap_target}/rollback" \
      RESTORE_LOCK_BASE="${tmp}/overlap-locks" bash restore.sh 2>&1
)"; then
  echo "restore unexpectedly allowed its rollback WAL inside a replaced bind" >&2
  exit 1
fi
grep -Fq '绑定目录与 事务回滚目录 重叠' <<<"$overlap_output"
[[ "$(cat "${overlap_target}/old.txt")" == "old-overlap-data" ]]
[[ ! -e "${overlap_target}/new.txt" ]]

# 不存在的 protected child 也必须通过 symlink 父目录规范化后识别重叠。
overlap_alias="${tmp}/overlap-target-link"
ln -s "$overlap_target" "$overlap_alias"
if overlap_output="$(
  cd "$overlap_bundle" &&
    RESTORE_ROLLBACK_BASE="${overlap_alias}/missing/../rollback" \
      RESTORE_LOCK_BASE="${tmp}/overlap-locks" bash restore.sh 2>&1
)"; then
  echo "restore unexpectedly missed a symlink-parent rollback overlap" >&2
  exit 1
fi
grep -Fq '绑定目录与 事务回滚目录 重叠' <<<"$overlap_output"
[[ "$(cat "${overlap_target}/old.txt")" == "old-overlap-data" ]]
[[ ! -e "${overlap_target}/new.txt" ]]

first_id="$(docker inspect -f '{{.Id}}' "$container_name")"
RESTORE_EXISTING=skip bash "${bundle}/runs/${container_name}.sh" >/dev/null
[[ "$(docker inspect -f '{{.Id}}' "$container_name")" == "$first_id" ]]

if RESTORE_EXISTING=fail bash "${bundle}/runs/${container_name}.sh" >/dev/null 2>&1; then
  echo "RESTORE_EXISTING=fail unexpectedly succeeded" >&2
  exit 1
fi

RESTORE_EXISTING=replace bash "${bundle}/runs/${container_name}.sh" >/dev/null
[[ "$(docker inspect -f '{{.Id}}' "$container_name")" != "$first_id" ]]

# 完整 restore.sh 的单容器失败路径必须把旧容器、volume 与 bind 一起回滚。
standalone_tx_bundle="${tmp}/standalone-tx-bundle"
standalone_tx_bind="${tmp}/standalone-tx-bind"
standalone_tx_bind_root="${tmp}/standalone-tx-bind-root"
standalone_tx_volume_source="${tmp}/standalone-tx-volume-source"
cp -a "$bundle" "$standalone_tx_bundle"
mkdir -p "${standalone_tx_bundle}/volumes" "${standalone_tx_bundle}/binds" \
  "$standalone_tx_bind" "${standalone_tx_bind_root}${standalone_tx_bind}" \
  "$standalone_tx_volume_source"
printf 'source-standalone-volume\n' >"${standalone_tx_volume_source}/source.txt"
tar -czf "${standalone_tx_bundle}/volumes/vol_${standalone_tx_volume_name}.tgz" \
  -C "$standalone_tx_volume_source" .
printf 'source-standalone-bind\n' \
  >"${standalone_tx_bind_root}${standalone_tx_bind}/source.txt"
tar -czf "${standalone_tx_bundle}/binds/standalone_bind.tgz" \
  -C "$standalone_tx_bind_root" "${standalone_tx_bind#/}"
jq --arg volume "$standalone_tx_volume_name" --arg host "$standalone_tx_bind" '
  .[0].Mounts = ((.[0].Mounts // []) + [
    {Type:"volume",Name:$volume,Destination:"/data",RW:true,Mode:"z",Propagation:""},
    {Type:"bind",Source:$host,Destination:"/bind",RW:true,Mode:"rw",Propagation:"rprivate"}
  ])
' "${standalone_tx_bundle}/meta/${container_name}.inspect.json" \
  >"${standalone_tx_bundle}/meta/${container_name}.inspect.json.tmp"
mv "${standalone_tx_bundle}/meta/${container_name}.inspect.json.tmp" \
  "${standalone_tx_bundle}/meta/${container_name}.inspect.json"
jq --arg volume "$standalone_tx_volume_name" --arg host "$standalone_tx_bind" '
  .volumes = [{name:$volume,dest:"/data",driver:"local",opts:{}}] |
  .binds = [{host:$host,dest:"/bind",file:"standalone_bind.tgz"}]
' "${standalone_tx_bundle}/manifest.json" >"${standalone_tx_bundle}/manifest.json.tmp"
mv "${standalone_tx_bundle}/manifest.json.tmp" "${standalone_tx_bundle}/manifest.json"
generate_bundle_checksums "$standalone_tx_bundle"

docker rm -f "$container_name" >/dev/null
docker volume create "$standalone_tx_volume_name" >/dev/null
docker run --rm -v "${standalone_tx_volume_name}:/to" alpine:3.20 sh -c \
  'printf old-standalone-volume >/to/old.txt'
printf 'old-standalone-bind\n' >"${standalone_tx_bind}/old.txt"
docker run -d --name "$container_name" -v "${standalone_tx_volume_name}:/data" \
  -v "${standalone_tx_bind}:/bind" alpine:3.20 sleep 300 >/dev/null
standalone_old_id="$(docker inspect -f '{{.Id}}' "$container_name")"
docker run -d --name "$blocker_name" -p "${host_port}:80" alpine:3.20 sleep 300 >/dev/null
standalone_restore_output=""
if standalone_restore_output="$(
  cd "$standalone_tx_bundle" && RESTORE_HEALTH_TIMEOUT=5 bash restore.sh 2>&1
)"; then
  echo "standalone transaction unexpectedly succeeded while the port was occupied" >&2
  exit 1
fi
[[ "$(docker inspect -f '{{.Id}}' "$container_name")" == "$standalone_old_id" ]]
if [[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" != "true" ]]; then
  echo "standalone transaction did not restore the old running state" >&2
  printf '%s\n' "$standalone_restore_output" >&2
  exit 1
fi
docker run --rm -v "${standalone_tx_volume_name}:/to:ro" alpine:3.20 sh -ec \
  'test "$(cat /to/old.txt)" = old-standalone-volume; test ! -e /to/source.txt'
[[ "$(cat "${standalone_tx_bind}/old.txt")" == "old-standalone-bind" ]]
[[ ! -e "${standalone_tx_bind}/source.txt" ]]
[[ "$(grep -Fc 'Docker 迁移结果' <<<"$standalone_restore_output")" -eq 1 ]]
[[ "$(grep -Fc '结果：' <<<"$standalone_restore_output")" -eq 1 ]]
grep -Fq '结果：❌ 恢复失败，已安全回滚' <<<"$standalone_restore_output"
grep -Fq '已确认宿主机端口绑定冲突' <<<"$standalone_restore_output"
! grep -Fq '结果：✅ 恢复成功' <<<"$standalone_restore_output"
docker rm -f "$blocker_name" >/dev/null

# 原本停止的独立容器必须只创建，不能在目标端短暂启动。
docker create --name "$stopped_container_name" alpine:3.20 sleep 300 >/dev/null
docker inspect "$stopped_container_name" >"${bundle}/meta/${stopped_container_name}.inspect.json"
write_run_script "$stopped_container_name" "${bundle}/runs/${stopped_container_name}.sh"
docker rm "$stopped_container_name" >/dev/null
bash "${bundle}/runs/${stopped_container_name}.sh" >/dev/null
[[ "$(docker inspect -f '{{.State.Running}}' "$stopped_container_name")" == "false" ]]

# 无 healthcheck 的运行容器若在 docker run -d 后立即退出，必须判为失败并保留旧容器。
docker run -d --name "$crash_container_name" alpine:3.20 sleep 300 >/dev/null
docker inspect "$crash_container_name" | jq '
  .[0].Config.Healthcheck = null |
  .[0].Config.Cmd = ["sh", "-c", "exit 42"]
' >"${bundle}/meta/${crash_container_name}.inspect.json"
write_run_script "$crash_container_name" "${bundle}/runs/${crash_container_name}.sh"
docker rm -f "$crash_container_name" >/dev/null
docker run -d --name "$crash_container_name" alpine:3.20 sleep 300 >/dev/null
crash_old_id="$(docker inspect -f '{{.Id}}' "$crash_container_name")"
if RESTORE_STARTUP_GRACE=2 \
  bash "${bundle}/runs/${crash_container_name}.sh" >/dev/null 2>&1; then
  echo "immediately exiting container unexpectedly passed startup verification" >&2
  exit 1
fi
[[ "$(docker inspect -f '{{.Id}}' "$crash_container_name")" == "$crash_old_id" ]]
[[ "$(docker inspect -f '{{.State.Running}}' "$crash_container_name")" == "true" ]]

# volume 与 bind 必须精确恢复；目标端多余旧文件不能在重复恢复后残留。
data_bundle="${tmp}/data-bundle"
bind_target="${tmp}/bind-target"
bind_archive_root="${tmp}/bind-archive-root"
mkdir -p "${data_bundle}/volumes" "${data_bundle}/binds" "${data_bundle}/meta" \
  "${tmp}/volume-source" "$bind_target" "${bind_archive_root}${bind_target}"
printf 'new-volume-data\n' >"${tmp}/volume-source/new.txt"
ln -s new.txt "${tmp}/volume-source/safe-link"
tar -czf "${data_bundle}/volumes/vol_${data_volume_name}.tgz" \
  -C "${tmp}/volume-source" .
printf 'new-bind-data\n' >"${bind_archive_root}${bind_target}/new.txt"
ln -s new.txt "${bind_archive_root}${bind_target}/safe-link"
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
  'test "$(cat /to/new.txt)" = new-volume-data; test "$(readlink /to/safe-link)" = new.txt; test ! -e /to/old.txt; test ! -e /to/stale.txt'
[[ "$(cat "${bind_target}/new.txt")" == "new-bind-data" ]]
[[ "$(readlink "${bind_target}/safe-link")" == "new.txt" ]]
[[ ! -e "${bind_target}/old.txt" && ! -e "${bind_target}/stale.txt" ]]

docker run --rm -v "${data_volume_name}:/to" alpine:3.20 sh -c 'printf stale >/to/stale.txt'
printf 'stale-bind-data\n' >"${bind_target}/stale.txt"
(cd "$data_bundle" && bash restore.sh >/dev/null)
docker run --rm -v "${data_volume_name}:/to:ro" alpine:3.20 test ! -e /to/stale.txt
[[ ! -e "${bind_target}/stale.txt" ]]

# 同名卷后端不一致时必须在清空前失败，不能把数据写入错误的 local/NFS/plugin 后端。
volume_mismatch_bundle="${tmp}/data-bundle-volume-mismatch"
cp -a "$data_bundle" "$volume_mismatch_bundle"
jq '.volumes[0].opts = {type:"nfs",device:":/source"}' \
  "${volume_mismatch_bundle}/manifest.json" >"${volume_mismatch_bundle}/manifest.json.tmp"
mv "${volume_mismatch_bundle}/manifest.json.tmp" "${volume_mismatch_bundle}/manifest.json"
generate_bundle_checksums "$volume_mismatch_bundle"
docker run --rm -v "${data_volume_name}:/to" alpine:3.20 \
  sh -c 'printf target-driver-data >/to/driver.txt'
if (cd "$volume_mismatch_bundle" && bash restore.sh >/dev/null 2>&1); then
  echo "volume backend mismatch unexpectedly restored" >&2
  exit 1
fi
docker run --rm -v "${data_volume_name}:/to:ro" alpine:3.20 \
  test -f /to/driver.txt

# 内层归档允许安全的相对链接，但绝对/越界符号链接与跨挂载硬链接必须失败；
# 如果 bind 阶段失败，前一步已替换的 volume 也必须由全局事务恢复。
docker run --rm -v "${data_volume_name}:/to" alpine:3.20 sh -c \
  'printf target-before-unsafe >/to/target-before-unsafe.txt'
printf 'target-before-unsafe\n' >"${bind_target}/target-before-unsafe.txt"

unsafe_link_bundle="${tmp}/data-bundle-unsafe-link"
cp -a "$data_bundle" "$unsafe_link_bundle"
unsafe_link_root="${tmp}/unsafe-link-root"
mkdir -p "${unsafe_link_root}${bind_target}"
ln -s /etc/passwd "${unsafe_link_root}${bind_target}/escape"
tar -czf "${unsafe_link_bundle}/binds/bind_test.tgz" \
  -C "$unsafe_link_root" "${bind_target#/}"
generate_bundle_checksums "$unsafe_link_bundle"
if (cd "$unsafe_link_bundle" && bash restore.sh >/dev/null 2>&1); then
  echo "unsafe inner symlink archive unexpectedly restored" >&2
  exit 1
fi
docker run --rm -v "${data_volume_name}:/to:ro" alpine:3.20 \
  test -f /to/target-before-unsafe.txt
[[ -f "${bind_target}/target-before-unsafe.txt" ]]

unsafe_relative_bundle="${tmp}/data-bundle-unsafe-relative-link"
cp -a "$data_bundle" "$unsafe_relative_bundle"
unsafe_relative_root="${tmp}/unsafe-relative-root"
mkdir -p "${unsafe_relative_root}${bind_target}"
ln -s ../outside "${unsafe_relative_root}${bind_target}/escape-relative"
tar -czf "${unsafe_relative_bundle}/binds/bind_test.tgz" \
  -C "$unsafe_relative_root" "${bind_target#/}"
generate_bundle_checksums "$unsafe_relative_bundle"
if (cd "$unsafe_relative_bundle" && bash restore.sh >/dev/null 2>&1); then
  echo "bind-relative symlink escape unexpectedly restored" >&2
  exit 1
fi
docker run --rm -v "${data_volume_name}:/to:ro" alpine:3.20 \
  test -f /to/target-before-unsafe.txt
[[ -f "${bind_target}/target-before-unsafe.txt" ]]

if command -v python3 >/dev/null 2>&1; then
  unsafe_hardlink_bundle="${tmp}/data-bundle-unsafe-hardlink"
  cp -a "$data_bundle" "$unsafe_hardlink_bundle"
  python3 - "${unsafe_hardlink_bundle}/binds/bind_test.tgz" "${bind_target#/}" <<'PY'
import io
import sys
import tarfile

archive, prefix = sys.argv[1:]
with tarfile.open(archive, "w:gz") as bundle:
    parts = prefix.split("/")
    current = ""
    for part in parts:
        current = f"{current}/{part}" if current else part
        info = tarfile.TarInfo(current)
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        bundle.addfile(info)
    payload = b"safe payload\n"
    regular = tarfile.TarInfo(f"{prefix}/new.txt")
    regular.size = len(payload)
    regular.mode = 0o644
    bundle.addfile(regular, io.BytesIO(payload))
    hardlink = tarfile.TarInfo(f"{prefix}/escape-hardlink")
    hardlink.type = tarfile.LNKTYPE
    hardlink.linkname = "/etc/passwd"
    bundle.addfile(hardlink)
PY
  generate_bundle_checksums "$unsafe_hardlink_bundle"
  if (cd "$unsafe_hardlink_bundle" && bash restore.sh >/dev/null 2>&1); then
    echo "unsafe inner hardlink archive unexpectedly restored" >&2
    exit 1
  fi
  docker run --rm -v "${data_volume_name}:/to:ro" alpine:3.20 \
    test -f /to/target-before-unsafe.txt
  [[ -f "${bind_target}/target-before-unsafe.txt" ]]
fi

if docker compose version >/dev/null 2>&1; then
  compose_bundle="${tmp}/compose-bundle"
  compose_bind_target="${tmp}/compose-bind-target"
  compose_work="${compose_bind_target}/app"
  compose_bind_archive_root="${tmp}/compose-bind-archive-root"
  compose_volume_source="${tmp}/compose-volume-source"
  mkdir -p "${compose_bundle}/compose/${compose_project}" "${compose_bundle}/meta" \
    "${compose_bundle}/volumes" "${compose_bundle}/binds" "$compose_bind_target" \
    "${compose_bind_archive_root}${compose_bind_target}" "$compose_volume_source"
  printf 'source-compose-volume\n' >"${compose_volume_source}/source.txt"
  tar -czf "${compose_bundle}/volumes/vol_${compose_data_volume_name}.tgz" \
    -C "$compose_volume_source" .
  printf 'source-compose-bind\n' \
    >"${compose_bind_archive_root}${compose_bind_target}/source.txt"
  tar -czf "${compose_bundle}/binds/compose_bind.tgz" \
    -C "$compose_bind_archive_root" "${compose_bind_target#/}"
  cat >"${compose_bundle}/compose/${compose_project}/_resolved_config.yml" <<YAML
name: ${compose_project}
services:
  first:
    image: alpine:3.20
    command: ["sleep", "300"]
    environment:
      MIGRATION_TEST: merged-config
    volumes:
      - migration_data:/data
      - ${compose_bind_target}:/bind
    networks:
      - migration_external
  second:
    image: alpine:3.20
    command: ["sleep", "300"]
volumes:
  migration_data:
    external: true
    name: ${compose_data_volume_name}
networks:
  migration_external:
    external: true
    name: ${compose_external_network_name}
YAML
  jq -n \
    --arg name "$compose_project" \
    --arg working_dir "$compose_work" \
    --arg volume "$compose_data_volume_name" \
    --arg host "$compose_bind_target" \
    --arg external_network "$compose_external_network_name" \
    --arg external_subnet "172.29.${third_octet}.0/24" \
    --arg external_gateway "172.29.${third_octet}.1" \
    '{
      images:[], runs:[],
      networks:[{
        name:$external_network,driver:"bridge",internal:false,attachable:true,
        enable_ipv6:false,options:{},labels:{"migration.network":"exact"},
        ipam:{driver:"default",options:{},config:[{Subnet:$external_subnet,Gateway:$external_gateway}]}
      }],
      volumes:[{name:$volume,dest:"/data",driver:"local",opts:{}}],
      binds:[{host:$host,dest:"/bind",file:"compose_bind.tgz"}],
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
    volumes:
      - migration_data:/data
      - ${compose_bind_target}:/bind
  second:
    image: alpine:3.20
    command: ["sleep", "300"]
volumes:
  migration_data:
    external: true
    name: ${compose_data_volume_name}
YAML
  docker volume create "$compose_data_volume_name" >/dev/null
  docker run --rm -v "${compose_data_volume_name}:/to" alpine:3.20 sh -c \
    'printf old-compose-volume >/to/old.txt'
  printf 'old-compose-bind\n' >"${compose_bind_target}/old.txt"
  docker compose -f "${compose_work}/_resolved_config.yml" up -d >/dev/null
  docker run -d --name "$compose_shared_writer_name" \
    -v "${compose_data_volume_name}:/data" alpine:3.20 sh -c \
    'trap "printf shared-writer-stopped >/data/shared-stopped.txt; exit 0" TERM; while :; do sleep 1; done' \
    >/dev/null

  # fail 策略必须在停止服务、覆盖 volume/bind 之前终止。
  if (cd "$compose_bundle" && RESTORE_EXISTING=fail bash restore.sh >/dev/null 2>&1); then
    echo "RESTORE_EXISTING=fail unexpectedly mutated an existing Compose project" >&2
    exit 1
  fi
  docker run --rm -v "${compose_data_volume_name}:/to:ro" alpine:3.20 \
    test -f /to/old.txt
  [[ -f "${compose_bind_target}/old.txt" ]]
  [[ "$(docker inspect -f '{{.State.Running}}' "${compose_project}-first-1")" == "true" ]]
  [[ "$(docker inspect -f '{{.State.Running}}' "$compose_shared_writer_name")" == "true" ]]

  failed_compose_bundle="${tmp}/compose-bundle-failing"
  cp -a "$compose_bundle" "$failed_compose_bundle"
  cat >"${failed_compose_bundle}/compose/${compose_project}/_resolved_config.yml" <<YAML
name: ${compose_project}
services:
  first:
    image: alpine:3.20
    command: ["sleep", "300"]
    volumes:
      - migration_data:/data
      - ${compose_bind_target}:/bind
    networks:
      - migration_external
    healthcheck:
      test: ["CMD", "false"]
      interval: 1s
      timeout: 1s
      retries: 1
  second:
    image: alpine:3.20
    command: ["sleep", "300"]
volumes:
  migration_data:
    external: true
    name: ${compose_data_volume_name}
networks:
  migration_external:
    external: true
    name: ${compose_external_network_name}
YAML
  generate_bundle_checksums "$failed_compose_bundle"
  docker network rm "$compose_external_network_name" >/dev/null 2>&1 || true
  if (cd "$failed_compose_bundle" && RESTORE_HEALTH_TIMEOUT=5 bash restore.sh >/dev/null 2>&1); then
    echo "unhealthy Compose replacement unexpectedly succeeded" >&2
    exit 1
  fi
  [[ ! -e "${failed_compose_bundle}/compose_restore" ]]
  docker network inspect "$compose_external_network_name" | jq -e --arg subnet "172.29.${third_octet}.0/24" '
    .[0].Driver == "bridge" and .[0].Attachable == true and
    .[0].IPAM.Config[0].Subnet == $subnet and
    .[0].Labels["migration.network"] == "exact"
  ' >/dev/null
  docker inspect "${compose_project}-first-1" |
    jq -e '.[0].Config.Env | index("MIGRATION_TEST=old-config") != null' >/dev/null
  grep -Fq 'MIGRATION_TEST: old-config' "${compose_work}/_resolved_config.yml"
  ! grep -Fq 'test: ["CMD", "false"]' "${compose_work}/_resolved_config.yml"
  [[ "$(docker inspect -f '{{.State.Running}}' "${compose_project}-first-1")" == "true" ]]
  docker run --rm -v "${compose_data_volume_name}:/to:ro" alpine:3.20 sh -ec \
    'test "$(cat /to/old.txt)" = old-compose-volume; test "$(cat /to/shared-stopped.txt)" = shared-writer-stopped; test ! -e /to/source.txt'
  [[ "$(cat "${compose_bind_target}/old.txt")" == "old-compose-bind" ]]
  [[ ! -e "${compose_bind_target}/source.txt" ]]
  [[ "$(docker inspect -f '{{.State.Running}}' "$compose_shared_writer_name")" == "true" ]]

  compose_restore_output="$(cd "$compose_bundle" && bash restore.sh 2>&1)"
  [[ "$(grep -Fc 'Docker 迁移结果' <<<"$compose_restore_output")" -eq 1 ]]
  [[ "$(grep -Fc '结果：' <<<"$compose_restore_output")" -eq 1 ]]
  grep -Fq '结果：✅ 恢复成功' <<<"$compose_restore_output"
  grep -Fq '容器：2 个（运行 1 / 暂停 0 / 停止 1）' <<<"$compose_restore_output"
  ! grep -Fq '若端口被占用' <<<"$compose_restore_output"
  docker inspect "${compose_project}-first-1" |
    jq -e '.[0].Config.Env | index("MIGRATION_TEST=merged-config") != null' >/dev/null
  grep -Fq 'MIGRATION_TEST: merged-config' "${compose_work}/_resolved_config.yml"
  [[ "$(docker inspect -f '{{.State.Running}}' "${compose_project}-first-1")" == "true" ]]
  [[ "$(docker inspect -f '{{.State.Running}}' "${compose_project}-second-1")" == "false" ]]
  docker run --rm -v "${compose_data_volume_name}:/to:ro" alpine:3.20 sh -ec \
    'test "$(cat /to/source.txt)" = source-compose-volume; test ! -e /to/old.txt; test ! -e /to/shared-stopped.txt'
  [[ "$(cat "${compose_bind_target}/source.txt")" == "source-compose-bind" ]]
  [[ ! -e "${compose_bind_target}/old.txt" ]]
  [[ "$(docker inspect -f '{{.State.Running}}' "$compose_shared_writer_name")" == "true" ]]
else
  echo "skip: Docker Compose integration subtest is unavailable"
fi

# 确定性阻断 volume 回滚，验证最终摘要不会把不完整回滚误报成安全回滚。
rollback_proxy_dir="${tmp}/rollback-failure-proxy"
mkdir -p "$rollback_proxy_dir"
export REAL_DOCKER
REAL_DOCKER="$(command -v docker)"
export CLEANUP_CONTAINER="$container_name"
export DOCKER_PROXY_LOG="${tmp}/docker-proxy.log"
: >"$DOCKER_PROXY_LOG"
cat >"${rollback_proxy_dir}/docker" <<'SH'
#!/bin/sh
printf '%s:%s:%s\n' "$1" "$2" "$*" >>"${DOCKER_PROXY_LOG}"
rollback_mount="${6:-}"
if [ "$1" = "run" ] && [ "${2:-}" = "--rm" ] &&
  [ "$rollback_mount" != "${rollback_mount%/volume_data:/from:ro}" ]; then
  exit 97
fi
if [ "$1" = "rm" ] && [ "${2:-}" = "-f" ]; then
  case "${3:-}" in
    "${CLEANUP_CONTAINER}.docker-migrate-backup-"*) exit 96 ;;
  esac
fi
exec "$REAL_DOCKER" "$@"
SH
chmod +x "${rollback_proxy_dir}/docker"
proxy_probe_rc=0
"${rollback_proxy_dir}/docker" run --rm \
  -v probe:/to -v "${tmp}/probe/volume_data:/from:ro" alpine:3.20 true \
  >/dev/null 2>&1 || proxy_probe_rc=$?
[[ "$proxy_probe_rc" -eq 97 ]]
: >"$DOCKER_PROXY_LOG"

docker run -d --name "$blocker_name" -p "${host_port}:80" alpine:3.20 sleep 300 >/dev/null
incomplete_rollback_output=""
if incomplete_rollback_output="$(
  cd "$standalone_tx_bundle" &&
    PATH="${rollback_proxy_dir}:$PATH" RESTORE_HEALTH_TIMEOUT=5 bash restore.sh 2>&1
)"; then
  echo "rollback failure injection unexpectedly succeeded" >&2
  exit 1
fi
[[ "$(grep -Fc 'Docker 迁移结果' <<<"$incomplete_rollback_output")" -eq 1 ]]
[[ "$(grep -Fc '结果：' <<<"$incomplete_rollback_output")" -eq 1 ]]
if ! grep -Fq '结果：⚠️ 恢复失败，自动回滚未完全成功' \
  <<<"$incomplete_rollback_output"; then
  echo "rollback failure injection produced an unexpected final status" >&2
  printf '%s\n' "$incomplete_rollback_output" >&2
  grep -F 'volume_data' "$DOCKER_PROXY_LOG" >&2 || true
  exit 1
fi
grep -Fq '请勿直接启动相关容器' <<<"$incomplete_rollback_output"
incomplete_rollback_dir="$(sed -n 's/^回滚资料：//p' <<<"$incomplete_rollback_output" | tail -n 1)"
if [[ -z "$incomplete_rollback_dir" || ! -d "$incomplete_rollback_dir" ]]; then
  echo "rollback failure did not preserve the reported transaction directory" >&2
  printf '%s\n' "$incomplete_rollback_output" >&2
  exit 1
fi
! grep -Fq '结果：❌ 恢复失败，已安全回滚' <<<"$incomplete_rollback_output"
docker rm -f "$blocker_name" >/dev/null

# 新服务已经验证后若旧回滚点清理失败，不能误报 SUCCESS，也不能回滚已提交数据。
post_commit_output=""
if post_commit_output="$(
  cd "$standalone_tx_bundle" &&
    PATH="${rollback_proxy_dir}:$PATH" RESTORE_HEALTH_TIMEOUT=15 bash restore.sh 2>&1
)"; then
  echo "post-commit cleanup failure injection unexpectedly succeeded" >&2
  exit 1
fi
if [[ "$(grep -Fc 'Docker 迁移结果' <<<"$post_commit_output")" -ne 1 ||
"$(grep -Fc '结果：' <<<"$post_commit_output")" -ne 1 ]] ||
  ! grep -Fq '结果：⚠️ 服务与数据已恢复，但提交后的清理未完成' \
    <<<"$post_commit_output"; then
  echo "post-commit cleanup failure produced an unexpected final status" >&2
  printf '%s\n' "$post_commit_output" >&2
  grep -F 'docker-migrate-backup-' "$DOCKER_PROXY_LOG" >&2 || true
  exit 1
fi
! grep -Fq '结果：✅ 恢复成功' <<<"$post_commit_output"
post_commit_dir="$(sed -n 's/^待清理资料：//p' <<<"$post_commit_output" | tail -n 1)"
if [[ -z "$post_commit_dir" || ! -d "$post_commit_dir" ]]; then
  echo "post-commit cleanup failure did not preserve its transaction manifest" >&2
  printf '%s\n' "$post_commit_output" >&2
  exit 1
fi
if [[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" != "true" ]]; then
  echo "post-commit cleanup failure rolled back or stopped the verified new container" >&2
  printf '%s\n' "$post_commit_output" >&2
  exit 1
fi

echo "Docker integration test passed"
