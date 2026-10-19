# 迁移前预检：在下载迁移包、改动新服务器之前，根据迁移计划找出会让迁移失败的问题。
#
# 问题分三级：
#   info  只提示，不停下（如 Docker 版本较旧）
#   ask   会导致迁移失败但可以处理，停下来让用户针对性地选择（如端口被占用）
#   stop  无法继续（如 CPU 架构不同）
# 用户的选择写进“恢复决定”文件（JSON），恢复脚本按它执行：换端口、跳过项目、
# 改为自动分配 IP 等。检查逻辑用 python3 实现（新服务器恢复时本来就需要它）。

# 输出检查结果 JSON：{"issues": [...], "summary": {...}}。
preflight_collect() {
  local plan="$1" decisions="$2" base_dir="$3"
  python3 - "$plan" "$decisions" "$base_dir" <<'PREFLIGHT_PY'
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys

plan_path, decisions_path, base_dir = sys.argv[1:4]
plan = json.load(open(plan_path))
try:
    decisions = json.load(open(decisions_path))
except (OSError, ValueError):
    decisions = {}
issues = []


def run(cmd):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def human(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            if unit == "B" or n >= 10:
                return "%d%s" % (n, unit)
            return ("%.1f" % n).rstrip("0").rstrip(".") + unit
        n /= 1024


def cjk_spaced(text):
    """中文排版：与英文或数字相邻时加一个空格，与中文或全角符号相邻时不加。"""
    if not text:
        return text
    left = " " if ord(text[0]) < 128 and text[0].isalnum() else ""
    right = " " if ord(text[-1]) < 128 and text[-1].isalnum() else ""
    return left + text + right


def add(level, kind, title, hint="", **data):
    item = {"level": level, "type": kind, "title": title, "hint": hint}
    item.update(data)
    issues.append(item)


def free_bytes(path):
    path = os.path.abspath(path or "/")
    while not os.path.exists(path) and path != "/":
        path = os.path.dirname(path)
    try:
        st = os.statvfs(path)
        return st.f_bavail * st.f_frsize, os.stat(path).st_dev
    except OSError:
        return None, None


skip_projects = set(decisions.get("skip_projects", []))
skip_containers = set(decisions.get("skip_containers", []))
replace_containers = set(decisions.get("replace_containers", []))
replace_projects = set(decisions.get("replace_projects", []))
keep_volumes = set(decisions.get("keep_volumes", []))
auto_subnet = set(decisions.get("auto_subnet", []))
reuse_network = set(decisions.get("reuse_network", []))
auto_ip = {(x.get("container"), x.get("network")) for x in decisions.get("auto_ip", [])}
port_map = {}
for item in decisions.get("port_map", []):
    key = (item.get("container"), item.get("host_ip", ""), str(item.get("host_port")),
           str(item.get("container_port")), item.get("proto", "tcp"))
    port_map[key] = str(item.get("new_port", ""))

containers = [c for c in plan.get("containers", [])
              if c.get("project", "") not in skip_projects and c["name"] not in skip_containers]
plan_names = {c["name"] for c in containers}
used_volumes = {v for c in containers for v in c.get("volumes", [])}
used_binds = {b for c in containers for b in c.get("binds", [])}

# ---------- Docker 环境 ----------
rc, out = run(["docker", "info", "--format", "{{json .}}"])
try:
    info = json.loads(out) if rc == 0 else {}
except ValueError:
    info = {}

arch_alias = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64",
              "armv7l": "arm", "armhf": "arm", "arm": "arm"}
src_arch = plan.get("source", {}).get("arch", "")
dst_arch = info.get("Architecture", "") or os.uname().machine
if src_arch and dst_arch and arch_alias.get(src_arch, src_arch) != arch_alias.get(dst_arch, dst_arch):
    add("stop", "arch",
        "两台服务器的 CPU 类型不同：旧服务器是 %s，新服务器是 %s" % (src_arch, dst_arch),
        "容器镜像只能在相同 CPU 类型的服务器上运行，请换一台和旧服务器相同类型的服务器")


def version_tuple(v):
    nums = re.findall(r"\d+", v or "")
    return tuple(int(x) for x in nums[:2]) if len(nums) >= 2 else None


src_ver = plan.get("source", {}).get("docker", "")
dst_ver = info.get("ServerVersion", "")
if version_tuple(src_ver) and version_tuple(dst_ver) and version_tuple(dst_ver) < version_tuple(src_ver):
    add("info", "docker_version",
        "新服务器的 Docker（%s）比旧服务器（%s）旧，一般不影响迁移" % (dst_ver, src_ver))

if any(c.get("project") for c in containers):
    has_plugin = run(["docker", "compose", "version"])[0] == 0
    if not has_plugin and not shutil.which("docker-compose"):
        add("stop", "compose",
            "要迁移 Compose 项目，但新服务器没有安装 Docker Compose",
            "先安装 Docker Compose（例如 apt install docker-compose-plugin）再重试")

runtimes = set((info.get("Runtimes") or {}).keys())
for c in containers:
    rt = c.get("runtime", "")
    if rt and rt != "runc" and runtimes and rt not in runtimes:
        add("stop", "runtime", "容器 %s 需要 %s 运行环境，新服务器没有安装" % (c["name"], rt),
            "先在新服务器安装它（例如 NVIDIA 显卡需要安装 NVIDIA Container Toolkit）再重试")
    for dev in c.get("devices", []):
        if dev and not os.path.exists(dev):
            add("stop", "device", "容器 %s 需要设备 %s，新服务器上没有" % (c["name"], dev),
                "确认新服务器有这个硬件并已安装驱动")

volume_plugins = set((info.get("Plugins") or {}).get("Volume") or [])
for v in plan.get("volumes", []):
    if v["name"] not in used_volumes:
        continue
    driver = v.get("driver", "local")
    if driver != "local" and volume_plugins and driver not in volume_plugins:
        add("stop", "volume_plugin", "数据卷 %s 使用 %s 插件存储，新服务器没有安装这个插件" % (v["name"], driver),
            "先在新服务器安装 %s 卷插件再重试" % driver)

mem_total = info.get("MemTotal") or 0
mem_need = sum(int(c.get("memory") or 0) for c in containers)
if mem_total and mem_need > mem_total:
    add("info", "memory", "容器设置的内存上限合计 %s，超过新服务器的内存 %s，内存紧张时容器可能被系统结束"
        % (human(mem_need), human(mem_total)))

# ---------- 磁盘空间 ----------
sizes = plan.get("sizes", {})
bundle = int(sizes.get("bundle") or 0)
kept_volume_bytes = sum(int(v.get("bytes") or 0) for v in plan.get("volumes", [])
                        if v["name"] in keep_volumes or v["name"] not in used_volumes)
docker_need = int(sizes.get("images") or 0) + int(sizes.get("volumes") or 0) - kept_volume_bytes
# 在已解压的迁移包里手动恢复时，下载和解压所需空间已经用掉了，不再计算。
skip_base = os.environ.get("PREFLIGHT_SKIP_BASE_DISK") == "1"
if skip_base:
    bundle = 0
base_need = 2 * bundle
base_free, base_dev = free_bytes(base_dir)
root_free, root_dev = free_bytes(info.get("DockerRootDir") or "/var/lib/docker")
if base_free is not None and root_free is not None and base_dev == root_dev:
    # 同一块磁盘：解压出的迁移包与加载后的镜像、数据卷会同时存在。
    total = max(base_need, bundle + docker_need)
    if base_free < total:
        add("ask", "disk_base",
            "磁盘空间不够：迁移需要约 %s，%s 所在磁盘只剩 %s" % (human(total), base_dir, human(base_free)),
            "清理磁盘后重新检查，或换一个空间更大的磁盘存放下载文件",
            need=total, free=base_free)
    elif base_free < total * 1.2:
        add("info", "disk_tight", "磁盘空间偏紧：迁移需要约 %s，剩余 %s" % (human(total), human(base_free)))
else:
    if base_free is not None and base_free < base_need:
        add("ask", "disk_base",
            "磁盘空间不够：下载和解压需要约 %s，%s 所在磁盘只剩 %s" % (human(base_need), base_dir, human(base_free)),
            "清理磁盘后重新检查，或换一个空间更大的磁盘存放下载文件",
            need=base_need, free=base_free)
    root = info.get("DockerRootDir") or "/var/lib/docker"
    if root_free is not None and root_free < docker_need:
        add("ask", "disk_docker",
            "磁盘空间不够：Docker 存放镜像和数据卷需要约 %s，%s 所在磁盘只剩 %s" % (human(docker_need), root, human(root_free)),
            "清理磁盘后重新检查（docker system prune 可以清理不用的镜像和容器）",
            need=docker_need, free=root_free)

for b in plan.get("binds", []):
    if b["host"] not in used_binds and (not b.get("link") or b["link"] not in used_binds):
        continue
    need = int(b.get("bytes") or 0)
    free, _ = free_bytes(b["host"])
    if free is not None and need and free < need:
        add("ask", "disk_bind",
            "磁盘空间不够：目录 %s 需要约 %s，所在磁盘只剩 %s" % (b["host"], human(need), human(free)),
            "清理这块磁盘后重新检查", need=need, free=free)

# ---------- 已有的同名容器、Compose 项目、数据卷 ----------
rc, out = run(["docker", "ps", "-a", "--format",
               '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Ports}}'])
existing = {}
for line in out.splitlines():
    parts = line.split("\t")
    if len(parts) >= 3:
        existing[parts[0]] = {"project": parts[1], "ports": parts[2]}
existing_projects = {e["project"] for e in existing.values() if e["project"]}
policy = os.environ.get("RESTORE_EXISTING", "")

for c in containers:
    if c.get("project") or c["name"] not in existing or c["name"] in replace_containers:
        continue
    if policy == "fail":
        add("stop", "existing_container", "新服务器上已经有同名容器 %s（RESTORE_EXISTING=fail 不允许替换）" % c["name"],
            "删除这个容器，或改用 RESTORE_EXISTING=replace")
    elif policy not in ("replace", "skip"):
        add("ask", "existing_container", "新服务器上已经有同名容器 %s" % c["name"], container=c["name"])
for project in sorted({c["project"] for c in containers if c.get("project")}):
    if project not in existing_projects or project in replace_projects:
        continue
    if policy == "fail":
        add("stop", "existing_project", "新服务器上已经有同名的 Compose 项目 %s（RESTORE_EXISTING=fail 不允许替换）" % project,
            "删除这个项目的容器，或改用 RESTORE_EXISTING=replace")
    elif policy not in ("replace", "skip"):
        add("ask", "existing_project", "新服务器上已经有同名的 Compose 项目 %s" % project, project=project)

for v in plan.get("volumes", []):
    if v["name"] not in used_volumes or v["name"] in keep_volumes:
        continue
    rc, out = run(["docker", "volume", "inspect", v["name"]])
    if rc != 0:
        continue
    try:
        cur = json.loads(out)[0]
    except (ValueError, IndexError):
        continue
    if (cur.get("Driver") or "local") != v.get("driver", "local") or (cur.get("Options") or {}) != (v.get("opts") or {}):
        add("ask", "volume_mismatch",
            "新服务器已有同名数据卷 %s，但它的存储方式和旧服务器不同" % v["name"], volume=v["name"])
    else:
        add("info", "volume_replace", "数据卷 %s 已存在，迁移的数据会替换它（失败时自动还原）" % v["name"])

# ---------- 网络 ----------
target_nets = {}
rc, out = run(["docker", "network", "ls", "-q"])
ids = out.split()
if ids:
    rc, out = run(["docker", "network", "inspect"] + ids)
    try:
        for n in json.loads(out) if rc == 0 else []:
            target_nets[n["Name"]] = {
                "driver": n.get("Driver", ""),
                "subnets": [c.get("Subnet") for c in (n.get("IPAM") or {}).get("Config") or [] if c.get("Subnet")],
                "ips": {(v.get("IPv4Address") or "").split("/")[0]: v.get("Name", "")
                        for v in (n.get("Containers") or {}).values()},
            }
    except ValueError:
        pass

plan_nets = {n["name"]: n for n in plan.get("networks", [])}
used_nets = {net["name"] for c in containers for net in c.get("networks", [])}
for name, net in plan_nets.items():
    if name not in used_nets or name in ("bridge", "host", "none") or net.get("compose"):
        continue
    if net.get("driver") in ("macvlan", "ipvlan"):
        add("info", "macvlan", "网络 %s 使用 %s，需要新服务器的网卡名称和旧服务器一致" % (name, net["driver"]))
    if name in reuse_network or name in auto_subnet:
        continue
    wanted = [s for s in net.get("subnets", []) if s]
    if name in target_nets:
        have = target_nets[name]
        if sorted(have["subnets"]) != sorted(wanted) or have["driver"] != net.get("driver", "bridge"):
            add("ask", "network_mismatch",
                "新服务器已有同名网络 %s，但网段不同（旧服务器 %s，新服务器 %s）"
                % (name, "、".join(wanted) or "自动", "、".join(have["subnets"]) or "自动"), network=name)
        continue
    for subnet in wanted:
        try:
            mine = ipaddress.ip_network(subnet, strict=False)
        except ValueError:
            continue
        clash = None
        for other, have in target_nets.items():
            for s in have["subnets"]:
                try:
                    if mine.overlaps(ipaddress.ip_network(s, strict=False)):
                        clash = (other, s)
                except (ValueError, TypeError):
                    pass
        if clash:
            add("ask", "subnet_conflict",
                "网络 %s 要用的网段 %s 和新服务器上的网络 %s（%s）重叠" % (name, subnet, clash[0], clash[1]),
                network=name)
            break

for c in containers:
    for net in c.get("networks", []):
        ip = net.get("ip", "")
        name = net["name"]
        if not ip or name in reuse_network or name in auto_subnet or (c["name"], name) in auto_ip:
            continue
        holder = target_nets.get(name, {}).get("ips", {}).get(ip)
        if holder and holder != c["name"] and holder not in plan_names:
            add("ask", "ip_conflict", "网络 %s 中的 IP %s 已被容器 %s 使用，容器 %s 需要它" % (name, ip, holder, c["name"]),
                container=c["name"], network=name)

# ---------- 端口 ----------
WILD = {"", "0.0.0.0", "::", "*", "[::]"}


def parse_listeners():
    found = []
    tool = None
    for proto, flag in (("tcp", "-Hltnp"), ("udp", "-Hlunp")):
        rc, out = run(["ss", flag])
        if rc != 0:
            rc, out = run(["ss", flag.replace("p", "")])
        if rc != 0:
            continue
        tool = "ss"
        for line in out.splitlines():
            cols = line.split()
            if len(cols) < 5:
                continue
            local = cols[3]
            host, _, port = local.rpartition(":")
            host = host.strip("[]").split("%")[0]
            proc = ""
            m = re.search(r'users:\(\("([^"]+)",pid=(\d+)', line)
            if m:
                proc = "%s（进程 %s）" % (m.group(1), m.group(2))
            if port.isdigit():
                found.append((proto, host, port, proc))
    return tool, found


tool, listeners = parse_listeners()
docker_ports = {}
for cname, e in existing.items():
    for m in re.finditer(r"([0-9a-fA-F:.\[\]]*):(\d+)->\d+/(tcp|udp)", e["ports"]):
        docker_ports.setdefault((m.group(3), m.group(2)), cname)


def port_holder(proto, host_ip, port):
    owner = docker_ports.get((proto, port))
    if owner:
        return "容器 %s" % owner, owner
    for p, host, lport, proc in listeners:
        if p == proto and lport == port and (host_ip in WILD or host in WILD or host == host_ip):
            if "docker-proxy" in proc:
                continue
            return proc or "其他程序", None
    return None, None


requested = set()
for c in containers:
    if c.get("network_mode", "") == "host" or c.get("network_mode", "").startswith("container:"):
        continue
    for p in c.get("ports", []):
        key = (c["name"], p.get("host_ip", ""), str(p["host_port"]), str(p["container_port"]), p.get("proto", "tcp"))
        port = port_map.get(key, str(p["host_port"]))
        if not port:
            continue
        requested.add((p.get("proto", "tcp"), port))
        holder, owner = port_holder(p.get("proto", "tcp"), p.get("host_ip", ""), port)
        if not holder:
            continue
        # 占用端口的正是将被替换的同名容器：恢复时它会先停止，不算冲突。
        if owner and owner in plan_names:
            continue
        busy = {(pr, po) for pr, _, po, _ in listeners} | set(docker_ports.keys()) | requested
        suggest = next((str(x) for x in range(int(port) + 1, min(int(port) + 200, 65536))
                        if (p.get("proto", "tcp"), str(x)) not in busy), "")
        add("ask", "port",
            "端口 %s 已被%s占用，%s需要使用它" % (port, cjk_spaced(holder),
                ("Compose 项目 %s 的容器 %s " % (c["project"], c["name"])) if c.get("project") else ("容器 %s " % c["name"])),
            container=c["name"], project=c.get("project", ""), host_ip=p.get("host_ip", ""),
            host_port=str(p["host_port"]), current_port=port, container_port=str(p["container_port"]),
            proto=p.get("proto", "tcp"), holder=holder, suggest=suggest)
if tool is None and any(c.get("ports") for c in containers):
    add("info", "port_unchecked", "新服务器没有 ss 命令，无法提前检查端口是否被占用")

need = max(base_need, bundle + docker_need)
json.dump({"issues": issues, "summary": {"containers": len(containers), "need_bytes": need}},
          sys.stdout, ensure_ascii=False)
PREFLIGHT_PY
}

# ---------- 恢复决定文件 ----------

preflight_decide() {
  local file="$1" filter="$2"
  shift 2
  local tmp="${file}.tmp.$$"
  [[ -s "$file" ]] || printf '{}\n' >"$file"
  jq "$@" "$filter" "$file" >"$tmp" && mv "$tmp" "$file"
}

# 读取一个选项编号；回车选默认值。非交互时直接使用默认值。
preflight_choose() {
  local max="$1" default="$2" answer
  while :; do
    printf '请选择 [%s]：' "$default" >&2
    read -r answer </dev/tty || answer=""
    answer="${answer:-$default}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= max)); then
      printf '%s\n' "$answer"
      return 0
    fi
    printf '请输入 1 到 %s 之间的数字。\n' "$max" >&2
  done
}

preflight_option() {
  printf '  %s) %s\n' "$1" "$2" >&2
}

# 处理一个“需要用户选择”的问题。返回 0 表示已处理（或选择了重新检查），
# 返回 1 表示用户选择取消。auto=1 时自动采用推荐做法，无法自动处理时返回 1。
preflight_resolve() {
  local issue="$1" decisions="$2" index="$3" total="$4" auto="$5"
  local kind title choice container project port new_port network volume
  kind="$(jq -r '.type' <<<"$issue")"
  title="$(jq -r '.title' <<<"$issue")"
  container="$(jq -r '.container // ""' <<<"$issue")"
  project="$(jq -r '.project // ""' <<<"$issue")"
  network="$(jq -r '.network // ""' <<<"$issue")"
  volume="$(jq -r '.volume // ""' <<<"$issue")"

  if [[ "$auto" != "1" ]]; then
    printf '\n问题 %s/%s：' "$index" "$total" >&2
  fi
  case "$kind" in
    port)
      port="$(jq -r '.current_port' <<<"$issue")"
      new_port="$(jq -r '.suggest // ""' <<<"$issue")"
      if [[ -n "$project" ]]; then
        if [[ "$auto" == "1" ]]; then
          log_line "无法自动处理：${title}"
          return 1
        fi
        printf '%s\n' "$(screen_color '1;33' "⚠️  端口被占用，Compose 项目 ${project} 无法启动")" >&2
        printf '  %s\n' "$title" >&2
        printf '  请自行停止占用端口的程序，或修改 %s 的 compose 文件中的端口后再继续。\n' "$project" >&2
        preflight_option 1 "我已处理好，重新检查（推荐）"
        preflight_option 2 "暂时跳过 ${project} 项目，继续迁移其他容器"
        preflight_option 3 "取消恢复"
        choice="$(preflight_choose 3 1)"
        case "$choice" in
          2) preflight_decide "$decisions" '.skip_projects = ((.skip_projects // []) + [$p] | unique) |
               .skipped_reasons = ((.skipped_reasons // []) + [{project: $p, reason: $r}])' \
            --arg p "$project" --arg r "端口 ${port} 被占用" ;;
          3) return 1 ;;
        esac
        return 0
      fi
      if [[ "$auto" == "1" ]]; then
        [[ -n "$new_port" ]] || return 1
        choice=1
      else
        printf '%s\n' "$title" >&2
        if [[ -n "$new_port" ]]; then
          preflight_option 1 "改用空闲端口 ${new_port}（推荐）"
        else
          preflight_option 1 "改用其他端口（附近没有找到空闲端口，需要手动输入）"
        fi
        preflight_option 2 "输入其他端口"
        preflight_option 3 "我先停掉占用端口的程序，然后重新检查"
        preflight_option 4 "不对外开放这个端口"
        preflight_option 5 "取消恢复"
        choice="$(preflight_choose 5 1)"
      fi
      if [[ "$choice" == 1 && -z "$new_port" ]] || [[ "$choice" == 2 ]]; then
        while :; do
          printf '新端口：' >&2
          read -r new_port </dev/tty || new_port=""
          [[ "$new_port" =~ ^[0-9]+$ ]] && ((new_port >= 1 && new_port <= 65535)) && break
          printf '请输入 1 到 65535 之间的端口号。\n' >&2
        done
        choice=1
      fi
      case "$choice" in
        1 | 4)
          [[ "$choice" == 1 ]] || new_port=""
          preflight_decide "$decisions" '
            .port_map = ([(.port_map // [])[] | select((.container == $c and .host_ip == $ip and
              .host_port == $hp and .container_port == $cp and .proto == $proto) | not)] +
              [{container: $c, host_ip: $ip, host_port: $hp, container_port: $cp, proto: $proto, new_port: $np}])' \
            --arg c "$container" --arg ip "$(jq -r '.host_ip' <<<"$issue")" \
            --arg hp "$(jq -r '.host_port' <<<"$issue")" --arg cp "$(jq -r '.container_port' <<<"$issue")" \
            --arg proto "$(jq -r '.proto' <<<"$issue")" --arg np "$new_port"
          ;;
        5) return 1 ;;
      esac
      ;;
    existing_container | existing_project)
      if [[ "$auto" == "1" ]]; then
        choice=1
      else
        printf '%s\n' "$title" >&2
        preflight_option 1 "替换它（推荐，迁移失败时会自动还原）"
        if [[ "$kind" == existing_project ]]; then
          preflight_option 2 "保留已有的，跳过这个项目"
        else
          preflight_option 2 "保留已有的，跳过这个容器"
        fi
        preflight_option 3 "取消恢复"
        choice="$(preflight_choose 3 1)"
      fi
      case "$kind:$choice" in
        existing_container:1) preflight_decide "$decisions" '.replace_containers = ((.replace_containers // []) + [$c] | unique)' --arg c "$container" ;;
        existing_container:2) preflight_decide "$decisions" '.skip_containers = ((.skip_containers // []) + [$c] | unique) |
          .skipped_reasons = ((.skipped_reasons // []) + [{container: $c, reason: "保留新服务器上已有的容器"}])' --arg c "$container" ;;
        existing_project:1) preflight_decide "$decisions" '.replace_projects = ((.replace_projects // []) + [$p] | unique)' --arg p "$project" ;;
        existing_project:2) preflight_decide "$decisions" '.skip_projects = ((.skip_projects // []) + [$p] | unique) |
          .skipped_reasons = ((.skipped_reasons // []) + [{project: $p, reason: "保留新服务器上已有的项目"}])' --arg p "$project" ;;
        *:3) return 1 ;;
      esac
      ;;
    ip_conflict | subnet_conflict | network_mismatch)
      if [[ "$auto" == "1" ]]; then
        choice=1
      else
        printf '%s\n' "$title" >&2
        case "$kind" in
          ip_conflict) preflight_option 1 "改为由 Docker 自动分配 IP（推荐）" ;;
          subnet_conflict) preflight_option 1 "让 Docker 自动选择一个不冲突的网段，网络里的容器改为自动分配 IP（推荐）" ;;
          network_mismatch) preflight_option 1 "继续使用新服务器上已有的这个网络，容器改为自动分配 IP（推荐）" ;;
        esac
        preflight_option 2 "取消恢复"
        choice="$(preflight_choose 2 1)"
      fi
      [[ "$choice" == 1 ]] || return 1
      case "$kind" in
        ip_conflict) preflight_decide "$decisions" '.auto_ip = ((.auto_ip // []) + [{container: $c, network: $n}] | unique)' \
          --arg c "$container" --arg n "$network" ;;
        subnet_conflict) preflight_decide "$decisions" '.auto_subnet = ((.auto_subnet // []) + [$n] | unique)' --arg n "$network" ;;
        network_mismatch) preflight_decide "$decisions" '.reuse_network = ((.reuse_network // []) + [$n] | unique)' --arg n "$network" ;;
      esac
      ;;
    volume_mismatch)
      [[ "$auto" != "1" ]] || return 1
      printf '%s\n' "$title" >&2
      preflight_option 1 "取消恢复，我先处理这个数据卷（推荐）"
      preflight_option 2 "保留已有的数据卷，不写入迁移过来的数据"
      choice="$(preflight_choose 2 1)"
      [[ "$choice" == 2 ]] || return 1
      preflight_decide "$decisions" '.keep_volumes = ((.keep_volumes // []) + [$v] | unique)' --arg v "$volume"
      ;;
    disk_base)
      [[ "$auto" != "1" ]] || return 1
      printf '%s\n' "$title" >&2
      preflight_option 1 "我先清理磁盘，然后重新检查（推荐）"
      preflight_option 2 "换一个目录存放下载文件"
      preflight_option 3 "取消恢复"
      choice="$(preflight_choose 3 1)"
      case "$choice" in
        2)
          local dir
          printf '目录（例如 /data/restore）：' >&2
          read -r dir </dev/tty || dir=""
          [[ "$dir" == /* ]] && preflight_decide "$decisions" '.restore_base = $d' --arg d "$dir"
          ;;
        3) return 1 ;;
      esac
      ;;
    disk_docker | disk_bind | *)
      [[ "$auto" != "1" ]] || return 1
      printf '%s\n' "$title" >&2
      preflight_option 1 "我先清理磁盘，然后重新检查（推荐）"
      preflight_option 2 "取消恢复"
      choice="$(preflight_choose 2 1)"
      [[ "$choice" == 1 ]] || return 1
      ;;
  esac
  return 0
}

# 运行预检，交互地处理问题，直到没有需要处理的问题。
# 返回 0 可以继续；返回 1 不能继续（失败原因已记录）。
# PREFLIGHT_NEED_BYTES、PREFLIGHT_CONTAINERS 会被设置，供阶段结果显示。
preflight_run() {
  local plan="$1" decisions="$2" base_dir="$3"
  local result asks stops i total row interactive=0 auto="${RESTORE_AUTO_RESOLVE:-0}" round=0
  local -A shown_infos=()
  [[ -s "$decisions" ]] || printf '{}\n' >"$decisions"
  if [[ -t 0 || -r /dev/tty ]] && [[ -t 2 ]]; then
    interactive=1
  fi
  while :; do
    round=$((round + 1))
    base_dir="$(jq -r --arg d "$base_dir" '.restore_base // $d' "$decisions")"
    if ! result="$(preflight_collect "$plan" "$decisions" "$base_dir" 2>>"${DM_LOG_FILE:-/dev/null}")"; then
      log_line "预检脚本运行失败，跳过预检"
      warn_user "预检没能完成，直接开始迁移（问题会在迁移过程中发现并自动回滚）"
      return 0
    fi
    log_line "预检结果（第 ${round} 轮）：${result}"
    # 供调用方在阶段结果中显示。
    export PREFLIGHT_NEED_BYTES PREFLIGHT_CONTAINERS
    PREFLIGHT_NEED_BYTES="$(jq -r '.summary.need_bytes // 0' <<<"$result")"
    PREFLIGHT_CONTAINERS="$(jq -r '.summary.containers // 0' <<<"$result")"
    while IFS= read -r row; do
      [[ -n "$row" && -z "${shown_infos[$row]:-}" ]] || continue
      shown_infos["$row"]=1
      warn_user "$row"
    done < <(jq -r '.issues[] | select(.level == "info") | .title' <<<"$result")

    stops="$(jq -c '[.issues[] | select(.level == "stop")]' <<<"$result")"
    if [[ "$(jq 'length' <<<"$stops")" -gt 0 ]]; then
      stage_hold
      printf '%s\n' "$(screen_color '1;31' '发现无法继续的问题，尚未下载或修改任何内容：')" >&2
      while IFS=$'\t' read -r row hint; do
        printf '  ✗ %s\n' "$row" >&2
        [[ -z "$hint" ]] || printf '    建议：%s\n' "$hint" >&2
      done < <(jq -r '.[] | [.title, .hint] | @tsv' <<<"$stops")
      fail_reason "$(jq -r '.[0].title' <<<"$stops")" "$(jq -r '.[0].hint' <<<"$stops")"
      return 1
    fi

    asks="$(jq -c '[.issues[] | select(.level == "ask")]' <<<"$result")"
    total="$(jq 'length' <<<"$asks")"
    ((total > 0)) || return 0

    if ((interactive == 0)) && [[ "$auto" != "1" ]]; then
      stage_hold
      printf '%s\n' "$(screen_color '1;33' "发现 ${total} 个需要处理的问题，尚未下载或修改任何内容：")" >&2
      while IFS=$'\t' read -r row hint; do
        printf '  ! %s\n' "$row" >&2
        [[ -z "$hint" ]] || printf '    建议：%s\n' "$hint" >&2
      done < <(jq -r '.[] | [.title, .hint] | @tsv' <<<"$asks")
      printf '处理后重新运行即可；也可以设置 RESTORE_AUTO_RESOLVE=1，自动采用推荐的处理方式（例如自动换一个空闲端口）。\n' >&2
      fail_reason "$(jq -r '.[0].title' <<<"$asks")" \
        "处理后重新运行；或设置 RESTORE_AUTO_RESOLVE=1 自动采用推荐做法（如自动换端口）"
      return 1
    fi

    if ((interactive == 1)) && [[ "$auto" != "1" ]]; then
      stage_hold
      printf '%s\n' "$(screen_color '1;33' "发现 ${total} 个需要处理的问题（尚未下载或修改任何内容）")" >&2
    fi
    for ((i = 0; i < total; i++)); do
      if ! preflight_resolve "$(jq -c ".[$i]" <<<"$asks")" "$decisions" "$((i + 1))" "$total" \
        "$([[ "$auto" == "1" ]] && echo 1 || echo 0)"; then
        fail_reason "$(jq -r ".[$i].title" <<<"$asks")" \
          "$([[ "$auto" == "1" ]] && echo "这个问题无法自动处理，请手动处理后重新运行" || echo "处理后重新粘贴同一个链接即可继续")"
        return 1
      fi
    done
    # 自动处理只做一轮：再次检查仍有问题时交给用户。
    if [[ "$auto" == "1" ]] && ((round >= 2)); then
      auto=0
      ((interactive == 1)) || {
        fail_reason "自动处理后仍有问题没有解决" "查看日志了解详情"
        return 1
      }
    fi
    printf '\n重新检查……\n' >&2
  done
}

# 恢复结果中列出预检时做的调整，让用户知道哪些地方和旧服务器不同。
print_decision_summary() {
  local decisions="${1:-}"
  [[ -n "$decisions" && -s "$decisions" ]] || return 0
  jq -r '
    ([.port_map[]? | if .new_port == "" then
        "不再对外开放：\(.container) 的端口 \(.host_port)"
      else "端口变更：\(.container) \(.host_port) → \(.new_port)" end]) +
    ([.skipped_reasons[]? | if .project then "⚠️ 未迁移：Compose 项目 \(.project)（\(.reason)）"
      else "⚠️ 未迁移：容器 \(.container)（\(.reason)）" end]) +
    ([.auto_ip[]? | "自动分配 IP：\(.container) 在网络 \(.network) 中"]) +
    ([.auto_subnet[]? | "自动选择网段：网络 \(.)"]) +
    ([.reuse_network[]? | "沿用新服务器已有网络：\(.)"]) +
    ([.keep_volumes[]? | "保留已有数据卷、未写入迁移数据：\(.)"]) | .[]' "$decisions" 2>/dev/null
  if jq -e '(.skipped_reasons // []) | any(.project)' "$decisions" >/dev/null 2>&1; then
    printf '   处理好之后，在新服务器重新粘贴同一个链接即可补上（旧服务器的传输服务需要仍在运行）。\n'
  fi
}
