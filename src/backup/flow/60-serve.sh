#####################################
# HTTP 下载服务
#####################################
if [[ -t 0 ]]; then
  echo ""
  read -rp "HTTP 下载端口 [回车=${PORT}]： " IN_PORT || true
  if [[ -n "${IN_PORT:-}" ]]; then
    if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && ((IN_PORT >= 1 && IN_PORT <= 65535)); then
      NEW_PORT="$(pick_free_port "$IN_PORT")"
      if [[ "$NEW_PORT" != "$IN_PORT" ]]; then
        YEL "[WARN] 端口 ${IN_PORT} 已占用，改用临近可用端口：${NEW_PORT}"
      fi
      PORT="$NEW_PORT"
    else
      YEL "[WARN] 输入端口无效，继续使用默认端口：${PORT}"
    fi
  fi
fi

SECRET_TOKEN="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
BASE_URL="$(pick_advertise_url "$PORT")"
FINAL_URL="" # will be set below by the chosen HTTP server

SHPID=""

HTTP_LOG="${BUNDLE_ROOT}/http_server_${RID}.log"
: >"$HTTP_LOG"
cd "${BUNDLE_ROOT}" || exit 1

# start_http_server: multi-fallback — python3 > busybox httpd > netcat
TRANSFER_SIZE="$(stat -c%s "$TRANSFER_PATH" 2>/dev/null || stat -f%z "$TRANSFER_PATH" 2>/dev/null || echo 0)"

if command -v python3 >/dev/null 2>&1; then
  # --- Fallback 1: Python3 HTTP server (best — supports secret token + proper headers) ---
  http_log_event "启动 backend=python3 port=${PORT} file=${TRANSFER_NAME} size=${TRANSFER_SIZE}"
  python3 - "$PORT" "$SECRET_TOKEN" "$TRANSFER_NAME" >>"${HTTP_LOG}" 2>&1 <<'PY' &
import http.server
import os
from socketserver import ThreadingTCPServer
import sys

port = int(sys.argv[1])
secret = sys.argv[2]
fname = sys.argv[3]
allowed_path = "/" + secret + "/" + fname
root = os.getcwd()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        if path != allowed_path:
            self.send_response(404)
            self.end_headers()
            return
        fpath = os.path.join(root, fname)
        try:
            st = os.stat(fpath)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(st.st_size))
        self.send_header("Content-Disposition", 'attachment; filename="' + fname + '"')
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        with open(fpath, "rb") as f:
            while True:
                chunk = f.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def log_message(self, format, *args):
        message = format % args
        message = message.replace(secret, "<token>")
        sys.stderr.write(
            "%s client=%s %s\n"
            % (self.log_date_time_string(), self.client_address[0], message)
        )
        sys.stderr.flush()

import socket


class Server(ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        # 同时监听 IPv4 与 IPv6，纯 IPv6 服务器也能提供下载。
        if self.address_family == socket.AF_INET6:
            try:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except (AttributeError, OSError):
                pass
        super().server_bind()


try:
    Server.address_family = socket.AF_INET6
    httpd = Server(("::", port), Handler)
except OSError:
    Server.address_family = socket.AF_INET
    httpd = Server(("", port), Handler)

with httpd:
    httpd.serve_forever()
PY
  SHPID=$!
  FINAL_URL="${BASE_URL}/${SECRET_TOKEN}/${TRANSFER_NAME}${TRANSFER_FRAGMENT}"

elif command -v busybox >/dev/null 2>&1; then
  # --- Fallback 2: Busybox httpd (widespread on minimal/embedded systems) ---
  # 通过子目录隔离：创建一个符号链接，只暴露 tar.gz 文件而不暴露整个 bundle_root
  http_log_event "启动 backend=busybox-httpd port=${PORT} file=${TRANSFER_NAME} size=${TRANSFER_SIZE}"
  BUSYBOX_WEB="${BUNDLE_ROOT}/_bb_http_serve"
  mkdir -p "$BUSYBOX_WEB/$SECRET_TOKEN"
  printf 'Not found\n' >"$BUSYBOX_WEB/index.html"
  ln -sf "$TRANSFER_PATH" "$BUSYBOX_WEB/$SECRET_TOKEN/$TRANSFER_NAME"
  busybox httpd -f -p "$PORT" -h "$BUSYBOX_WEB" >>"${HTTP_LOG}" 2>&1 &
  SHPID=$!
  FINAL_URL="${BASE_URL}/${SECRET_TOKEN}/${TRANSFER_NAME}${TRANSFER_FRAGMENT}"

elif command -v nc >/dev/null 2>&1; then
  # --- Fallback 3: Netcat one-shot HTTP (virtually universal) ---
  http_log_event "启动 backend=netcat port=${PORT} file=${TRANSFER_NAME} size=${TRANSFER_SIZE}"
  # Build a raw HTTP response; serve the same file for any path
  cat >"${BUNDLE_ROOT}/nc_http_response.http" <<NCEOF
HTTP/1.1 200 OK
Content-Type: application/octet-stream
Content-Length: ${TRANSFER_SIZE}
Content-Disposition: attachment; filename="${TRANSFER_NAME}"
Cache-Control: no-store
X-Content-Type-Options: nosniff
Connection: close

NCEOF
  # 兼容常见 nc/ncat/BSD 参数；若全部不支持必须退出，让启动检查报告失败，
  # 不能留下一个空转但永远无法下载的后台进程。
  netcat_http_serve "$PORT" "${BUNDLE_ROOT}/nc_http_response.http" \
    "$TRANSFER_PATH" >>"${HTTP_LOG}" 2>&1 &
  SHPID=$!
  # nc fallback: no secret token — URL is just http://host:port/<file>
  FINAL_URL="${BASE_URL}/${TRANSFER_NAME}${TRANSFER_FRAGMENT}"

else
  RED "[ERR] 未找到可用的 HTTP 服务方式（python3 / busybox httpd / nc），请手动安装其一后重试。"
  exit 1
fi
HTTP_WAS_STARTED=1

cd "$WORKDIR"
sleep 1

if ! kill -0 "$SHPID" 2>/dev/null; then
  HTTP_EXIT_UNEXPECTED=1
  RED "[ERR] HTTP 服务启动失败，请检查端口 ${PORT} 或防火墙设置。"
  print_http_diagnostics_once "$HTTP_LOG"
  graceful_exit 1
fi
SOURCE_TRANSFER_PUBLISHED=1

if [[ -t 0 ]]; then
  print_transfer_instructions "$FINAL_URL" interactive
  while kill -0 "$SHPID" 2>/dev/null; do
    if read -r -t 1 _; then
      graceful_exit 0
    fi
  done
  http_wait_rc=0
  wait "$SHPID" || http_wait_rc=$?
  HTTP_EXIT_UNEXPECTED=1
  SHPID=""
  RED "[ERR] HTTP 服务在用户确认退出前意外停止（rc=${http_wait_rc}）。"
  print_http_diagnostics_once "$HTTP_LOG"
  graceful_exit 1
else
  print_transfer_instructions "$FINAL_URL" noninteractive "$$"
  http_wait_rc=0
  wait "$SHPID" || http_wait_rc=$?
  HTTP_EXIT_UNEXPECTED=1
  SHPID=""
  RED "[ERR] HTTP 服务在收到停止指令前意外退出（rc=${http_wait_rc}）。"
  print_http_diagnostics_once "$HTTP_LOG"
  graceful_exit 1
fi
