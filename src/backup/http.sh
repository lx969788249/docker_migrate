# 源端 HTTP 下载服务与对外地址探测。

http_log_event() {
  local message="$1"
  [[ -n "${HTTP_LOG:-}" ]] || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$message" >>"$HTTP_LOG"
}

print_http_diagnostics() {
  local log_file="${1:-}"
  printf 'HTTP 服务诊断（最后 20 行）：\n' >&2
  if [[ -n "$log_file" && -s "$log_file" ]]; then
    tail -n 20 "$log_file" >&2 || true
  else
    printf 'HTTP 服务未提供额外日志。\n' >&2
  fi
  [[ -z "$log_file" ]] || printf '完整日志：%s\n' "$log_file" >&2
}

print_http_diagnostics_once() {
  local log_file="${1:-}"
  ((${HTTP_DIAGNOSTICS_SHOWN:-0} == 0)) || return 0
  HTTP_DIAGNOSTICS_SHOWN=1
  print_http_diagnostics "$log_file"
}

netcat_http_serve() {
  local port="$1" response_file="$2" transfer_file="$3"
  while true; do
    if {
      cat "$response_file"
      cat "$transfer_file"
    } | nc -l -p "$port" -q 0; then
      continue
    fi
    if {
      cat "$response_file"
      cat "$transfer_file"
    } | nc -l -p "$port"; then
      continue
    fi
    if {
      cat "$response_file"
      cat "$transfer_file"
    } | nc -l "$port"; then
      continue
    fi
    return 1
  done
}

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  [[ "$ip" =~ ^127\. ]] && return 0
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  return 1
}

get_public_ip_external() {
  local ip
  for svc in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
    ip="$(curl -fsS --max-time 2 "$svc" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

get_public_ipv6() {
  local ip
  ip="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  if [[ "$ip" == *:* && "$ip" != fe80:* && "$ip" != fd* && "$ip" != fc* && "$ip" != ::1 ]]; then
    echo "$ip"
    return 0
  fi
  ip="$(curl -6 -fsS --max-time 2 https://api64.ipify.org 2>/dev/null | tr -d '\r\n' || true)"
  if [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:* ]]; then
    echo "$ip"
    return 0
  fi
  return 1
}

# URL 中的 IPv6 地址必须加方括号，否则端口会被当成地址的一部分。
url_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[* ]]; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
}

pick_advertise_url() {
  local port="$1"
  local host=""
  if [[ -n "${ADVERTISE_HOST:-}" ]]; then
    host="$ADVERTISE_HOST"
  else
    local via_route=""
    via_route="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if [[ -n "$via_route" ]] && ! is_private_ipv4 "$via_route"; then
      host="$via_route"
    fi
    [[ -z "$host" ]] && host="$(get_public_ip_external || true)"
    # 纯 IPv6 服务器没有可用的 IPv4 地址。
    [[ -z "$host" ]] && host="$(get_public_ipv6 || true)"
    [[ -z "$host" ]] && host="$(ip -4 -o addr show 2>/dev/null | awk '!/ lo| docker| veth| br-| kube/ {print $4}' | cut -d/ -f1 | head -n1 || true)"
    if [[ -z "$host" ]]; then
      host="127.0.0.1"
      YEL "[WARN] 无法探测本机对外地址，链接暂用 127.0.0.1，新服务器无法访问；请用 ADVERTISE_HOST=公网IP或域名 重新运行。" >&2
    fi
  fi
  echo "http://$(url_host "$host"):${port}"
}

pick_free_port() {
  local p="${1:-8080}"
  local i
  for i in $(seq 0 50); do
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
        echo "$p"
        return 0
      fi
    elif command -v netstat >/dev/null 2>&1; then
      if ! netstat -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
        echo "$p"
        return 0
      fi
    else
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  echo "${1:-8080}"
}
