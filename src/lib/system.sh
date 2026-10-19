# 系统工具：sudo、超时、包管理器、Docker 服务与磁盘空间。

asudo() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    "$@"
  fi
}

pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo dnf
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo yum
    return
  fi
  if command -v zypper >/dev/null 2>&1; then
    echo zypper
    return
  fi
  if command -v apk >/dev/null 2>&1; then
    echo apk
    return
  fi
  echo none
}

pm_install() {
  local pm="$1"
  shift
  case "$pm" in
    apt)
      asudo apt-get update -y
      asudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf) asudo dnf install -y "$@" ;;
    yum) asudo yum install -y "$@" ;;
    zypper) asudo zypper --non-interactive install -y "$@" ;;
    apk) asudo apk add --no-cache "$@" ;;
    *)
      RED "[ERR] 不支持的包管理器：$pm，请手动安装：$*"
      exit 1
      ;;
  esac
}

need_bin() {
  local bin="$1" pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[INFO] 安装依赖：$bin（可能耗时；如出现 sudo 密码提示，请按提示输入）"
    pm_install "$PKGMGR" "$pkg"
  fi
}

try_optional_bin() {
  local bin="$1" pkg="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  [[ "${PKGMGR:-none}" != "none" ]] || return 0
  echo "[INFO] 安装可选依赖：$bin（可能耗时；如出现 sudo 密码提示，请按提示输入）"
  pm_install "$PKGMGR" "$pkg" || true
}

ensure_docker_running() {
  if ! command -v docker >/dev/null 2>&1; then
    RED "[ERR] 未检测到 docker，请先安装 Docker 再运行本脚本。"
    exit 1
  fi

  if docker info >/dev/null 2>&1; then
    return 0
  fi

  YEL "[INFO] 尝试启动 Docker 服务..."
  if command -v systemctl >/dev/null 2>&1; then
    YEL "[INFO] 正在通过 systemctl 启动 Docker；如出现 sudo 密码提示，请按提示输入。"
    asudo systemctl enable --now docker || true
  fi
  if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    YEL "[INFO] 正在通过 service 启动 Docker；如出现 sudo 密码提示，请按提示输入。"
    asudo service docker start || true
  fi
  if ! docker info >/dev/null 2>&1; then
    YEL "[WARN] 尝试后台直接启动 dockerd ..."
    if command -v dockerd >/dev/null 2>&1; then
      asudo nohup dockerd >/var/log/dockerd.migrate.log 2>&1 &
      sleep 3
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    RED "[ERR] Docker 仍未正常启动，请手动检查后重试。"
    exit 1
  fi
}

# 目录所在文件系统的可用字节数；无法获取时输出空。
free_disk_bytes() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

# 可用空间不足 need 字节时返回 1 并打印提示；无法判断时放行。
ensure_free_space() {
  local dir="$1" need="$2" label="$3" free
  free="$(free_disk_bytes "$dir")"
  [[ "$free" =~ ^[0-9]+$ && "$need" =~ ^[0-9]+$ ]] || return 0
  ((free >= need)) && return 0
  RED "[ERR] ${label}需要约 $(human "$need") 可用空间，${dir} 所在磁盘只剩 $(human "$free")。"
  return 1
}
