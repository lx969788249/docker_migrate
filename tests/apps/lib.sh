# shellcheck shell=bash
# 应用的 seed.sh / verify.sh 在模拟服务器里运行，运行前会先加载这个文件。
set -euo pipefail
trap 'echo "${DM_SCRIPT:-脚本}: 第 ${LINENO} 行失败（退出码 $?）" >&2' ERR

# 等待某个地址返回期望的 HTTP 状态码（默认 200，可写成 200|302）。
wait_http() {
  local url="$1" want="${2:-200}" timeout="${3:-300}" code="" i
  for ((i = 0; i < timeout; i += 3)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"
    [[ "$code" =~ ^(${want})$ ]] && return 0
    sleep 3
  done
  echo "等待 ${url} 返回 ${want} 超时（最后一次是 ${code:-无响应}）" >&2
  return 1
}

# 反复执行命令直到成功，用于等待数据库等服务就绪。
retry() {
  local timeout="$1" i
  shift
  for ((i = 0; i < timeout; i += 3)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 3
  done
  "$@"
}

# 断言文本包含指定内容。
expect_contains() {
  local what="$1" text="$2" needle="$3"
  if [[ "$text" != *"$needle"* ]]; then
    echo "${what}：没有找到「${needle}」" >&2
    printf '%s\n' "$text" | head -n 20 >&2
    return 1
  fi
  echo "  ✓ ${what}"
}

# 按 Compose 服务名找到容器。
service_container() {
  docker ps -q --filter "label=com.docker.compose.project=$1" \
    --filter "label=com.docker.compose.service=$2" | head -n1
}
