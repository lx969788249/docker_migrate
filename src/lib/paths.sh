# 挂载路径判断：重叠检测、宿主机系统路径与软链接解析。主脚本与恢复脚本共用。

mount_paths_overlap() {
  local left="$1" right="$2"
  while [[ "$left" != "/" && "$left" == */ ]]; do left="${left%/}"; done
  while [[ "$right" != "/" && "$right" == */ ]]; do right="${right%/}"; done
  [[ "$left" != "/" && "$right" != "/" ]] || return 0
  [[ "$left" == "$right" || "$left" == "${right}/"* || "$right" == "${left}/"* ]]
}

# 宿主机系统路径只在目标端重建挂载关系，不迁移其内容：这些路径属于宿主机
# 本身（时区、DNS、内核模块、伪文件系统等），覆盖目标端会破坏新服务器。
# 第一组匹配自身及其子路径；第二组是只在完全相同时才算系统路径的大目录。
SYSTEM_BIND_PREFIXES=(
  /proc /sys /dev /run /var/run /boot /lib/modules /usr/lib/modules
  /var/lib/docker /var/lib/containerd /var/log /etc/docker /etc/systemd
  /lib/systemd /usr/lib/systemd /etc/localtime /etc/timezone /usr/share/zoneinfo
  /etc/hostname /etc/hosts /etc/resolv.conf /etc/machine-id /etc/os-release
  /usr/lib/os-release /etc/passwd /etc/group /etc/shadow /etc/gshadow
  /etc/ssl /etc/pki /etc/ca-certificates
)
SYSTEM_BIND_EXACT=(
  / /etc /usr /usr/lib /usr/bin /usr/local /var /var/lib /lib /lib64 /bin /sbin
  /opt /home /root /srv /mnt /media /tmp
)

bind_path_is_system() {
  local path="$1" prefix
  [[ "$path" == "/" ]] || path="${path%/}"
  for prefix in "${SYSTEM_BIND_EXACT[@]}"; do
    [[ "$path" != "$prefix" ]] || return 0
  done
  for prefix in "${SYSTEM_BIND_PREFIXES[@]}"; do
    [[ "$path" != "$prefix" && "$path" != "${prefix}/"* ]] || return 0
  done
  return 1
}

# bind 源本身是软链接时（如 /srv/app -> /data/app），Docker 挂载的是链接目标。
# 返回真实路径，供备份真实数据；无法解析时原样返回。
bind_resolve_source() {
  local path="$1" resolved=""
  if [[ -L "$path" ]]; then
    resolved="$(realpath "$path" 2>/dev/null || readlink -f "$path" 2>/dev/null || true)"
  fi
  printf '%s\n' "${resolved:-$path}"
}
