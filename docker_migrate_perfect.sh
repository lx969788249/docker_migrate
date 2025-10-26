#!/usr/bin/env bash
# docker_migrate_perfect.sh — 处理 Docker 容器备份与恢复的脚本
set -euo pipefail

# ---------- Auto install deps ----------
asudo(){ if [[ $EUID -ne 0 ]]; then sudo "$@"; else "$@"; fi; }
pm_detect(){ if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
             if command -v dnf     >/dev/null 2>&1; then echo dnf; return; fi
             if command -v yum     >/dev/null 2>&1; then echo yum; return; fi
             if command -v zypper  >/dev/null 2>&1; then echo zypper; return; fi
             if command -v apk     >/dev/null 2>&1; then echo apk; return; fi
             echo none; }
pm_install(){
  local pm="$1"; shift
  case "$pm" in
    apt)    asudo apt-get update -y; asudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@";;
    dnf)    asudo dnf install -y "$@";;
    yum)    asudo yum install -y "$@";;
    zypper) asudo zypper --non-interactive install -y "$@";;
    apk)    asudo apk add --no-cache "$@";;
    *) echo "[ERR] 无法识别包管理器，手动安装：$*"; exit 1;;
  esac
}
need_bin(){ local b="$1" p="$2"; command -v "$b" >/dev/null 2>&1 || { echo "[INFO] 安装依赖：$b"; pm_install "$PKGMGR" $p; }; }
ensure_docker_running(){
  if ! command -v docker >/dev/null 2>&1; then return; fi
  if docker info >/dev/null 2>&1; then return; fi
  echo "[INFO] 启动 Docker 服务..."
  if command -v systemctl >/dev/null 2>&1; then asudo systemctl enable --now docker || true; fi
  if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then asudo service docker start || true; fi
  if ! docker info >/dev/null 2>&1; then
    echo "[WARN] 尝试直接拉起 dockerd（后台）"
    if command -v dockerd >/dev/null 2>&1; then (asudo nohup dockerd >/var/log/dockerd.migrate.log 2>&1 &); sleep 2; fi
  fi
  docker info >/dev/null 2>&1 || { echo "[ERR] Docker 未成功启动，请手动检查"; exit 1; }
}

PKGMGR="$(pm_detect)"
if [[ "$PKGMGR" == "none" ]]; then
  echo "[ERR] 未检测到 apt/dnf/yum/zypper/apk，请手动安装依赖：docker jq python3 tar gzip curl"
  exit 1
fi

case "$PKGMGR" in
  apt) need_bin curl curl; need_bin jq jq; need_bin python3 python3; need_bin tar tar; need_bin gzip gzip; need_bin docker docker.io;;
  yum|dnf)
    need_bin curl curl; need_bin jq jq; need_bin python3 python3; need_bin tar tar; need_bin gzip gzip
    if ! command -v docker >/dev/null 2>&1; then pm_install "$PKGMGR" docker || pm_install "$PKGMGR" docker-ce || true; fi;;
  zypper) need_bin curl curl; need_bin jq jq; need_bin python3 python3; need_bin tar tar; need_bin gzip gzip; need_bin docker docker;;
  apk)    need_bin curl curl; need_bin jq jq; need_bin python3 python3; need_bin tar tar; need_bin gzip gzip; need_bin docker docker;;
esac
ensure_docker_running

# ---------- UI helpers ----------
BLUE(){ echo -e "\033[1;34m$*\033[0m"; }
YEL(){ echo -e "\033[1;33m$*\033[0m"; }
RED(){ echo -e "\033[1;31m$*\033[0m"; }
OK(){  echo -e "\033[1;32m$*\033[0m"; }

human(){ # bytes -> human
  local b=$1; local u=(B KB MB GB TB PB); local i=0
  while (( b>=1024 && i<${#u[@]}-1 )); do b=$((b/1024)); i=$((i+1)); done
  echo "${b}${u[$i]}"
}

spinner_run(){ local msg="$1"; shift; local spin='-\|/' i=0
  printf "%s " "$msg"
  ( "$@" ) & local cmd_pid=$!
  while kill -0 "$cmd_pid" 2>/dev/null; do i=$(( (i+1)%4 )); printf "\r%s %s" "$msg" "${spin:$i:1}"; sleep 0.15; done
  wait "$cmd_pid"; printf "\r%s 完成\n" "$msg"
}

# --- images.tar 进度（pv优先，其次stat轮询） ---
progress_docker_save(){
  local outfile="$1"; shift
  if command -v pv >/dev/null 2>&1; then
    "$@" | pv -b > "$outfile"
  else
    "$@" > "$outfile" &
    local pid=$!
    local last=0 cur=0
    printf "[进度] images.tar "
    while kill -0 "$pid" 2>/dev/null; do
      if [[ -f "$outfile" ]]; then
        cur=$(stat -c %s "$outfile" 2>/dev/null || echo 0)
        if (( cur!=last )); then
          printf "\r[进度] images.tar 已写入：%s" "$(human "$cur")"
          last=$cur
        else
          printf "\r[进度] images.tar 写入中 ..."
        fi
      else
        printf "\r[进度] images.tar 准备中 ..."
      fi
      sleep 1
    done
    wait "$pid" || true
    cur=$(stat -c %s "$outfile" 2>/dev/null || echo 0)
    printf "\r[进度] images.tar 完成：%s\n" "$(human "$cur")"
  fi
}

# ---------- IP / URL（只输出一个最终URL，公网优先） ---
is_private_ipv4(){ local ip="$1"
  [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|^127\.|^169\.254\. ]] && return 0 || return 1; }
get_public_ip_external(){ local ip
  for svc in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
    ip="$(curl -fsS --max-time 2 "$svc" 2>/dev/null | tr -d '\r\n' || true)"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done; return 1; }
pick_advertise_url(){
  local port="$1" rid="$2" host=""
  if [[ -n "${ADVERTISE_HOST:-}" ]]; then host="$ADVERTISE_HOST"
  else
    local via_route; via_route="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    if [[ -n "$via_route" ]] && ! is_private_ipv4 "$via_route"; then host="$via_route"; fi
    [[ -z "$host" ]] && host="$(get_public_ip_external || true)"
    [[ -z "$host" ]] && host="$(ip -4 -o addr show 2>/dev/null | awk '!/ lo| docker| veth| br-| kube/ {print $4}' | cut -d/ -f1 | head -n1)"
    : "${host:=127.0.0.1}"
  fi
  echo "http://${host}:${port}/${rid}.tar.gz"
}

pick_free_port(){ local p="${1:-8080}"; for _ in $(seq 0 50); do ss -lnt 2>/dev/null|awk '{print $4}'|grep -q ":$p$"||{ echo "$p"; return; }; p=$((p+1)); done; echo "$1"; }

# ---------- Args ----------
NO_STOP="0"; INCLUDE_LIST=""
for arg in "$@"; do
  case "$arg" in
    --no-stop) NO_STOP="1" ;;
    --include=*) INCLUDE_LIST="${arg#*=}" ;;
    --include) shift; INCLUDE_LIST="${1:-}" ;;
    -h|--help)
cat <<'HLP'
用法:
  bash docker_migrate_perfect.sh [--no-stop] [--include=name1,name2]
环境变量:
  PORT=8080            # HTTP 端口（默认 8080；被占用会自动递增）
  ADVERTISE_HOST=IP    # 用于生成下载链接（优先级最高）
HLP
      exit 0;;
  esac
done

# ---------- dirs & ids ----------
PORT="$(pick_free_port "${PORT:-8080}")"
WORKDIR="$(pwd)"; STAMP="$(date +%Y%m%d-%H%M%S)"
RID="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 10)"
BUNDLE="${WORKDIR}/bundle/${RID}"
mkdir -p "${BUNDLE}"/{runs,volumes,binds,compose,meta}
BLUE "[INFO] Bundle: ${BUNDLE}"

# ---------- select containers ----------
mapfile -t ALL_IDS < <(docker ps --format '{{.ID}}')
((${#ALL_IDS[@]})) || { RED "[ERR] 没有运行中的容器"; exit 1; }

declare -a IDS
if [[ -n "$INCLUDE_LIST" ]]; then
  IFS=',' read -r -a NAMES <<<"$INCLUDE_LIST"
  for n in "${NAMES[@]}"; do n="$(echo "$n"|xargs)"; id=$(docker ps --filter "name=^${n}$" --format '{{.ID}}' | head -n1 || true)
    [[ -n "$id" ]] && IDS+=("$id") || YEL "[WARN] 未找到容器：$n"; done
  ((${#IDS[@]})) || { RED "[ERR] --include 未匹配到任何容器"; exit 1; }
else
  BLUE "[INFO] 当前运行容器："; docker ps --format '  {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  read -rp $'\n请选择容器 [回车=全部 / 或输入逗号分隔的名字]： ' PICK
  if [[ -z "$PICK" ]]; then IDS=("${ALL_IDS[@]}"); else
    IFS=',' read -r -a NAMES <<<"$PICK"
    for n in "${NAMES[@]}"; do n="$(echo "$n"|xargs)"; id=$(docker ps --filter "name=^${n}$" --format '{{.ID}}' | head -n1 || true)
      [[ -n "$id" ]] && IDS+=("$id") || YEL "[WARN] 未找到容器：$n"; done
    ((${#IDS[@]})) || { RED "[ERR] 未选择任何容器"; exit 1; }
  fi
fi

# ---------- discovery ----------
BLUE "[INFO] 采集元数据 ..."
declare -A IMGSET=() NETWORKS=() CONTAINER_NAME=() CONTAINER_IS_COMPOSE=()
declare -A PROJECT_KEY_OF=() COMPOSE_GROUP=() COMPOSE_CFGS=() SINGLETONS=()

for id in "${IDS[@]}"; do
  j="$(docker inspect "$id")"
  name=$(jq -r '.[0].Name|ltrimstr("/")' <<<"$j")
  img=$(jq -r '.[0].Config.Image' <<<"$j")
  IMGSET["$img"]=1; CONTAINER_NAME["$id"]="$name"
  mapfile -t nets < <(jq -r '.[0].NetworkSettings.Networks|keys[]?' <<<"$j" || true)
  for n in "${nets[@]}"; do case "$n" in bridge|host|none) :;; *) NETWORKS["$n"]=1;; esac; done
  proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
  wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")
  cfgs=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$j")
  if [[ -n "$proj" && -n "$wdir" ]]; then
    key="${proj}|${wdir}"; COMPOSE_GROUP["$key"]=1; [[ -n "$cfgs" ]] && COMPOSE_CFGS["$key"]="$cfgs"
    PROJECT_KEY_OF["$id"]="$key"; CONTAINER_IS_COMPOSE["$id"]=1
  else
    PROJECT_KEY_OF["$id"]=""; CONTAINER_IS_COMPOSE["$id"]=0; SINGLETONS["$name"]=1
  fi
  echo "$j" > "${BUNDLE}/meta/${name}.inspect.json"
done

# ---------- stop window ----------
STOPPED_ON_BACKUP=()
if [[ "$NO_STOP" == "1" ]]; then
  YEL "[WARN] --no-stop：不停机备份，可能不一致（数据库尤需注意）"
else
  read -rp "是否现在停机以确保一致性备份？[Y/n] " STOPNOW; STOPNOW=${STOPNOW:-Y}
  if [[ "$STOPNOW" =~ ^[Yy]$ ]]; then
    total=${#IDS[@]}; idx=0
    for id in "${IDS[@]}"; do
      idx=$((idx+1)); n="${CONTAINER_NAME[$id]}"
      printf "[停机] (%d/%d) %s ..." "$idx" "$total" "$n"
      if docker stop "$n" >/dev/null 2>&1; then
        STOPPED_ON_BACKUP+=("$n"); printf " ok\n"
      else
        printf " fail\n"
      fi
    done
  else
    YEL "[WARN] 你选择了不停机备份"
  fi
fi

# ---------- pack volumes & binds ----------
BLUE "[INFO] 备份卷与绑定目录 ..."
declare -a MAN_VOL=() MAN_BIND=()
# 预统计总数
vol_count=0; bind_count=0
for id in "${IDS[@]}"; do
  n="${CONTAINER_NAME[$id]}"; j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
  vol_count=$((vol_count + $(jq -r '.[0].Mounts[]? | select(.Type=="volume") | 1' <<<"$j" | wc -l || echo 0)))
  bind_count=$((bind_count + $(jq -r '.[0].Mounts[]? | select(.Type=="bind")   | 1' <<<"$j" | wc -l || echo 0)))
done
v_idx=0; b_idx=0

# ---------- 处理卷与绑定目录 ----------
for id in "${IDS[@]}"; do
  n="${CONTAINER_NAME[$id]}"; j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
  while IFS= read -r m; do [[ -z "$m" ]] && continue
    t=$(jq -r '.Type' <<<"$m"); dest=$(jq -r '.Destination' <<<"$m")
    case "$t" in
      volume)
        v_idx=$((v_idx+1))
        vname=$(jq -r '.Name' <<<"$m"); printf "  [VOL] (%d/%d) %s :: %s -> %s\n" "$v_idx" "$vol_count" "$n" "$vname" "$dest"
        out="${BUNDLE}/volumes/vol_${vname}.tgz"
        docker run --rm -v "${vname}:/from:ro" -v "${BUNDLE}/volumes:/to" alpine:3.20 sh -c "cd /from && tar -czf /to/$(basename "$out") ."
        MAN_VOL+=("{\"name\":\"${vname}\",\"dest\":\"${dest}\"}") ;;
      bind)
        b_idx=$((b_idx+1))
        src=$(jq -r '.Source' <<<"$m"); esc=$(echo "$src"|sed 's#/#_#g'|sed 's/^_//'); out="${BUNDLE}/binds/bind_${esc}.tgz"
        printf "  [BIND] (%d/%d) %s :: %s -> %s\n" "$b_idx" "$bind_count" "$n" "$src" "$dest"
        mkdir -p "$(dirname "$out")"
        tar -C / -czf "$out" "${src#/}" 2>/dev/null || { YEL "    跳过不可读路径：$src"; continue; }
        MAN_BIND+=("{\"host\":\"${src}\",\"dest\":\"${dest}\",\"file\":\"$(basename "$out")\"}") ;;
      *) YEL "  [SKIP] mount=$t dest=$dest" ;;
    esac
  done < <(jq -c '.[0].Mounts[]?' <<<"$j")
done

# -------- save images（带实时进度） --------
BLUE "[INFO] 保存镜像 images.tar ..."
mapfile -t IMAGES < <(printf "%s\n" "${!IMGSET[@]}" | sort -u)
if ((${#IMAGES[@]})); then
  OUT_IMG="${BUNDLE}/images.tar"
  progress_docker_save "${OUT_IMG}" docker image save "${IMAGES[@]}"
  OK "[OK] images.tar 已生成，大小：$(du -h "${OUT_IMG}" | awk '{print $1}')"
else
  YEL "[WARN] 未收集到镜像名？"
fi

# -------- 生成 manifest.json 与 restore.sh --------
generate_manifest_and_restore(){
  mapfile -t NETLIST < <(printf "%s\n" "${!NETWORKS[@]}" | sort -u)
  declare -a MAN_PROJECTS=()
  for key in "${!COMPOSE_GROUP[@]}"; do
    proj="${key%%|*}"; wdir="${key#*|}"
    files_json="[]"
    if ls -1 "${BUNDLE}/compose/${proj}/" >/dev/null 2>&1; then
      mapfile -t FLS < <(ls -1 "${BUNDLE}/compose/${proj}/" 2>/dev/null || true)
      ((${#FLS[@]})) && files_json=$(printf "\"%s\"," "${FLS[@]}" | sed 's/,$//' | awk '{print "["$0"]"}')
    fi
    MAN_PROJECTS+=("{\"name\":\"${proj}\",\"working_dir\":\"${wdir}\",\"files\":${files_json}}")
  done

  {
    echo "{"
    echo "  \"created_at\": \"${STAMP}\","
    echo "  \"bundle_id\": \"${RID}\","
    echo "  \"images\": [$(printf "\"%s\"," "${IMAGES[@]}" | sed 's/,$//')],"
    echo "  \"networks\": [$(printf "\"%s\"," "${NETLIST[@]}" | sed 's/,$//')],"
    echo "  \"projects\": [$(printf "%s," "${MAN_PROJECTS[@]}" | sed 's/,$//')],"
    echo "  \"volumes\": [$(printf "%s," "${MAN_VOL[@]}" | sed 's/,$//')],"
    echo "  \"binds\": [$(printf "%s," "${MAN_BIND[@]}" | sed 's/,$//')],"
    echo "  \"runs\": [$(printf "\"%s\"," "${RUNS[@]}" | sed 's/,$//')]"
    echo "}"
  } > "${BUNDLE}/manifest.json"

  cat > "${BUNDLE}/restore.sh" <<'REST_SH'
#!/usr/bin/env bash
set -euo pipefail
BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$BUNDLE_DIR"
say(){ echo -e "\033[1;34m$*\033[0m"; }; warn(){ echo -e "\033[1;33m$*\033[0m"; }

say "[A] 加载镜像（如 images.tar 存在）"
[[ -f images.tar ]] && docker load -i images.tar || warn "images.tar 不存在，将按需在线拉取镜像"

say "[B] 创建自定义网络（如有）"
if jq -e ".networks|length>0" manifest.json >/dev/null; then
  for n in $(jq -r ".networks[]" manifest.json); do case "$n" in bridge|host|none) :;; *) docker network create "$n" >/dev/null 2>&1 || true;; esac; done
fi

say "[C] 回灌命名卷"
if jq -e ".volumes|length>0" manifest.json >/dev/null; then
  mkdir -p volumes
  while IFS= read -r row; do
    vname=$(jq -r ".name" <<<"$row"); file="vol_${vname}.tgz"
    [[ -f "volumes/$file" ]] || { warn "  跳过 $vname（缺少 volumes/$file）"; continue; }
    echo "  - ${vname}"
    docker volume create "$vname" >/dev/null 2>&1 || true
    docker run --rm -v "${vname}:/to" -v "$PWD/volumes:/from" alpine:3.20 sh -c "cd /to && tar -xzf /from/${file}"
  done < <(jq -c ".volumes[]" manifest.json)
fi

say "[D] 回灌绑定目录"
if jq -e ".binds|length>0" manifest.json >/dev/null; then
  mkdir -p binds
  while IFS= read -r row; do
    host=$(jq -r ".host" <<<"$row")
    file=$(jq -r ".file" <<<"$row")
    echo "  - ${host}"

    # 只创建父目录，兼容文件型绑定（例如 /etc/localtime）
    parent="$(dirname "$host")"
    mkdir -p "$parent" || true

    # 归档按绝对路径制作，直接从根解包覆盖/写入
    tar -C / -xzf "binds/${file}"
  done < <(jq -c ".binds[]" manifest.json)
fi

say "[E] 恢复 Compose 项目"
if jq -e ".projects|length>0" manifest.json >/dev/null; then
  mkdir -p compose_restore
  while IFS= read -r row; do
    name=$(jq -r ".name" <<<"$row"); echo "  - project: $name"; mkdir -p "compose_restore/${name}"
    if compgen -G "compose/${name}/*.tgz" >/dev/null; then
      for t in compose/${name}/*.tgz; do tar -xzf "$t" -C "compose_restore/${name}" 2>/dev/null || true; done
    fi
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env docker-compose.override.yml compose.override.yaml; do
      [[ -f "compose/${name}/${f}" ]] && cp -a "compose/${name}/${f}" "compose_restore/${name}/${f}" || true
    done
    NET="${name}_default"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      (cd "compose_restore/${name}" && docker compose down || true; docker network rm "$NET" >/dev/null 2>&1 || true; docker compose up -d)
    elif command -v docker-compose >/dev/null 2>&1; then
      (cd "compose_restore/${name}" && docker-compose down || true; docker network rm "$NET" >/dev/null 2>&1 || true; docker-compose up -d)
    else
      warn "  新机未安装 docker compose/docker-compose，跳过该项目"
    fi
  done < <(jq -c ".projects[]" manifest.json)
fi

say "[F] 恢复单容器（非 Compose）"
if jq -e ".runs|length>0" manifest.json >/dev/null; then
  for r in $(jq -r ".runs[]" manifest.json); do echo "  - $r"; bash "$r" || true; done
fi

say "[G] 完成，当前容器："
docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "提示：若端口被占用，请编辑 compose 或 runs 脚本后再次执行。"
REST_SH
  chmod +x "${BUNDLE}/restore.sh"
}
spinner_run "[INFO] 生成 manifest.json 与 restore.sh ..." generate_manifest_and_restore

# ---------- README ----------
cat > "${BUNDLE}/README.txt" <<EOF
新服务器操作：
- 推荐：使用 auto_restore.sh 输入“一键包下载”链接（.tar.gz），自动下载解压并执行 restore.sh
- 手动：下载整个目录后，bash restore.sh
EOF

# ---------- single-file bundle (RID.tar.gz) ----------
BUNDLE_BASENAME="$(basename "${BUNDLE}")"
spinner_run "[INFO] 生成单文件包 ${BUNDLE_BASENAME}.tar.gz ..." bash -c "(cd \"$(dirname "${BUNDLE}")\" && tar -czf \"${BUNDLE_BASENAME}.tar.gz\" \"${BUNDLE_BASENAME}\")"
SINGLE_TAR_PATH="$(dirname "${BUNDLE}")/${BUNDLE_BASENAME}.tar.gz"

# ---------- HTTP serve + post-restart + hard clean ----------
OK  "[OK] 生成完成：${BUNDLE}"
( cd "${BUNDLE}" && ls -lah )

PORT="${PORT:-8080}"; PORT="$(pick_free_port "$PORT")"
URL="$(pick_advertise_url "$PORT" "$RID")"

BLUE "[INFO] 启动 HTTP 服务（python3 -m http.server ${PORT}）"
SHPID=""
cleanup_http(){ [[ -n "${SHPID:-}" ]] && kill "${SHPID}" 2>/dev/null || true; }

# 无条件删除：关 HTTP → 重启容器 → 删除 bundle/<RID>/ 与 <RID>.tar.gz
hard_clean(){
  rm -rf "${BUNDLE}" 2>/dev/null || true
  rm -f  "$(dirname "${BUNDLE}")/$(basename "${BUNDLE}").tar.gz" 2>/dev/null || true
  OK "[OK] 已清理：工作目录与单文件包"
}

# 退出时序：关HTTP → 重启容器（逐个）→ 无条件清理
graceful_exit(){
  echo
  YEL "[INFO] 即将退出，先关闭 HTTP 服务 ..."
  cleanup_http

  if ((${#STOPPED_ON_BACKUP[@]})); then
    BLUE "[INFO] 重启本次停机的容器（共 ${#STOPPED_ON_BACKUP[@]} 个） ..."
    local ok=0 fail=0
    for n in "${STOPPED_ON_BACKUP[@]}"; do
      printf "  - starting: %s ... " "$n"
      if docker start "$n" >/dev/null 2>&1; then
        printf "ok\n"; ok=$((ok+1))
      else
        printf "fail\n"; fail=$((fail+1))
      fi
    done
    OK "[OK] 重启完成：成功 ${ok} / 失败 ${fail}"
  else
    YEL "[INFO] 本次未停任何容器，无需重启"
  fi

  YEL "[INFO] 清理打包产物 ..."
  hard_clean
  exit 0
}
trap graceful_exit INT TERM

( cd "$(dirname "${BUNDLE}")" && python3 -m http.server "${PORT}" >/dev/null 2>&1 & )
SHPID=$!; sleep 1

# 只输出一个下载链接（公网优先，探测不到则回退内网/127.0.0.1）
OK  "[OK] 下载链接： ${URL}"
YEL "[WARN] HTTP 未鉴权，仅限可信网络使用。完成后关闭此窗口。"

# 交互等待；回车 -> 关 HTTP → 重启 → 无条件清理
if [[ -t 0 ]]; then
  read -rp $'\n按回车键停止 HTTP 并退出（将自动重启停机容器并清理产物）... '
  graceful_exit
else
  graceful_exit
fi
