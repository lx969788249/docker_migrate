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

restore_sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    return 127
  fi
}

restore_verify_checksums() {
  local expected rel file actual count=0
  local -A verified_paths=()
  [[ -f checksums.sha256 ]] || return 2
  while IFS=$'\t' read -r expected rel; do
    [[ -n "$expected" && -n "$rel" ]] || continue
    case "$rel" in /*|..|../*|*/../*|*/..) return 1 ;; esac
    file="${BUNDLE_DIR}/${rel}"
    [[ -f "$file" ]] || return 1
    actual="$(restore_sha256_file "$file")" || return 1
    [[ "$actual" == "$expected" ]] || return 1
    verified_paths["$rel"]=1
    count=$((count + 1))
  done <checksums.sha256
  (( count > 0 )) || return 1
  while IFS= read -r -d '' file; do
    rel="${file#"${BUNDLE_DIR}/"}"
    case "$rel" in checksums.sha256 | restore.sh | .docker_migrate_rollback/*) continue ;; esac
    [[ -n "${verified_paths["$rel"]+present}" ]] || return 1
  done < <(find "$BUNDLE_DIR" -type f -print0)
}

restore_manifest_is_safe() {
  local run name metadata_name
  jq -e '
    type == "object" and
    (.images | type == "array") and
    (.networks | type == "array") and
    (.projects | type == "array") and
    (.volumes | type == "array") and
    (.binds | type == "array") and
    (.runs | type == "array") and
    all(.runs[]; type == "string" and test("^runs/[A-Za-z0-9][A-Za-z0-9_.-]*\\.sh$")) and
    all(.projects[];
      (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) and
      (.working_dir // "" | type == "string" and
        (. == "" or (startswith("/") and (test("(^|/)\\.\\.(/|$)") | not) and
          all(explode[]; . >= 32 and . != 127))))
    ) and
    all(.volumes[]; (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$"))) and
    all(.binds[];
      (.host | type == "string" and startswith("/") and . != "/" and
        (test("(^|/)\\.\\.(/|$)") | not) and
        all(explode[]; . >= 32 and . != 127)) and
      (.file | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*\\.tgz$")) and
      ((.link // null) == null or (.link | type == "string" and startswith("/") and . != "/" and
        (test("(^|/)\\.\\.(/|$)") | not) and
        all(explode[]; . >= 32 and . != 127)))
    )
  ' manifest.json >/dev/null || return 1
  while IFS= read -r run; do
    [[ -f "${BUNDLE_DIR}/${run}" ]] || return 1
    name="${run#runs/}"
    name="${name%.sh}"
    [[ -f "${BUNDLE_DIR}/meta/${name}.inspect.json" ]] || return 1
    metadata_name="$(jq -r '.[0].Name | ltrimstr("/")' \
      "${BUNDLE_DIR}/meta/${name}.inspect.json" 2>/dev/null || true)"
    [[ "$metadata_name" == "$name" ]] || return 1
  done < <(jq -r '.runs[]' manifest.json)
}

archive_members_safe() {
  # 只解析元数据，不访问软链接目标。完整建表后检查，避免归档通过成员顺序
  # 或路径重名，让解压程序沿链接写出目标树。gzip 只解压扫描一次。
  python3 - "$1" "${2:-}" <<'ARCHIVE_PY'
import gzip
import sys
import tarfile
import zlib


def archive_path(raw):
    parts = raw.split("/")
    if raw.startswith("/") or ".." in parts or "\0" in raw:
        raise ValueError("拒绝归档中的绝对或越界成员路径：" + repr(raw))
    return "/".join(part for part in parts if part not in ("", "."))


try:
    prefix = archive_path(sys.argv[2])
    members = {}

    def scoped_path(raw):
        name = archive_path(raw)
        if prefix and name != prefix and not name.startswith(prefix + "/"):
            raise ValueError("归档成员超出绑定路径：" + repr(raw))
        return name

    with gzip.open(sys.argv[1], "rb") as compressed:
        with tarfile.open(fileobj=compressed, mode="r:") as archive:
            for member in archive:
                name = scoped_path(member.name)
                if member.size < 0:
                    raise ValueError("归档成员长度不能为负数：" + repr(name))
                if member.isdir():
                    kind, target = "dir", ""
                elif member.issym():
                    # 绝对、外部、悬空乃至循环软链接均可原样保存；不解引用。
                    if not member.linkname or "\0" in member.linkname:
                        raise ValueError("软链接目标为空或包含空字节：" + repr(name))
                    kind, target = "symlink", member.linkname
                elif member.islnk():
                    kind, target = "hardlink", scoped_path(member.linkname)
                elif member.isreg() and member.sparse is None:
                    kind, target = "file", ""
                elif member.isfifo():
                    kind, target = "fifo", ""
                else:
                    raise ValueError("不支持的归档成员类型（设备或稀疏格式）：" + repr(name))
                if not name and kind != "dir":
                    raise ValueError("归档根必须是目录")
                if name in members and not (kind == members[name][0] == "dir"):
                    raise ValueError("拒绝重复或改变类型的归档成员：" + repr(name))
                members[name] = (kind, target)
                # 仅保留安全检查所需的信息，不重复缓存完整 TarInfo 对象。
                archive.members.clear()
            # tar 遇到结束块即停止，但 gzip 校验码在流末尾；必须读完尾部。
            # 同时拒绝结束块后藏有另一个归档或非零记录，消除解析器歧义。
            compressed.seek(archive.offset)
            while True:
                padding = compressed.read(1024 * 1024)
                if not padding:
                    break
                if padding.strip(b"\0"):
                    raise ValueError("归档结束标记后存在额外数据")

    for name in members:
        parent = name.rpartition("/")[0]
        while parent:
            if parent in members and members[parent][0] != "dir":
                raise ValueError("拒绝通过链接或非目录写入：%r（父路径：%r）" % (name, parent))
            parent = parent.rpartition("/")[0]

    # 硬链接会访问目标 inode，与只保存目标字符串的软链接不同。
    # 允许内部硬链接链，但最终必须指向同一归档内的普通文件。
    resolved = {name for name, (kind, _) in members.items() if kind == "file"}
    for name, (kind, _) in members.items():
        if kind != "hardlink":
            continue
        current, chain = name, set()
        while current not in resolved:
            if current in chain:
                raise ValueError("拒绝循环硬链接：" + repr(name))
            chain.add(current)
            node = members.get(current)
            if node is None or node[0] != "hardlink":
                raise ValueError("硬链接必须指向归档内的普通文件：%r -> %r" % (name, current))
            current = node[1]
        resolved.update(chain)

    if prefix and (prefix not in members or members[prefix][0] not in ("dir", "file")):
        raise ValueError("绑定路径根必须是普通文件或目录：" + repr(prefix))
except (OSError, EOFError, ValueError, tarfile.TarError, zlib.error) as error:
    print("归档预检失败：%s：%s" % (sys.argv[1], error), file=sys.stderr)
    sys.exit(1)
ARCHIVE_PY
}

archive_normalized_stream() {
  # 只用于已完成结构预检的归档。Python 与 BusyBox 对 PAX/GNU 扩展头的
  # 优先级、size 等字段存在差异；不把原始头交给第二个解析器。用同一个
  # tarfile 解析器生成明确的 GNU tar 流，再交给隔离容器保存权限和属主。
  python3 - "$1" <<'STREAM_PY'
import copy
import posixpath
import sys
import tarfile

try:
    with tarfile.open(sys.argv[1], "r:gz") as source:
        with tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.GNU_FORMAT,
                          copybufsize=1024 * 1024) as output:
            for original in source:
                member = copy.copy(original)
                member.name = posixpath.normpath(member.name)
                member.pax_headers = {}
                if member.islnk():
                    member.linkname = posixpath.normpath(member.linkname)
                elif not member.issym():
                    # BusyBox 会把带 linkname 的零字节普通文件误当硬链接。
                    member.linkname = ""
                if member.isreg():
                    member.type = tarfile.REGTYPE
                    with source.extractfile(original) as payload:
                        output.addfile(member, payload)
                else:
                    member.size = 0
                    output.addfile(member)
                source.members.clear()
except (OSError, EOFError, ValueError, tarfile.TarError) as error:
    print("归档读取失败：%s" % error, file=sys.stderr)
    sys.exit(1)
STREAM_PY
}

