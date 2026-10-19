#!/usr/bin/env bash
# 把 src/ 下的模块合并成单文件发布脚本 docker_migrate_perfect.sh。
#
# 源码中独占一行的 `# @include 相对路径` 会被替换为对应文件（相对 src/）的内容，
# 可以嵌套，也可以写在 heredoc 模板内部——生成的恢复脚本由此复用同一份公共函数。
#
# 用法：
#   ./build.sh           重新生成 docker_migrate_perfect.sh
#   ./build.sh --check   只检查已提交的发布文件是否与 src/ 一致（CI 使用）
#
# 只依赖 bash 3.2+ 内置功能，macOS 自带 bash 也可以运行。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${ROOT_DIR}/src"
OUTPUT="${ROOT_DIR}/docker_migrate_perfect.sh"
INCLUDE_STACK=" "

expand() {
  local rel="$1" path line target
  path="${SRC_DIR}/${rel}"
  if [[ ! -f "$path" ]]; then
    echo "build.sh: 找不到被引用的文件：src/${rel}" >&2
    return 1
  fi
  case "$INCLUDE_STACK" in
    *" ${rel} "*)
      echo "build.sh: 检测到循环引用：src/${rel}" >&2
      return 1
      ;;
  esac
  INCLUDE_STACK="${INCLUDE_STACK}${rel} "
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "# @include "* ]]; then
      target="${line#\# @include }"
      expand "$target" || return 1
    else
      printf '%s\n' "$line"
    fi
  done <"$path"
  INCLUDE_STACK="${INCLUDE_STACK% "${rel}" }"
  INCLUDE_STACK="${INCLUDE_STACK} "
}

generated="$(mktemp "${TMPDIR:-/tmp}/docker_migrate_build.XXXXXX")"
trap 'rm -f "$generated"' EXIT
expand main.sh >"$generated"

if [[ "${1:-}" == "--check" ]]; then
  if ! cmp -s "$generated" "$OUTPUT"; then
    echo "docker_migrate_perfect.sh 与 src/ 不一致，请运行 ./build.sh 并提交结果：" >&2
    diff -u "$OUTPUT" "$generated" | head -n 40 >&2 || true
    exit 1
  fi
  echo "docker_migrate_perfect.sh 与 src/ 一致"
  exit 0
fi

cp "$generated" "$OUTPUT"
chmod +x "$OUTPUT"
echo "已生成 docker_migrate_perfect.sh（$(wc -l <"$OUTPUT" | tr -d ' ') 行）"
