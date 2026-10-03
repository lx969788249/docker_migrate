#!/usr/bin/env bash
set -euo pipefail

# Exercise the exact generated restore helpers. No host paths or Docker volumes
# are mounted: each extraction uses a disposable container's private tmpfs.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOCKER_MIGRATE_LIB_ONLY=1
# shellcheck disable=SC1091
source "${ROOT}/docker_migrate_perfect.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
write_bundle_restore_script "${tmp}/restore.sh"
# shellcheck disable=SC1090
source <(sed -n '/^archive_members_safe() {/,/^}/p; /^archive_normalized_stream() {/,/^}/p' "${tmp}/restore.sh")
export -f archive_members_safe archive_normalized_stream

python3 - "$tmp" <<'PY'
import gzip
import io
import pathlib
import subprocess
import sys
import tarfile


def extension(kind, value):
    if kind in ("L", "K"):
        data = value.encode() + b"\0"
        member = tarfile.TarInfo("././@LongLink")
        member.type, member.size = kind.encode(), len(data)
        return member.tobuf(tarfile.USTAR_FORMAT) + padded(data)
    return tarfile.TarInfo._create_pax_generic_header(
        {kind: value}, tarfile.XHDTYPE, "utf-8"
    )


def padded(data):
    return data.ljust((len(data) + 511) // 512 * 512, b"\0")


def entry(name, data=b"", target=None, declared_size=None):
    member = tarfile.TarInfo(name)
    member.size = len(data) if declared_size is None else declared_size
    if target is not None:
        member.type, member.linkname = tarfile.SYMTYPE, target
    return member.tobuf(tarfile.USTAR_FORMAT) + padded(data)


cases = []

# BusyBox ignores global PAX path/linkpath; Python correctly applies them.
global_path = tarfile.TarInfo._create_pax_generic_header(
    {"path": "expected"}, tarfile.XGLTYPE, "utf-8"
)
cases.append(("global-path", global_path + entry("raw-name", b"data"), "file", "expected", "data"))
global_link = tarfile.TarInfo._create_pax_generic_header(
    {"linkpath": "/expected/socket"}, tarfile.XGLTYPE, "utf-8"
)
cases.append(("global-linkpath", global_link + entry("link", target="/wrong"), "link", "link", "/expected/socket"))

# Python's outer extension wins; BusyBox would otherwise use the last header.
for first, second in (("L", "path"), ("path", "L"), ("path", "path")):
    raw = extension(first, "expected") + extension(second, "wrong") + entry("raw-name", b"data")
    cases.append((f"name-{first}-{second}", raw, "file", "expected", "data"))
for first, second in (("K", "linkpath"), ("linkpath", "K"), ("linkpath", "linkpath")):
    raw = extension(first, "/expected/socket") + extension(second, "/wrong") + entry("link", target="/raw")
    cases.append((f"link-{first}-{second}", raw, "link", "link", "/expected/socket"))

# BusyBox ignores PAX size, while Python uses it to locate the file payload.
raw = extension("size", "4") + entry("expected", b"data", declared_size=0)
cases.append(("pax-size", raw, "file", "expected", "data"))
raw = extension("GNU.sparse.name", "expected") + entry("raw-name", b"data")
cases.append(("pax-name-alias", raw, "file", "expected", "data"))

# BusyBox interprets a zero-byte regular file with linkname as a hard link.
member = tarfile.TarInfo("expected")
member.linkname = "/etc/passwd"
cases.append(("zero-file-linkname", member.tobuf(tarfile.USTAR_FORMAT), "file", "expected", ""))

member = tarfile.TarInfo("expected")
member.type = tarfile.FIFOTYPE
cases.append(("fifo", member.tobuf(tarfile.USTAR_FORMAT), "fifo", "expected", ""))
long_name, long_target = "n" * 140, "/" + "t" * 140
raw = extension("L", long_name) + extension("K", long_target) + entry("raw-name", target="/raw")
cases.append(("gnu-long-name-and-target", raw, "link", long_name, long_target))

negative = tarfile.TarInfo("negative")
negative.size = -1
invalid = [
    ("negative-size", negative.tobuf(tarfile.GNU_FORMAT)),
    ("nul-link-target", extension("linkpath", "bad\0target") + entry("link", target="/raw")),
    ("empty-link-target", entry("link", target="")),
]
for label, raw in invalid:
    archive = pathlib.Path(sys.argv[1]) / (label + ".tgz")
    archive.write_bytes(gzip.compress(raw + b"\0" * 1024))
    rejected = subprocess.run(
        ["bash", "-c", 'archive_members_safe "$1"', "test", str(archive)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    assert rejected.returncode != 0, "unsafe metadata accepted: " + label
    assert "归档预检失败" in rejected.stderr.decode(), label
    print("PASS invalid archive metadata rejected:", label)

for label, raw, kind, name, expected in cases:
    archive = pathlib.Path(sys.argv[1]) / (label + ".tgz")
    archive.write_bytes(gzip.compress(raw + b"\0" * 1024))
    subprocess.run(["bash", "-c", 'archive_members_safe "$1"', "test", str(archive)], check=True)
    normalized = subprocess.run(
        ["bash", "-c", 'archive_normalized_stream "$1"', "test", str(archive)],
        check=True, stdout=subprocess.PIPE
    ).stdout
    with tarfile.open(fileobj=io.BytesIO(normalized), mode="r:") as checked:
        members = list(checked)
        assert len(members) == 1 and members[0].name == name, label
        if kind == "link":
            assert members[0].issym() and members[0].linkname == expected, label
        elif kind == "fifo":
            assert members[0].isfifo(), label
        else:
            assert members[0].isreg() and not members[0].linkname, label
            assert checked.extractfile(members[0]).read() == expected.encode(), label
    subprocess.run([
        "docker", "run", "--rm", "-i", "--read-only", "--network", "none",
        "--security-opt", "no-new-privileges", "--cap-drop", "MKNOD",
        "--tmpfs", "/tree", "alpine:3.20", "sh", "-eu", "-c",
        'tar -xf - -C /tree; '
        'test "$(find /tree -mindepth 1 -maxdepth 1 | wc -l)" -eq 1; '
        'if [ "$1" = link ]; then '
        'test -L "/tree/$2"; test "$(readlink "/tree/$2")" = "$3"; '
        'elif [ "$1" = fifo ]; then test -p "/tree/$2"; '
        'else test -f "/tree/$2"; test ! -L "/tree/$2"; '
        'test "$(cat "/tree/$2")" = "$3"; fi',
        "test", kind, name, expected
    ], input=normalized, check=True)
    print("PASS archive parser compatibility:", label)
print("All %d archive parser compatibility cases and %d rejection cases passed." % (len(cases), len(invalid)))
PY
