# 系统工具：sudo、超时、包管理器、Docker 服务与磁盘空间。

asudo() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    sudo "$@"
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
      return 1
      ;;
  esac
}

# 安装软件包：输出写入日志、屏幕只显示进度。需要输入 sudo 密码时改为
# 前台运行，保证密码提示可见。
install_package() {
  local bin="$1" pkg="$2"
  if [[ ${EUID:-$(id -u)} -eq 0 ]] || sudo -n true 2>/dev/null; then
    DM_PROGRESS_HINT="正在通过系统包管理器安装，网络较慢时可能需要几分钟" \
      run_with_activity "安装 ${bin}" dm_quiet pm_install "$PKGMGR" "$pkg"
  else
    stage_hold
    printf '    需要安装 %s，请按提示输入 sudo 密码：\n' "$bin" >&2
    pm_install "$PKGMGR" "$pkg"
  fi
}

need_bin() {
  local bin="$1" pkg="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  if [[ "${PKGMGR:-none}" == "none" ]] || ! install_package "$bin" "$pkg" ||
    ! command -v "$bin" >/dev/null 2>&1; then
    error_user "缺少命令 ${bin}，自动安装失败" "请手动安装 ${pkg} 后重试"
    exit 1
  fi
}

try_optional_bin() {
  local bin="$1" pkg="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  [[ "${PKGMGR:-none}" != "none" ]] || return 0
  install_package "$bin" "$pkg" || detail "可选依赖 ${bin} 安装失败，继续运行"
}

ensure_docker_running() {
  local info_error
  if ! command -v docker >/dev/null 2>&1; then
    error_user "未检测到 Docker" "请先安装 Docker（https://docs.docker.com/engine/install/）再运行本脚本"
    exit 1
  fi

  if info_error="$(docker info 2>&1 >/dev/null)"; then
    return 0
  fi
  log_line "docker info 失败：${info_error}"
  if [[ "$info_error" == *"permission denied"* ]]; then
    error_user "当前用户没有访问 Docker 的权限" "请用 root 运行，或用 sudo 运行脚本"
    exit 1
  fi

  detail "Docker 未运行，尝试启动 Docker 服务"
  if command -v systemctl >/dev/null 2>&1; then
    run_with_activity "启动 Docker 服务" dm_quiet asudo systemctl enable --now docker || true
  fi
  if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    run_with_activity "启动 Docker 服务" dm_quiet asudo service docker start || true
  fi
  if ! docker info >/dev/null 2>&1; then
    detail "尝试后台直接启动 dockerd"
    if command -v dockerd >/dev/null 2>&1; then
      asudo nohup dockerd >/var/log/dockerd.migrate.log 2>&1 &
      sleep 3
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    error_user "Docker 服务无法启动" "执行 systemctl status docker 与 journalctl -u docker 查看原因"
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
  error_user "磁盘空间不足：${label}需要约 $(human "$need")，${dir} 所在磁盘只剩 $(human "$free")" \
    "执行 df -h 查看并清理磁盘后重试"
  return 1
}
