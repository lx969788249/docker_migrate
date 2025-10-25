#!/usr/bin/env bash
# auto_restore.sh — 输入旧机的 RID.tar.gz 链接，自动下载、解压并执行 restore.sh
set -euo pipefail
need(){ command -v "$1" >/dev/null 2>&1 || { echo "[ERR] need: $1"; exit 1; }; }
need curl; need tar; need jq; need docker

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
