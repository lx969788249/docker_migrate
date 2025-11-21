#!/usr/bin/env bash
set -euo pipefail

# 环境变量：
# RESTORE_KEEP=1         # 恢复成功后也不删除文件
# RESTORE_CLEAN_ALL=1    # 无论成功失败都删除文件（危险）

BLUE(){ echo -e "\033[1;34m$*\033[0m"; }
YEL(){  echo -e "\033[1;33m$*\033[0m"; }
RED(){  echo -e "\033[1;31m$*\033[0m"; }
OK(){   echo -e "\033[1;32m$*\033[0m"; }

asudo(){
  if [[ $EUID -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

pm_detect(){
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf     >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum     >/devnull 2>&1; then echo yum; return; fi
  if command -v zypper  >/dev/null 2>&1; then echo zypper; return; fi
  if command -v apk     >/dev/null 2>&1; then echo apk; return; fi
  echo none
}

pm_install(){
  local pm="$1"; shift
  case "$pm" in
    apt)
      asudo apt-get update -y
      asudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf)
      asudo dnf install -y "$@"
      ;;
    yum)
      asudo yum install -y "$@"
      ;;
    zypper)
      asudo zypper --non-interactive install -y "$@"
      ;;
    apk)
      asudo apk add --no-cache "$@"
      ;;
    *)
      RED "[ERR] 不支持的包管理器：$pm，请手动安装：$*"
      return 1
      ;;
  esac
}

ensure_deps(){
  local PM; PM="$(pm_detect)"

  # 1) 基础依赖：curl / tar / jq / docker
  for bin in curl tar jq docker; do
    # 已安装则跳过
    if command -v "$bin" >/dev/null 2>&1; then
      continue
    fi

    if [[ "$PM" == "none" ]]; then
      RED "[ERR] 缺少依赖：$bin，请手动安装后再运行本脚本。"
      exit 1
    fi

    if [[ "$bin" == "docker" ]]; then
      YEL "[INFO] 未检测到 docker，尝试自动安装 ..."

      case "$PM" in
        apt)
          # Debian / Ubuntu：官方源一般提供 docker.io
          if ! pm_install "$PM" docker.io; then
            RED "[ERR] 通过 apt 安装 docker.io 失败，请手动安装 Docker 后重试。"
            exit 1
          fi
          ;;
        yum|dnf)
          # RHEL / CentOS / AlmaLinux 等：可能叫 docker 或 docker-ce
          if ! pm_install "$PM" docker; then
            pm_install "$PM" docker-ce || {
              RED "[ERR] 通过 $PM 安装 docker/docker-ce 失败，请手动安装 Docker 后重试。"
              exit 1
            }
          fi
          ;;
        zypper)
          if ! pm_install "$PM" docker; then
            RED "[ERR] 通过 zypper 安装 docker 失败，请手动安装 Docker 后重试。"
            exit 1
          fi
          ;;
        apk)
          if ! pm_install "$PM" docker; then
            RED "[ERR] 通过 apk 安装 docker 失败，请手动安装 Docker 后重试。"
            exit 1
          fi
          ;;
        *)
          RED "[ERR] 当前包管理器不支持自动安装 Docker，请手动安装。"
          exit 1
          ;;
      esac
    else
      # 普通依赖：包名 = 命令名
      YEL "[INFO] 安装依赖：$bin"
      pm_install "$PM" "$bin"
    fi
  done

  # 2) 尝试启动 docker
  if ! docker info >/dev/null 2>&1; then
    YEL "[INFO] 尝试启动 Docker 服务..."

    # systemd 场景
    if command -v systemctl >/dev/null 2>&1; then
      asudo systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    # SysV/service 场景
    if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
      asudo service docker start >/dev/null 2>&1 || true
    fi

    # 兜底：没有 service 单元，就直接后台起 dockerd
    if ! docker info >/dev/null 2>&1 && command -v dockerd >/dev/null 2>&1; then
      YEL "[INFO] 直接后台启动 dockerd（日志：/var/log/dockerd.restore.log）..."
      asudo nohup dockerd >/var/log/dockerd.restore.log 2>&1 &
      sleep 3
    fi

    # 最终检查
    if ! docker info >/dev/null 2>&1; then
      RED "[ERR] Docker 未能启动，请确认在新服务器上正确安装并配置 Docker。"
      exit 1
    fi
  fi

  # 3) 尝试确保 docker compose / docker-compose 可用（最佳努力，不强制失败）
  if docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1; then
    OK "[OK] 已检测到 Docker Compose：$(docker compose version 2>/dev/null || docker-compose version 2>/dev/null)"
  else
    YEL "[INFO] 未检测到 docker compose / docker-compose，尝试自动安装 ..."
    local PM2; PM2="$PM"
    case "$PM2" in
      apt)
        pm_install "$PM2" docker-compose || YEL "[WARN] apt 安装 docker-compose 失败，请考虑手动安装。"
        ;;
      yum|dnf)
        pm_install "$PM2" docker-compose || YEL "[WARN] $PM2 安装 docker-compose 失败，请考虑手动安装。"
        ;;
      zypper)
        pm_install "$PM2" docker-compose || YEL "[WARN] zypper 安装 docker-compose 失败，请考虑手动安装。"
        ;;
      apk)
        pm_install "$PM2" docker-compose || YEL "[WARN] apk 安装 docker-compose 失败，请考虑手动安装。"
        ;;
      *)
        YEL "[WARN] 当前环境无法自动安装 Docker Compose，请手动安装 docker compose / docker-compose。"
        ;;
    esac

    if docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1; then
      OK "[OK] Docker Compose 安装完成：$(docker compose version 2>/dev/null || docker-compose version 2>/dev/null)"
    else
      YEL "[WARN] 仍未检测到 docker compose / docker-compose，恢复时将跳过 Compose 项目（但不会影响其他容器恢复）。"
    fi
  fi
}

prompt_url(){
  local u="${1:-}"
  if [[ -z "$u" ]]; then
    read -rp "请输入迁移包下载链接（旧机输出的 .tar.gz 地址）： " u
  fi
  if [[ -z "$u" ]]; then
    RED "[ERR] 未提供下载链接"
    exit 1
  fi
  echo "$u"
}

download_bundle(){
  local url="$1"
  local outdir="$2"
  mkdir -p "$outdir"
  local fname
  fname="$(basename "$url")"
  local out="${outdir}/${fname}"

  BLUE "[INFO] 开始下载迁移包 ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    RED "[ERR] 既没有 curl 也没有 wget，无法下载。"
    exit 1
  fi

  if [[ ! -s "$out" ]]; then
    RED "[ERR] 下载的文件为空或不存在：$out"
    exit 1
  fi
  OK "[OK] 下载完成：$out"
  echo "$out"
}

extract_bundle(){
  local tgz="$1"
  local outdir="$2"

  mkdir -p "$outdir"
  BLUE "[INFO] 解压迁移包 ..."
  tar -C "$outdir" -xzf "$tgz"
  OK "[OK] 解压完成：$outdir"

  # 尝试自动找到解压后的 bundle 目录（里面有 manifest.json 和 restore.sh）
  local bdir=""
  if [[ -f "${outdir}/manifest.json" && -f "${outdir}/restore.sh" ]]; then
    bdir="$outdir"
  else
    # 找一层子目录
    local cand
    cand="$(find "$outdir" -maxdepth 2 -type f -name 'manifest.json' | head -n1 || true)"
    if [[ -n "$cand" ]]; then
      bdir="$(dirname "$cand")"
    fi
  fi

  if [[ -z "$bdir" ]]; then
    RED "[ERR] 未能在解压目录中找到 manifest.json/restore.sh，请检查迁移包是否完整。"
    exit 1
  fi

  echo "$bdir"
}

run_restore(){
  local bdir="$1"
  if [[ ! -x "${bdir}/restore.sh" ]]; then
    chmod +x "${bdir}/restore.sh" || true
  fi

  BLUE "[INFO] 即将执行恢复脚本：${bdir}/restore.sh"
  ( cd "$bdir" && ./restore.sh )
}

main(){
  BLUE "==== Docker Migrate — 自动恢复脚本 ===="

  ensure_deps

  local url
  url="$(prompt_url "${1:-}")"

  local TMPROOT
  TMPROOT="$(mktemp -d /tmp/docker-migrate-restore.XXXXXX)"

  local TGZ
  TGZ="$(download_bundle "$url" "$TMPROOT")"

  local OUTDIR
  OUTDIR="$(mktemp -d /tmp/docker-migrate-unpack.XXXXXX)"
  local BUNDLEDIR
  BUNDLEDIR="$(extract_bundle "$TGZ" "$OUTDIR")"

  BLUE "[INFO] 开始执行恢复流程 ..."
  set +e
  run_restore "$BUNDLEDIR"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    OK "[OK] 恢复脚本执行成功！当前 Docker 容器："
    docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}"
    # 自动清理（默认：删 tgz + 解压目录）
    if [[ "${RESTORE_KEEP:-0}" == "1" ]]; then
      YEL "[INFO] 已按 RESTORE_KEEP=1 保留文件：$TGZ 与 $OUTDIR"
    else
      rm -rf "$TGZ" "$OUTDIR" 2>/dev/null || true
      OK "[OK] 已清理下载文件与临时目录"
    fi
    exit 0
  else
    RED "[ERR] 恢复脚本返回非零：$rc"
    YEL "[INFO] 为便于排查，保留文件：$TGZ 与 $OUTDIR"
    if [[ "${RESTORE_CLEAN_ALL:-0}" == "1" ]]; then
      YEL "[WARN] RESTORE_CLEAN_ALL=1：仍将强制删除文件"
      rm -rf "$TGZ" "$OUTDIR" 2>/dev/null || true
      OK "[OK] 已清理下载文件与临时目录"
    fi
    exit "$rc"
  fi
}

main "$@"
