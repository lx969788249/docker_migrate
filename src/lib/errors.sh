# 常见错误识别：把 Docker、curl 等工具的英文报错翻译成“原因 + 建议”。
# 主脚本与生成的恢复脚本共用。

# 根据错误文本输出“原因<TAB>建议”；无法识别时返回 1。
explain_error() {
  local text="$1" port
  shopt -s nocasematch
  case "$text" in
    *"port is already allocated"* | *"address already in use"* | *"failed to bind host port"* | *"Bind for "*" failed"*)
      port="$(grep -oE '(Bind for [^ ]*:|host port |0\.0\.0\.0:|\]:)[0-9]+' <<<"$text" | grep -oE '[0-9]+$' | head -n1 || true)"
      printf '宿主机端口%s已被其他程序占用\t执行 ss -lntp%s 查看占用的进程，停止它或修改端口后重试\n' \
        "${port:+ ${port} }" "${port:+ | grep \":${port} \"}"
      ;;
    *"no space left on device"*)
      printf '磁盘空间不足\t执行 df -h 查看剩余空间，清理后重试（docker system prune 可以清理无用的镜像和容器）\n'
      ;;
    *"permission denied while trying to connect to the docker"*)
      printf '当前用户没有访问 Docker 的权限\t请用 root 运行，或用 sudo 运行脚本\n'
      ;;
    *"cannot connect to the docker daemon"* | *"is the docker daemon running"*)
      printf 'Docker 服务没有运行\t执行 systemctl start docker 启动 Docker 后重试\n'
      ;;
    *"exec format error"* | *"does not match the detected host platform"* | *"no matching manifest for"*)
      printf '镜像的 CPU 架构与本机不一致\t请在相同 CPU 架构（如都是 x86_64 或都是 arm64）的服务器之间迁移\n'
      ;;
    *"pull access denied"* | *"repository does not exist"* | *"manifest unknown"* | *"not found: manifest"*)
      printf '镜像仓库中找不到该镜像，或需要登录才能拉取\t检查镜像名；私有镜像请先执行 docker login\n'
      ;;
    *"tls handshake timeout"* | *"i/o timeout"* | *"client.timeout exceeded"* | *"request canceled while waiting"*)
      printf '连接镜像仓库超时\t检查服务器网络，或为 Docker 配置可用的镜像加速地址后重试\n'
      ;;
    *"is already in use by container"*)
      printf '容器名称已被其他容器占用\t删除或重命名同名容器，或设置 RESTORE_EXISTING=replace\n'
      ;;
    *"bind source path does not exist"* | *"invalid mount config"*)
      printf '挂载的宿主机路径不存在\t确认该路径在本机存在后重试\n'
      ;;
    *"could not resolve host"*)
      printf '无法解析链接中的主机名\t检查链接是否完整、DNS 是否可用\n'
      ;;
    *"failed to connect"* | *"connection refused"* | *"couldn't connect to server"*)
      printf '无法连接旧服务器的下载服务\t确认旧服务器上的脚本仍在运行，并检查旧服务器防火墙和云厂商安全组是否放行了下载端口\n'
      ;;
    *"unhealthy"* | *"did not become healthy"* | *"healthcheck timed out"*)
      printf '容器启动后健康检查没有通过\t执行 docker logs <容器名> 查看应用日志；启动较慢的服务可以调大 RESTORE_HEALTH_TIMEOUT\n'
      ;;
    *"timed out"* | *"connection reset"*)
      printf '与旧服务器的连接超时或中断\t检查两台服务器之间的网络，以及旧服务器防火墙和安全组设置，然后重试\n'
      ;;
    *"returned error: 404"* | *"404 not found"*)
      printf '下载地址不存在\t旧服务器可能已经结束传输，或链接没有完整复制；请在旧服务器重新运行备份\n'
      ;;
    *"did not remain running"*)
      printf '容器启动后立即退出\t执行 docker logs <容器名> 查看应用日志\n'
      ;;
    *"operation not permitted"* | *"permission denied"*)
      printf '权限不足\t请用 root 或 sudo 运行脚本\n'
      ;;
    *)
      shopt -u nocasematch
      return 1
      ;;
  esac
  shopt -u nocasematch
}

# 记录失败原因：能识别的报错给出具体原因和建议，否则使用调用方给出的描述。
fail_with_output() {
  local fallback="$1" output="${2:-}" row reason hint
  if [[ -n "$output" ]] && row="$(explain_error "$output")"; then
    IFS=$'\t' read -r reason hint <<<"$row"
    error_user "${fallback}：${reason}" "$hint"
  else
    error_user "$fallback" "${3:-查看下方日志中的最后几行了解详情}"
  fi
}

# 日志末尾的报错文本，用于在命令失败后识别原因。
log_tail_text() {
  [[ -n "${DM_LOG_FILE:-}" && -f "$DM_LOG_FILE" ]] || return 0
  tail -n "${1:-30}" "$DM_LOG_FILE" 2>/dev/null || true
}
