#!/usr/bin/env bash
# auto_restore.sh — 输入旧机的 RID.tar.gz 链接，自动安装依赖、下载、解压并执行 restore.sh
set -euo pipefail

# ---------- Auto install deps ----------
asudo(){ if [[ $EUID -ne 0 ]]; then sudo "$@"; else "$@"; fi; }
pm_detect(){
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
  if command -v apk >/dev/null 2>&1; then echo apk; return; fi
  echo none
}
pm_install(){
  local pm="$1"; shift
  case "$pm" in
    apt)
      asudo apt-get update -y
      asudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf)    asudo dnf install -y "$@" ;;
    yum)    asudo yum install -y "$@" ;;
    zypper) asudo zypper --non-interactive install -y "$@" ;;
    apk)    asudo apk add --no-cache "$@" ;;
    *) echo "[ERR] 无法识别包管理器，手动安装：$*"; exit 1;;
  esac
}
need_bin(){
  local b="$1" p="$2"
  command -v "$b" >/dev/null 2>&1 || { echo "[INFO] 安装依赖：$b"; pm_install "$PKGMGR" $p; }
}
ensure_docker_running(){
  if ! command -v docker >/dev/null 2>&1; then return; fi
  if docker info >/dev/null 2>&1; then return; fi
  echo "[INFO] 启动 Docker 服务..."
  if command -v systemctl >/dev/null 2>&1; then
    asudo systemctl enable --now docker || true
  fi
  if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    asudo service docker start || true
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "[WARN] 尝试直接拉起 dockerd（后台）"
    if command -v dockerd >/dev/null 2>&1; then
      (asudo nohup dockerd >/var/log/dockerd.migrate.log 2>&1 &); sleep 2
    fi
  fi
  docker info >/dev/null 2>&1 || { echo "[ERR] Docker 未成功启动，请手动检查"; exit 1; }
}

PKGMGR="$(pm_detect)"
if [[ "$PKGMGR" == "none" ]]; then
  echo "[ERR] 未检测到 apt/dnf/yum/zypper/apk，请手动安装依赖：docker jq python3 tar gzip curl"
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

# ---------- Main ----------
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT

URL="${1:-}"
if [[ -z "$URL" ]]; then
  read -rp "请输入旧服务器的“一键包下载”链接（以 .tar.gz 结尾）： " URL
fi
case "$URL" in http://*|https://*) : ;; *) echo "[ERR] 非 http(s) 链接"; exit 1;; esac

echo "[INFO] 下载：$URL"
cd "$TMPDIR"
curl -fL "$URL" -o bundle.tar.gz
echo "[INFO] 大小：$(du -h bundle.tar.gz | awk '{print $1}')"

echo "[INFO] 解压..."
tar -xzf bundle.tar.gz
BUNDLE_DIR="$(tar -tzf bundle.tar.gz | head -n1 | cut -d/ -f1)"
cd "$BUNDLE_DIR"

[[ -x restore.sh ]] || chmod +x restore.sh
echo "[INFO] 执行恢复..."
bash ./restore.sh

echo "[OK] 完成。当前容器："
docker ps --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}'
