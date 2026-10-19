# --diagnose：收集排查问题所需的信息，生成一个可以直接附到 issue 里的文件。
# 只读取信息，不改动任何容器或数据；写入前统一隐藏密钥与密码。

diagnose_section() {
  printf '\n===== %s =====\n' "$1"
}

run_diagnose() {
  local out log_dir restore_dir file
  out="${PWD}/docker_migrate_diagnose-$(date +%Y%m%d-%H%M%S).txt"
  log_dir="${DOCKER_MIGRATE_LOG_DIR:-${HOME:-/tmp}/docker_migrate_logs}"
  restore_dir="${RESTORE_BASE:-${HOME:-/tmp}/docker_migrate_restore}"
  printf '正在收集诊断信息……\n' >&2
  {
    # 收集过程中个别命令失败（目录不存在、工具未安装）是正常的，不能中断整份报告。
    set +e +o pipefail
    log_environment diagnose
    diagnose_section "Docker 信息"
    docker info 2>&1 | head -n 80
    diagnose_section "容器"
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1
    diagnose_section "网络"
    docker network ls 2>&1
    diagnose_section "数据卷"
    docker volume ls 2>&1
    diagnose_section "磁盘"
    df -h 2>&1
    diagnose_section "监听端口"
    { ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null || echo "ss / netstat 均不可用"; } | head -n 60
    diagnose_section "防火墙"
    if command -v ufw >/dev/null 2>&1; then ufw status 2>&1; fi
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --state 2>&1
      firewall-cmd --list-ports 2>&1
    fi
    diagnose_section "最近的运行日志（最多 3 份，每份最后 300 行）"
    if [[ -d "$log_dir" ]]; then
      while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        printf -- '--- %s\n' "$file"
        tail -n 300 "$file" 2>&1
      done < <(ls -1t "$log_dir"/*.log 2>/dev/null | head -n 3)
    else
      echo "没有找到日志目录：$log_dir"
    fi
    diagnose_section "恢复工作目录"
    ls -la "$restore_dir" 2>&1 | head -n 30
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      printf -- '--- %s\n' "$file"
      cat "$file" 2>&1
    done < <(find "$restore_dir" -maxdepth 2 -name 'restore-result.json' 2>/dev/null | head -n 5)
    diagnose_section "回滚资料目录"
    ls -la "${RESTORE_ROLLBACK_BASE:-${HOME:-/tmp}/.docker_migrate_rollback}" 2>&1 | head -n 30
  } 2>&1 | log_redact >"$out"
  chmod 600 "$out" 2>/dev/null || true
  printf '诊断文件已生成：%s\n' "$out" >&2
  printf '提交 issue 时请附上这个文件。密钥与密码已自动隐藏，上传前也建议自己再检查一遍。\n' >&2
}
