#!/usr/bin/env bash
# 两台模拟服务器之间迁移真实应用。
#
# 每台“服务器”是一个独立的 Docker-in-Docker 容器：有自己的 Docker、文件和网络，
# 新服务器上没有旧服务器的任何东西，只能通过网络从旧服务器下载迁移包。
#
# 用法：
#   tests/apps/run.sh <应用名>...    应用名就是 tests/apps/ 下的目录名
#   tests/apps/run.sh unreachable   新服务器连不上旧服务器时的提示
#
# 每个应用目录里：
#   compose.yml 等   应用本身（官方 Compose 文件，固定版本）
#   app.env          可选：APP_PROJECT（项目名，默认目录名）、NEW_MEMORY（新服务器内存上限）
#   up.sh            可选：自定义启动方式；默认 docker compose up -d --wait
#   seed.sh          在旧服务器上写入一份能认出来的数据
#   verify.sh        在新服务器上确认这份数据还在
# 设置 DM_APPS_ARTIFACTS=目录 时，失败的日志会复制到那里。
set -euo pipefail
trap 'echo "${BASH_SOURCE[0]##*/}: 第 ${LINENO} 行失败（退出码 $?）" >&2' ERR

APPS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${APPS_DIR}/../.." && pwd)"
HOST_IMAGE="docker-migrate-test-host:1"
BACKUP_PORT=18080
URL_PATTERN='http://[^[:space:]]*\.tar\.gz\.enc#sha256=[[:xdigit:]]{64}&enc=aes-256-ctr-hmac-sha256-v1&secret=[[:xdigit:]]{128}&iv=[[:xdigit:]]{32}&mac=[[:xdigit:]]{64}'

id="dmapps$$"
old="${id}_old"
new="${id}_new"
net="${id}_net"
tmp="$(mktemp -d)"
current=""

log() { printf '\n==> %s\n' "$*"; }
elapsed() { printf '%d 分 %02d 秒' $((($1) / 60)) $((($1) % 60)); }

save_artifacts() {
  [[ -n "${DM_APPS_ARTIFACTS:-}" && -n "$current" ]] || return 0
  local dest="${DM_APPS_ARTIFACTS}/${current}"
  mkdir -p "$dest"
  cp "$tmp"/*.log "$tmp"/*.json "$dest"/ 2>/dev/null || true
  for host in "$old" "$new"; do
    docker cp "${host}:/root/docker_migrate_logs" "${dest}/${host##*_}-logs" >/dev/null 2>&1 || true
    docker exec "$host" sh -c 'docker ps -a; for c in $(docker ps -aq); do echo "--- $c"; docker logs --tail 40 "$c" 2>&1; done' \
      >"${dest}/${host##*_}-containers.txt" 2>&1 || true
  done
}

remove_hosts() {
  docker rm -fv "$old" "$new" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}

cleanup() {
  local rc=$?
  ((rc == 0)) || save_artifacts
  remove_hosts
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT

# 在某台服务器上执行脚本：先加载 lib.sh，再执行给定的文件。
run_script_on() {
  local host="$1" file="$2"
  shift 2
  cat "${APPS_DIR}/lib.sh" "$file" |
    docker exec -i -e DM_SCRIPT="$(basename "$file")" "$@" "$host" bash -s
}

start_hosts() {
  local new_memory="${1:-}" host i
  docker network create "$net" >/dev/null
  docker run -d --privileged --name "$old" --hostname old \
    --network "$net" --network-alias old "$HOST_IMAGE" >/dev/null
  docker run -d --privileged --name "$new" --hostname new \
    --network "$net" --network-alias new ${new_memory:+--memory "$new_memory"} "$HOST_IMAGE" >/dev/null
  for host in "$old" "$new"; do
    for i in $(seq 1 60); do
      docker exec "$host" docker info >/dev/null 2>&1 && break
      ((i < 60)) || {
        echo "模拟服务器 ${host} 里的 Docker 没有启动" >&2
        docker logs --tail 50 "$host" >&2
        return 1
      }
      sleep 1
    done
    docker cp "${ROOT_DIR}/docker_migrate_perfect.sh" "${host}:/root/docker_migrate_perfect.sh"
  done
}

# 镜像先在本机拉取再导入旧服务器：本机有缓存时不用重复下载。
preload_images() {
  local host="$1" img
  shift
  local -a images=()
  for img in "$@"; do
    [[ -n "$img" ]] || continue
    docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null
    images+=("$img")
  done
  ((${#images[@]} > 0)) || return 0
  docker save "${images[@]}" | docker exec -i "$host" docker load -q >/dev/null
}

compose_images() {
  local dir="$1"
  (cd "$dir" && docker compose config --images 2>/dev/null) |
    while read -r img; do
      # 需要现场构建的镜像拉不到，交给 up.sh 构建。
      if docker image inspect "$img" >/dev/null 2>&1 || docker manifest inspect "$img" >/dev/null 2>&1; then
        printf '%s\n' "$img"
      fi
    done | sort -u
}

# 等容器的健康检查都有结果，避免把“启动中”的状态拿去比较。
wait_settled() {
  local host="$1" i
  for i in $(seq 1 100); do
    if ! docker exec "$host" sh -c \
      'docker ps -q | xargs -r docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{end}}"' |
      grep -q starting; then
      return 0
    fi
    sleep 3
  done
  echo "${host} 上有容器的健康检查一直没有结果" >&2
  return 1
}

dump_state() {
  docker exec -i "$1" bash -s <"${APPS_DIR}/state.sh"
}

start_backup() {
  local containers
  containers="$(docker exec "$old" docker ps -a --format '{{.Names}}' | sort | paste -sd, -)"
  docker exec -d "$old" bash -c "cd /root && PORT=${BACKUP_PORT} ADVERTISE_HOST=old \
    STOP_SHARED_MOUNTS=1 DOCKER_MIGRATE_KEEP_LOG=1 \
    bash docker_migrate_perfect.sh --backup --include='${containers}' </dev/null >/root/backup.log 2>&1"
}

wait_for_url() {
  local url="" i
  for i in $(seq 1 900); do
    docker exec "$old" cat /root/backup.log >"${tmp}/backup.log" 2>/dev/null || true
    url="$(grep -oE "$URL_PATTERN" "${tmp}/backup.log" | tail -n1 || true)"
    [[ -z "$url" ]] || break
    if grep -Fq '结果：❌' "${tmp}/backup.log" || { ((i > 5)) &&
      ! docker exec "$old" pgrep -f 'docker_migrate_perfect.sh --backup' >/dev/null; }; then
      echo "旧服务器备份失败" >&2
      tail -n 40 "${tmp}/backup.log" >&2
      return 1
    fi
    sleep 2
  done
  [[ -n "$url" ]] || {
    echo "等待下载链接超时" >&2
    tail -n 40 "${tmp}/backup.log" >&2
    return 1
  }
  printf '%s\n' "$url"
}

stop_backup() {
  local i
  docker exec "$old" pkill -TERM -f 'docker_migrate_perfect.sh --backup' || true
  for i in $(seq 1 60); do
    docker exec "$old" pgrep -f 'docker_migrate_perfect.sh --backup' >/dev/null || return 0
    sleep 1
  done
  echo "旧服务器的备份进程没有退出" >&2
  return 1
}

restore_on_new() {
  local url="$1" log="$2"
  shift 2
  docker exec -e DM_URL="$url" "$@" "$new" bash -c \
    'cd /root && RESTORE_AUTO_RESOLVE=1 DOCKER_MIGRATE_KEEP_LOG=1 bash docker_migrate_perfect.sh --restore="$DM_URL" </dev/null' \
    >"$log" 2>&1
}

compare_state() {
  local before="$1" after="$2" what="$3"
  if ! diff <(jq -S . "$before") <(jq -S . "$after") >"${tmp}/state.diff"; then
    echo "${what}：容器配置不一致" >&2
    cat "${tmp}/state.diff" >&2
    return 1
  fi
  echo "  ✓ ${what}：$(jq length "$after") 个容器的状态、端口、网络、挂载、环境变量一致"
}

run_app() {
  local app="$1" dir="${APPS_DIR}/$1" started=$SECONDS t project new_memory url
  current="$app"
  [[ -f "${dir}/seed.sh" && -f "${dir}/verify.sh" ]] || {
    echo "未知应用：${app}" >&2
    return 1
  }
  APP_PROJECT="" NEW_MEMORY=""
  # shellcheck disable=SC1091
  [[ ! -f "${dir}/app.env" ]] || source "${dir}/app.env"
  project="${APP_PROJECT:-$app}"
  new_memory="${NEW_MEMORY:-}"

  log "[${app}] 准备两台模拟服务器${new_memory:+（新服务器内存 ${new_memory}）}"
  start_hosts "$new_memory"
  mapfile -t images < <(compose_images "$dir")
  preload_images "$old" alpine:3.20 "${images[@]}"
  preload_images "$new" alpine:3.20
  docker exec "$old" mkdir -p /opt/apps
  docker cp "$dir" "${old}:/opt/apps/${app}"

  log "[${app}] 在旧服务器上启动应用并写入数据"
  t=$SECONDS
  if [[ -f "${dir}/up.sh" ]]; then
    run_script_on "$old" "${dir}/up.sh" -w "/opt/apps/${app}"
  else
    docker exec -w "/opt/apps/${app}" "$old" \
      docker compose -p "$project" up -d --wait --wait-timeout 300
  fi
  run_script_on "$old" "${dir}/seed.sh" -w "/opt/apps/${app}" -e APP_PROJECT="$project"
  wait_settled "$old"
  dump_state "$old" >"${tmp}/before.json"
  echo "  启动并写入数据用时 $(elapsed $((SECONDS - t)))"

  log "[${app}] 旧服务器备份"
  t=$SECONDS
  start_backup
  url="$(wait_for_url)"
  echo "  备份用时 $(elapsed $((SECONDS - t)))，$(grep -E '^\[[0-9]/7\]' "${tmp}/backup.log" | grep '✓' | tail -n 3 | tr '\n' ' ')"

  log "[${app}] 新服务器恢复"
  t=$SECONDS
  if ! restore_on_new "$url" "${tmp}/restore.log"; then
    echo "恢复失败" >&2
    tail -n 60 "${tmp}/restore.log" >&2
    return 1
  fi
  grep -Fq '结果：✅ 恢复成功' "${tmp}/restore.log" || {
    echo "恢复结果不是成功" >&2
    tail -n 60 "${tmp}/restore.log" >&2
    return 1
  }
  grep -E '^\[[0-9]/9\].*✓' "${tmp}/restore.log" | sed 's/^/  /'
  echo "  恢复用时 $(elapsed $((SECONDS - t)))"

  log "[${app}] 检查新服务器上的应用和数据"
  wait_settled "$new"
  run_script_on "$new" "${dir}/verify.sh" -e APP_PROJECT="$project"
  dump_state "$new" >"${tmp}/after.json"
  compare_state "${tmp}/before.json" "${tmp}/after.json" "新服务器与旧服务器"
  if docker exec "$new" docker ps -a --format '{{.Label "com.docker.compose.project"}}' |
    grep -v -x -F -e "$project" -e '' | grep -q .; then
    echo "新服务器上多出了别的 Compose 项目" >&2
    docker exec "$new" docker ps -a >&2
    return 1
  fi

  log "[${app}] 结束传输，确认旧服务器恢复原状"
  stop_backup
  wait_settled "$old"
  dump_state "$old" >"${tmp}/old-after.json"
  compare_state "${tmp}/before.json" "${tmp}/old-after.json" "旧服务器"

  remove_hosts
  current=""
  log "[${app}] 通过，总用时 $(elapsed $((SECONDS - started)))"
}

# 新服务器连不上旧服务器时，第一步就要说清楚原因，而不是重试几分钟。
run_unreachable() {
  local url t rc
  current="unreachable"
  log "[unreachable] 准备两台模拟服务器"
  start_hosts ""
  preload_images "$old" alpine:3.20
  docker exec "$old" docker run -d --name dm_probe alpine:3.20 sleep 3600 >/dev/null
  start_backup
  url="$(wait_for_url)"

  log "[unreachable] 端口被防火墙丢弃（云厂商安全组没放行时就是这样）"
  docker exec "$old" iptables -I INPUT -p tcp --dport "$BACKUP_PORT" -j DROP
  t=$SECONDS
  rc=0
  restore_on_new "$url" "${tmp}/drop.log" -e RESTORE_CONNECT_TIMEOUT=5 || rc=$?
  ((rc != 0)) || {
    echo "端口被拦截时恢复不应该成功" >&2
    return 1
  }
  ((SECONDS - t < 60)) || {
    echo "过了 $((SECONDS - t)) 秒才报错，应该很快说明原因" >&2
    return 1
  }
  grep -Fq "连接旧服务器 old 的端口 ${BACKUP_PORT} 超时" "${tmp}/drop.log"
  grep -Fq "安全组" "${tmp}/drop.log"
  grep -Fq "ufw allow ${BACKUP_PORT}/tcp" "${tmp}/drop.log"
  echo "  ✓ $((SECONDS - t)) 秒内提示：连接超时，请在安全组和防火墙放行 TCP ${BACKUP_PORT}"

  log "[unreachable] 端口被防火墙拒绝"
  docker exec "$old" iptables -D INPUT -p tcp --dport "$BACKUP_PORT" -j DROP
  docker exec "$old" iptables -I INPUT -p tcp --dport "$BACKUP_PORT" -j REJECT --reject-with tcp-reset
  rc=0
  restore_on_new "$url" "${tmp}/reject.log" -e RESTORE_CONNECT_TIMEOUT=5 || rc=$?
  ((rc != 0))
  grep -Fq "旧服务器 old 的端口 ${BACKUP_PORT} 拒绝连接" "${tmp}/reject.log"
  grep -Fq "ufw allow ${BACKUP_PORT}/tcp" "${tmp}/reject.log"
  echo "  ✓ 提示：拒绝连接，请确认脚本还在运行并放行端口"

  log "[unreachable] 放行后同一个链接可以正常使用"
  docker exec "$old" iptables -D INPUT -p tcp --dport "$BACKUP_PORT" -j REJECT --reject-with tcp-reset
  docker exec -e DM_URL="$url" "$new" bash -c \
    'cd /root && bash docker_migrate_perfect.sh --check="$DM_URL" </dev/null' >"${tmp}/check.log" 2>&1
  grep -Fq '预检通过' "${tmp}/check.log"
  echo "  ✓ 预检通过"

  stop_backup
  remove_hosts
  current=""
  log "[unreachable] 通过"
}

(($# > 0)) || {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}
for bin in docker jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "需要 ${bin}" >&2
    exit 1
  }
done
docker build -q -t "$HOST_IMAGE" -f "${APPS_DIR}/host.Dockerfile" "$APPS_DIR" >/dev/null

for target in "$@"; do
  case "$target" in
    unreachable) run_unreachable ;;
    *) run_app "$target" ;;
  esac
done
