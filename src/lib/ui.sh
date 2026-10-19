# 终端输出：颜色、耗时、结果摘要与帮助信息。

result_rule() {
  printf '%s\n' '━━━━━━━━━━ Docker 迁移结果 ━━━━━━━━━━'
}

result_end_rule() {
  printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

print_restore_result_summary() {
  local status="$1" stage="$2" container_line="$3" data_line="$4"
  local cleanup_line="$5" diagnostic_dir="$6" rollback_dir="$7" elapsed="$8"

  printf '\n'
  result_rule
  case "$status" in
    SUCCESS)
      printf '结果：✅ 恢复成功\n'
      [[ -z "$container_line" ]] || printf '%s\n' "$container_line"
      [[ -z "$data_line" ]] || printf '%s\n' "$data_line"
      printf '验证：完整性校验、服务启动与健康检查均已通过\n'
      print_stage_timings
      print_warning_summary
      ;;
    FAILED_ROLLED_BACK)
      printf '结果：❌ 恢复失败，已安全回滚\n'
      printf '失败阶段：%s\n' "${stage:-未知阶段}"
      printf '新服务器：原来的服务和数据已还原\n'
      ;;
    INTERRUPTED_ROLLED_BACK)
      printf '结果：⚠️ 恢复已中断，已安全回滚\n'
      printf '中断阶段：%s\n' "${stage:-未知阶段}"
      printf '新服务器：原来的服务和数据已还原\n'
      ;;
    FAILED_ROLLBACK_INCOMPLETE | INTERRUPTED_ROLLBACK_INCOMPLETE)
      if [[ "$status" == INTERRUPTED_* ]]; then
        printf '结果：⚠️ 恢复已中断，自动回滚未完全成功\n'
        printf '中断阶段：%s\n' "${stage:-未知阶段}"
      else
        printf '结果：⚠️ 恢复失败，自动回滚未完全成功\n'
        printf '失败阶段：%s\n' "${stage:-未知阶段}"
      fi
      printf '重要：请勿直接启动相关容器，请根据保留的回滚资料人工处理\n'
      [[ -z "$rollback_dir" ]] || printf '回滚资料：%s\n' "$rollback_dir"
      ;;
    FAILED_POST_COMMIT)
      printf '结果：⚠️ 服务与数据已恢复，但提交后的清理未完成\n'
      printf '失败阶段：%s\n' "${stage:-提交清理}"
      [[ -z "$rollback_dir" ]] || printf '待清理资料：%s\n' "$rollback_dir"
      ;;
    INTERRUPTED)
      printf '结果：⚠️ 恢复已中断\n'
      printf '中断阶段：%s\n' "${stage:-未知阶段}"
      ;;
    *)
      printf '结果：❌ 恢复失败\n'
      printf '失败阶段：%s\n' "${stage:-未知阶段}"
      ;;
  esac
  [[ -z "$cleanup_line" ]] || printf '清理：%s\n' "$cleanup_line"
  [[ -z "$diagnostic_dir" ]] || printf '诊断目录：%s\n' "$diagnostic_dir"
  [[ -z "$elapsed" ]] || printf '耗时：%s\n' "$elapsed"
  print_decision_summary "${DM_RESTORE_DECISIONS:-}"
  if [[ "$status" != "SUCCESS" ]]; then
    print_warning_summary
    print_failure_details
  fi
  result_end_rule
}

print_source_result_summary() {
  local status="$1" package_line="$2" http_line="$3" source_line="$4"
  local cleanup_line="$5" elapsed="$6"

  printf '\n'
  result_rule
  case "$status" in
    SUCCESS)
      printf '结果：✅ 源端任务已安全结束\n'
      [[ -z "$source_line" ]] || printf '源容器：%s\n' "$source_line"
      [[ -z "$elapsed" ]] || printf '耗时：%s\n' "$elapsed"
      print_stage_timings
      print_warning_summary
      result_end_rule
      return 0
      ;;
    INTERRUPTED) printf '结果：⚠️ 源端任务已中断，清理流程已执行\n' ;;
    *) printf '结果：❌ 源端任务失败，清理流程已执行\n' ;;
  esac
  [[ -z "$package_line" ]] || printf '迁移包：%s\n' "$package_line"
  [[ -z "$http_line" ]] || printf 'HTTP 服务：%s\n' "$http_line"
  [[ -z "$source_line" ]] || printf '源容器：%s\n' "$source_line"
  [[ -z "$cleanup_line" ]] || printf '清理：%s\n' "$cleanup_line"
  [[ -z "$elapsed" ]] || printf '耗时：%s\n' "$elapsed"
  print_warning_summary
  print_failure_details
  result_end_rule
}

# 下载失败最常见的原因是端口没放行。只给出提示与命令，不擅自修改防火墙。
print_firewall_hint() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  printf '新服务器下载失败时，请确认旧服务器防火墙和云厂商安全组已放行 TCP %s 端口' "$port"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    printf '（检测到 ufw：ufw allow %s/tcp）' "$port"
  elif command -v firewall-cmd >/dev/null 2>&1 &&
    [[ "$(firewall-cmd --state 2>/dev/null || true)" == "running" ]]; then
    printf '（检测到 firewalld：firewall-cmd --add-port=%s/tcp）' "$port"
  fi
  printf '。\n'
}

print_transfer_instructions() {
  local url="$1" mode="${2:-interactive}" source_pid="${3:-}" port
  port="${url#*://}"
  port="${port%%/*}"
  port="${port##*:}"
  printf '\n%s\n' '━━━━━━━━━━ 迁移包已就绪 ━━━━━━━━━━'
  printf '下载链接（请完整复制）：\n%s\n\n' "$url"
  printf '使用方法：在新服务器运行同一脚本 → 选择「2) 下载备份并恢复」→ 粘贴上面的完整链接。\n'
  print_firewall_hint "$port"
  if [[ "$mode" == "interactive" ]]; then
    printf '新服务器恢复成功后，回到这个窗口按回车，停止传输并清理临时文件。\n'
  else
    printf '传输服务会一直运行；新服务器恢复完成后执行：kill -TERM %s\n' "$source_pid"
  fi
  printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

show_banner() {
  echo -e "\033[1;36m"
  cat <<'BANNER'
  ____             _               __  __ _                 _
 |  _ \  ___   ___| | _____ _ __  |  \/  (_) __ _ _ __ __ _| |_ ___
 | | | |/ _ \ / __| |/ / _ \ '__| | |\/| | |/ _` | '__/ _` | __/ _ \
 | |_| | (_) | (__|   <  __/ |    | |  | | | (_| | | | (_| | ||  __/
 |____/ \___/ \___|_|\_\___|_|    |_|  |_|_|\__, |_|  \__,_|\__\___|
                                            |___/
 ---------------------------------------------------------------
      🐳 一键备份 · 安全传输 · 完整恢复 | Docker 容器迁移工具
 ---------------------------------------------------------------
BANNER
  echo -e "\033[0m"
}

show_help() {
  cat <<'HLP'
用法:
  bash docker_migrate_perfect.sh [--backup] [--no-stop] [--include=name1,name2] [--verbose]
  bash docker_migrate_perfect.sh --restore[=URL] [--verbose]
  bash docker_migrate_perfect.sh --diagnose

  --verbose                 在屏幕上显示每一步的细节（默认只写进日志）
  --diagnose                收集系统、Docker 与最近日志，生成可附到 issue 的诊断文件
  --check=URL               只做迁移前预检（端口、磁盘、CPU 类型等），不下载也不修改任何东西

环境变量:
  PORT=8080                 HTTP 端口（被占用会自动递增）
  ADVERTISE_HOST=IP         下载链接中使用的主机名/IP
  RESTORE_EXISTING=replace  同名容器策略：replace、skip 或 fail
  RESTORE_KEEP=1            恢复后保留文件
  RESTORE_CLEAN_ALL=1       恢复失败也强制删除文件
  RESTORE_BASE=/path        自定义恢复目录
  DOCKER_MIGRATE_SNAPSHOT=auto
                            可写层快照：auto 仅在容器内有改动时快照（默认），
                            always 总是快照，never 不迁移容器内未挂载的改动
  STOP_SHARED_MOUNTS=1      非交互模式下允许临时停止共享挂载的其他容器
  DOCKER_MIGRATE_LOG_DIR    日志目录（默认 ~/docker_migrate_logs）；成功后日志自动删除，
                            失败时保留并在结果中给出路径
  DOCKER_MIGRATE_KEEP_LOG=1 成功后也保留日志
  RESTORE_AUTO_RESOLVE=1    非交互模式下，预检发现的问题自动采用推荐处理（如自动换端口）
  RESTORE_SKIP_PREFLIGHT=1  跳过迁移前预检

宿主机系统路径（如 /etc/localtime、/proc、/sys、/dev）只在新服务器重建挂载，不迁移内容。
不带参数运行时仍使用原有交互菜单。
HLP
}
