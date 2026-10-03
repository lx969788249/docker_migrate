#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_MIGRATE_LIB_ONLY=1
# shellcheck source=../docker_migrate_perfect.sh
source "${ROOT_DIR}/docker_migrate_perfect.sh"

PASS_COUNT=0
FAIL_COUNT=0

run_test() {
  local name="$1" rc
  shift
  set +e
  (
    set -e
    "$@"
  )
  rc=$?
  set -e
  if ((rc == 0)); then
    printf 'ok - %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

test_progress_propagates_failure() {
  local tmp rc output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  set +e
  output="$(progress_docker_save "${tmp}/images.tar" bash -c 'printf partial; exit 7' 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 7 ]]
  [[ "$(grep -Fc '[失败] 保存镜像 images.tar' <<<"$output")" -eq 1 ]]
  ! grep -Fq '完成' <<<"$output"
}

test_activity_progress_plain_failure_contract() {
  local output rc label='测试失败传播'
  set +e
  output="$(DOCKER_MIGRATE_PROGRESS_MODE=plain \
    run_with_activity "$label" bash -c 'exit 7' 2>&1)"
  rc=$?
  set -e

  [[ "$rc" -eq 7 ]]
  [[ "$(grep -Fc "[失败] ${label}" <<<"$output")" -eq 1 ]]
  ! grep -Fq '开始' <<<"$output"
  ! grep -Fq '完成' <<<"$output"
}

test_progress_render_reports_only_real_percentages() {
  local known unknown clamped
  known="$(progress_render '已知总量' 50 100 0)"
  grep -Fq '50%' <<<"$known"

  unknown="$(progress_render '未知总量' 2048 0 0)"
  grep -Fq '· 2KB ·' <<<"$unknown"
  [[ "$unknown" != *%* ]]

  clamped="$(progress_render '超出总量' 150 100 0)"
  grep -Fq '100%' <<<"$clamped"
  grep -Fq '100B/100B' <<<"$clamped"
}

test_tty_progress_redraw_has_no_blank_frame() {
  local output expected
  output="$({
    progress_tty_draw '较长的进度内容 · 1 秒'
    progress_tty_draw '短内容 · 2 秒'
    progress_tty_clear
  } 2>&1)"
  expected=$'\r较长的进度内容 · 1 秒\033[K\r短内容 · 2 秒\033[K\r\033[K'
  [[ "$output" == "$expected" ]]
  [[ "$output" != *"$(printf '%120s' '')"* ]]
}

test_quick_file_progress_is_silent() {
  local tmp output label='测试文件写入'
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  output="$(DOCKER_MIGRATE_PROGRESS_MODE=plain \
    run_with_file_progress "$label" "${tmp}/output.bin" 0 \
    bash -c 'printf data >"$1"' _ "${tmp}/output.bin" 2>&1)"

  [[ "$(<"${tmp}/output.bin")" == 'data' ]]
  [[ -z "$output" ]]
}

test_activity_progress_emits_heartbeat() {
  local output label='测试运行心跳'
  output="$(DOCKER_MIGRATE_PROGRESS_INTERVAL=1 \
    run_with_activity "$label" bash -c 'sleep 2' 2>&1)"
  grep -Eq "^\[进度\] ${label} · [12] 秒$" <<<"$output"
  ! grep -Fq '开始' <<<"$output"
  ! grep -Fq '无需按键' <<<"$output"
  ! grep -Fq '完成' <<<"$output"
}

test_activity_progress_preserves_shell_state_and_stdin() {
  local received
  set -e
  DOCKER_MIGRATE_PROGRESS_MODE=plain run_with_activity '测试 errexit 开启' true \
    >/dev/null 2>&1
  [[ $- == *e* ]]

  set +e
  DOCKER_MIGRATE_PROGRESS_MODE=plain run_with_activity '测试 errexit 关闭' true \
    >/dev/null 2>&1
  [[ $- != *e* ]]
  set -e

  received="$(printf 'sentinel\n' | DOCKER_MIGRATE_PROGRESS_MODE=plain \
    run_with_activity '测试标准输入' bash -c 'read -r value; printf "%s" "$value"' 2>/dev/null)"
  [[ "$received" == 'sentinel' ]]
}

assert_finishes_before_progress_interval() {
  local pid deadline
  "$@" &
  pid=$!
  deadline=$((SECONDS + 5))
  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
    sleep 0.1
  done
  wait "$pid"
}

progress_command_substitution_probe() {
  local output label='测试命令替换及时结束'
  output="$(DOCKER_MIGRATE_PROGRESS_INTERVAL=30 \
    run_with_activity "$label" bash -c 'printf sentinel' 2>&1)"
  [[ "$output" == 'sentinel' ]]
}

test_activity_progress_does_not_hold_command_substitution_open() {
  # interval 远大于截止时间；测试的是 watcher 结束后管道会立即关闭，
  # 不依赖具体机器上的毫秒级耗时。
  assert_finishes_before_progress_interval progress_command_substitution_probe
}

progress_process_substitution_probe() {
  local line count=0
  while IFS= read -r line; do
    [[ "$line" == 'sentinel' ]] && count=$((count + 1))
  done < <(DOCKER_MIGRATE_PROGRESS_INTERVAL=30 \
    run_with_activity '测试进程替换及时结束' bash -c 'printf "sentinel\n"' 2>/dev/null)
  [[ "$count" -eq 1 ]]
}

test_activity_progress_does_not_hold_process_substitution_open() {
  assert_finishes_before_progress_interval progress_process_substitution_probe
}

test_snapshot_cleanup_keeps_failed_records() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/docker" <<'SH'
#!/bin/sh
# 同时模拟 image rm 与 daemon 探测失败；不能把它误判为“镜像已不存在”。
exit 97
SH
  chmod +x "${tmp}/bin/docker"
  TEMP_IMAGES=(docker-migrate-snapshot:test)
  if PATH="${tmp}/bin:$PATH" cleanup_snapshot_images; then
    return 1
  fi
  [[ "${#TEMP_IMAGES[@]}" -eq 1 ]]
  [[ "${TEMP_IMAGES[0]}" == "docker-migrate-snapshot:test" ]]
}

test_final_result_summaries_are_unambiguous() {
  local success rolled_back incomplete source source_failure
  success="$(print_restore_result_summary SUCCESS 完成 \
    '容器：2 个（运行 1 / 暂停 0 / 停止 1）' \
    '数据：1 个 volume、1 个 bind 目录' \
    '下载文件与临时目录已删除' '' '' '12 秒')"
  [[ "$(grep -Fc 'Docker 迁移结果' <<<"$success")" -eq 1 ]]
  [[ "$(grep -Fc '结果：' <<<"$success")" -eq 1 ]]
  grep -Fq '结果：✅ 恢复成功' <<<"$success"
  grep -Fq '停止 1' <<<"$success"
  ! grep -Fq '若端口被占用' <<<"$success"

  rolled_back="$(print_restore_result_summary FAILED_ROLLED_BACK 恢复独立容器 \
    '' '' '恢复文件已保留，便于排查' '/tmp/session' '' '8 秒')"
  [[ "$(grep -Fc '结果：' <<<"$rolled_back")" -eq 1 ]]
  grep -Fq '结果：❌ 恢复失败，已安全回滚' <<<"$rolled_back"
  grep -Fq '目标端状态：旧服务与原数据已恢复' <<<"$rolled_back"

  incomplete="$(print_restore_result_summary FAILED_ROLLBACK_INCOMPLETE 回灌命名卷 \
    '' '' '恢复文件已保留，便于排查' '/tmp/session' '/tmp/rollback' '9 秒')"
  [[ "$(grep -Fc '结果：' <<<"$incomplete")" -eq 1 ]]
  grep -Fq '自动回滚未完全成功' <<<"$incomplete"
  grep -Fq '请勿直接启动相关容器' <<<"$incomplete"
  grep -Fq '回滚资料：/tmp/rollback' <<<"$incomplete"

  source="$(print_source_result_summary SUCCESS '已生成、完成加密并提供下载' \
    '已停止' '已恢复 2/2' '临时迁移文件已删除' '15 秒')"
  [[ "$(grep -Fc 'Docker 迁移结果' <<<"$source")" -eq 1 ]]
  [[ "$(grep -Fc '结果：' <<<"$source")" -eq 1 ]]
  grep -Fq '结果：✅ 源端任务已安全结束' <<<"$source"
  grep -Fq '源容器：已恢复 2/2' <<<"$source"
  grep -Fq '耗时：15 秒' <<<"$source"
  ! grep -Fq '迁移包：' <<<"$source"
  ! grep -Fq 'HTTP 服务：' <<<"$source"
  ! grep -Fq '清理：' <<<"$source"

  source_failure="$(print_source_result_summary FAILED '未完成' \
    '异常退出' '已恢复 2/2' '临时迁移文件已删除' '16 秒')"
  grep -Fq '结果：❌ 源端任务失败' <<<"$source_failure"
  grep -Fq '迁移包：未完成' <<<"$source_failure"
  grep -Fq 'HTTP 服务：异常退出' <<<"$source_failure"
  grep -Fq '清理：临时迁移文件已删除' <<<"$source_failure"
}

test_transfer_instructions_are_concise() {
  local url output
  url='http://127.0.0.1:8080/token/bundle.tar.gz.enc#sha256=abc'
  output="$(print_transfer_instructions "$url" interactive)"
  [[ "$(grep -Fc "$url" <<<"$output")" -eq 1 ]]
  [[ "$(grep -Fc '选择「2) 下载备份并恢复」' <<<"$output")" -eq 1 ]]
  grep -Fq '按回车停止传输服务并清理临时文件' <<<"$output"
  ! grep -Fq '可信渠道' <<<"$output"
  ! grep -Fq 'HTTP 服务日志' <<<"$output"
}

test_http_diagnostics_show_details_once() {
  local tmp output empty_output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  printf 'backend=python3\nsynthetic failure detail\n' >"${tmp}/http.log"

  export HTTP_DIAGNOSTICS_SHOWN=0
  output="$({
    print_http_diagnostics_once "${tmp}/http.log"
    print_http_diagnostics_once "${tmp}/http.log"
  } 2>&1)"
  [[ "$(grep -Fc 'HTTP 服务诊断（最后 20 行）' <<<"$output")" -eq 1 ]]
  [[ "$(grep -Fc 'synthetic failure detail' <<<"$output")" -eq 1 ]]
  [[ "$(grep -Fc "完整日志：${tmp}/http.log" <<<"$output")" -eq 1 ]]

  : >"${tmp}/empty.log"
  export HTTP_DIAGNOSTICS_SHOWN=0
  empty_output="$(print_http_diagnostics_once "${tmp}/empty.log" 2>&1)"
  grep -Fq 'HTTP 服务未提供额外日志' <<<"$empty_output"
}

test_netcat_fallback_rejects_unsupported_cli() {
  local tmp rc=0 calls
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/nc" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$NC_CALL_LOG"
exit 42
SH
  chmod +x "${tmp}/bin/nc"
  printf 'HTTP/1.1 200 OK\r\n\r\n' >"${tmp}/response"
  printf 'payload\n' >"${tmp}/transfer"
  : >"${tmp}/nc.calls"

  PATH="${tmp}/bin:$PATH" NC_CALL_LOG="${tmp}/nc.calls" \
    netcat_http_serve 8080 "${tmp}/response" "${tmp}/transfer" \
    >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]]
  calls="$(wc -l <"${tmp}/nc.calls")"
  [[ "$calls" -eq 3 ]]
}

test_generated_scripts_are_valid_bash() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bundle/runs" "${tmp}/bundle/meta"
  write_run_script demo "${tmp}/bundle/runs/demo.sh"
  write_bundle_restore_script "${tmp}/bundle/restore.sh"
  bash -n "${tmp}/bundle/runs/demo.sh"
  bash -n "${tmp}/bundle/restore.sh"
  grep -Fq 'restore_load_images()' "${tmp}/bundle/restore.sh"
  # 两类生成脚本都必须让 watcher 管理并隔离 timer，避免恢复时再次出现
  # 命令替换或进程替换等待完整心跳周期的性能回归。
  grep -Fq 'kill "$timer_pid"' "${tmp}/bundle/runs/demo.sh"
  grep -Fq 'sleep "$interval" </dev/null >/dev/null 2>&1 &' \
    "${tmp}/bundle/runs/demo.sh"
  grep -Fq 'kill "$timer_pid"' "${tmp}/bundle/restore.sh"
  grep -Fq 'sleep "$interval" </dev/null >/dev/null 2>&1 &' \
    "${tmp}/bundle/restore.sh"
  ! grep -Fq '此步骤可能耗时较长' "${tmp}/bundle/runs/demo.sh"
  ! grep -Fq '此步骤可能耗时较长' "${tmp}/bundle/restore.sh"
  ! grep -Fq '无需按键' "${tmp}/bundle/runs/demo.sh"
  ! grep -Fq '无需按键' "${tmp}/bundle/restore.sh"
  # TTY 更新必须一次覆盖并清除行尾，不能先输出 120 个空格制造空白帧。
  grep -Fq "printf '\\r%s\\033[K'" "${tmp}/bundle/runs/demo.sh"
  grep -Fq "printf '\\r%s\\033[K'" "${tmp}/bundle/restore.sh"
  grep -Fq "printf '\\r\\033[K'" "${tmp}/bundle/runs/demo.sh"
  grep -Fq "printf '\\r\\033[K'" "${tmp}/bundle/restore.sh"
  [[ "$(grep -Fc 'dm_tty_clear' "${tmp}/bundle/runs/demo.sh")" -ge 2 ]]
  [[ "$(grep -Fc 'dm_tty_clear' "${tmp}/bundle/restore.sh")" -ge 2 ]]
  ! grep -Fq '%-120s' "${tmp}/bundle/runs/demo.sh"
  ! grep -Fq '%-120s' "${tmp}/bundle/restore.sh"
}

test_generated_quiesce_list_rejects_partial_pipeline() {
  local tmp previous_pwd
  tmp="$(mktemp -d)"
  # 该测试会 source 生成脚本；RETURN trap 会在 source 返回时过早删除夹具。
  TEST_GENERATED_QUIESCE_TMP="$tmp"
  trap 'rm -rf "$TEST_GENERATED_QUIESCE_TMP"' EXIT
  mkdir -p "${tmp}/bundle"
  write_bundle_restore_script "${tmp}/bundle/restore.sh"
  awk '/^trap restore_nontransaction_exit_handler EXIT$/ { exit } { print }' \
    "${tmp}/bundle/restore.sh" >"${tmp}/restore-library.sh"

  previous_pwd="$PWD"
  # shellcheck source=/dev/null
  source "${tmp}/restore-library.sh"
  cd "$previous_pwd"

  printf 'shared-a\trunning\nshared-a\tpaused\n' >"${tmp}/shared.tsv"
  if transaction_build_quiesce_list "${tmp}/shared.tsv" \
    "${tmp}/missing-managed.list" "${tmp}/quiesce.list" 2>/dev/null; then
    return 1
  fi
  [[ ! -e "${tmp}/quiesce.list" ]]
  [[ ! -e "${tmp}/quiesce.list.partial.$$" ]]

  printf 'managed-b\nshared-a\n' >"${tmp}/managed.list"
  if transaction_build_quiesce_list "${tmp}/missing-shared.tsv" \
    "${tmp}/managed.list" "${tmp}/quiesce.list" 2>/dev/null; then
    return 1
  fi
  [[ ! -e "${tmp}/quiesce.list" ]]
  [[ ! -e "${tmp}/quiesce.list.partial.$$" ]]

  transaction_build_quiesce_list "${tmp}/shared.tsv" \
    "${tmp}/managed.list" "${tmp}/quiesce.list"
  [[ "$(<"${tmp}/quiesce.list")" == $'managed-b\nshared-a' ]]
}

test_checksums_detect_tampering() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bundle/meta"
  printf 'manifest\n' >"${tmp}/bundle/manifest.json"
  printf 'metadata\n' >"${tmp}/bundle/meta/demo.json"
  generate_bundle_checksums "${tmp}/bundle"
  verify_bundle_checksums "${tmp}/bundle" >/dev/null
  printf 'tampered\n' >>"${tmp}/bundle/meta/demo.json"
  ! verify_bundle_checksums "${tmp}/bundle" >/dev/null 2>&1

  printf 'metadata\n' >"${tmp}/bundle/meta/demo.json"
  printf 'unlisted\n' >"${tmp}/bundle/meta/unlisted.json"
  ! verify_bundle_checksums "${tmp}/bundle" >/dev/null 2>&1
}

test_archive_layout_rejects_unsafe_members_in_two_scans() {
  local tmp real_tar calls
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/safe/root" "${tmp}/symlink/root" "${tmp}/hardlink/root" "${tmp}/bin"
  printf 'ok\n' >"${tmp}/safe/root/file"
  tar -czf "${tmp}/safe.tar.gz" -C "${tmp}/safe" root
  archive_layout_is_safe "${tmp}/safe.tar.gz"

  ln -s /etc/passwd "${tmp}/symlink/root/link"
  tar -czf "${tmp}/symlink.tar.gz" -C "${tmp}/symlink" root
  ! archive_layout_is_safe "${tmp}/symlink.tar.gz"

  printf 'hardlink target\n' >"${tmp}/hardlink/root/target"
  ln "${tmp}/hardlink/root/target" "${tmp}/hardlink/root/link"
  tar -czf "${tmp}/hardlink.tar.gz" -C "${tmp}/hardlink" root
  ! archive_layout_is_safe "${tmp}/hardlink.tar.gz"

  printf 'not a gzip archive\n' >"${tmp}/corrupt.tar.gz"
  ! archive_layout_is_safe "${tmp}/corrupt.tar.gz"

  real_tar="$(command -v tar)"
  cat >"${tmp}/bin/tar" <<'SH'
#!/bin/sh
printf 'call\n' >>"$TAR_CALL_LOG"
exec "$REAL_TAR" "$@"
SH
  chmod +x "${tmp}/bin/tar"
  : >"${tmp}/tar.calls"
  PATH="${tmp}/bin:$PATH" REAL_TAR="$real_tar" TAR_CALL_LOG="${tmp}/tar.calls" \
    archive_layout_is_safe "${tmp}/safe.tar.gz"
  calls="$(wc -l <"${tmp}/tar.calls" | tr -d '[:space:]')"
  [[ "$calls" -eq 2 ]]
}

test_inner_archive_members_validate_structure_not_symlink_targets() {
  local tmp archive_case
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/safe/prefix" "${tmp}/wrong/other"
  printf 'ok\n' >"${tmp}/safe/prefix/file"
  ln -s file "${tmp}/safe/prefix/symlink"
  ln "${tmp}/safe/prefix/file" "${tmp}/safe/prefix/hardlink"
  ln -s /etc/passwd "${tmp}/safe/prefix/absolute"
  ln -s ../outside "${tmp}/safe/prefix/relative"
  ln -s missing "${tmp}/safe/prefix/dangling"
  ln -s loop "${tmp}/safe/prefix/loop"
  tar -czf "${tmp}/safe.tgz" -C "${tmp}/safe" prefix
  tar -czf "${tmp}/wrong.tgz" -C "${tmp}/wrong" other
  printf 'not a gzip archive\n' >"${tmp}/corrupt.tgz"

  write_bundle_restore_script "${tmp}/restore.sh"
  # archive_members_safe 是生成脚本中的纯函数；只提取该函数，避免执行恢复入口。
  # source 返回也会触发 RETURN trap，先临时解除，避免测试目录被提前删除。
  trap - RETURN
  # shellcheck disable=SC1090
  source <(sed -n '/^archive_members_safe() {/,/^}/p' "${tmp}/restore.sh")
  trap 'rm -rf "$tmp"' RETURN

  archive_members_safe "${tmp}/safe.tgz" prefix
  if archive_members_safe "${tmp}/wrong.tgz" prefix ||
    archive_members_safe "${tmp}/corrupt.tgz" prefix; then
    return 1
  fi

  # 使用真实 tar 元数据覆盖顺序、重复路径、扩展头和硬链接目标。
  python3 - "$tmp" <<'PY'
import io
from pathlib import Path
import sys
import tarfile

root = Path(sys.argv[1])

def write(name, members, fmt=tarfile.PAX_FORMAT):
    with tarfile.open(root / (name + ".tgz"), "w:gz", format=fmt) as archive:
        for path, kind, target in members:
            info = tarfile.TarInfo(path)
            info.type = kind
            info.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
            if kind == tarfile.REGTYPE:
                info.size = 4
                archive.addfile(info, io.BytesIO(b"data"))
            else:
                info.linkname = target
                archive.addfile(info)

D, F, S, H = tarfile.DIRTYPE, tarfile.REGTYPE, tarfile.SYMTYPE, tarfile.LNKTYPE
base = [("prefix", D, "")]
write("safe-hardlink-chain", base + [("prefix/file", F, ""),
    ("prefix/hard", H, "prefix/file"), ("prefix/chain", H, "prefix/hard")])
write("safe-repeat-dir", base + base + [("prefix/file", F, "")])
write("safe-file-bind", [("prefix", F, "")])
write("safe-fifo", base + [("prefix/pipe", tarfile.FIFOTYPE, "")])
link = ("prefix/link", S, "/tmp/outside")
child = ("prefix/link/overwrite", F, "")
write("symlink-parent-first", base + [link, child])
write("symlink-parent-last", base + [child, link])
write("file-parent", base + [("prefix/file", F, ""), ("prefix/file/child", F, "")])
write("hardlink-parent", base + [("prefix/file", F, ""),
    ("prefix/link", H, "prefix/file"), ("prefix/link/child", F, "")])
write("absolute-member", [("/prefix/file", F, "")])
write("dotdot-member", [("prefix/../outside", F, "")])
write("root-file", [(".", F, "")])
write("hardlink-absolute", base + [("prefix/link", H, "/etc/passwd")])
write("hardlink-outside", base + [("prefix/link", H, "../outside")])
write("hardlink-wrong-prefix", base + [("prefix/link", H, "other/file")])
write("hardlink-missing", base + [("prefix/link", H, "prefix/missing")])
write("hardlink-symlink", base + [("prefix/link", H, "prefix/sym"),
    ("prefix/sym", S, "/etc/passwd")])
write("hardlink-cycle", base + [("prefix/one", H, "prefix/two"),
    ("prefix/two", H, "prefix/one")])
write("duplicate-file", base + [("prefix/file", F, ""), ("prefix/file", F, "")])
write("duplicate-type", base + [("prefix/link", D, ""), link])
write("device", base + [("prefix/device", tarfile.CHRTYPE, "")])
long_name = "prefix/" + "long-" * 30
for name, fmt in [("pax", tarfile.PAX_FORMAT), ("gnu", tarfile.GNU_FORMAT)]:
    write("safe-" + name, base + [(long_name, F, ""),
        ("prefix/link", S, "/" + "outside-" * 30)], fmt)
    write("unsafe-" + name, base + [(long_name, S, "../outside"),
        (long_name + "/child", F, "")], fmt)
    write("unsafe-" + name + "-hardlink", base +
        [("prefix/link", H, "/" + "outside-" * 30)], fmt)
    write("unsafe-" + name + "-path", [(long_name + "/../outside", F, "")], fmt)
data = bytearray((root / "safe.tgz").read_bytes())
data[-8] ^= 1  # gzip CRC：tar 内容可列出，但完整压缩流已损坏。
(root / "corrupt-trailer.tgz").write_bytes(data)
PY
  for archive_case in safe-hardlink-chain safe-repeat-dir safe-file-bind safe-fifo safe-pax safe-gnu; do
    archive_members_safe "${tmp}/${archive_case}.tgz" prefix
  done
  for archive_case in symlink-parent-first symlink-parent-last file-parent hardlink-parent \
    absolute-member dotdot-member root-file hardlink-absolute hardlink-outside \
    hardlink-wrong-prefix hardlink-missing hardlink-symlink hardlink-cycle \
    duplicate-file duplicate-type device unsafe-pax unsafe-gnu \
    unsafe-pax-hardlink unsafe-gnu-hardlink unsafe-pax-path unsafe-gnu-path corrupt-trailer; do
    if archive_members_safe "${tmp}/${archive_case}.tgz" prefix; then
      printf 'unsafe or corrupt archive unexpectedly accepted: %s\n' "$archive_case" >&2
      return 1
    fi
  done
  if archive_members_safe "${tmp}/root-file.tgz"; then
    return 1
  fi
}

test_archive_normalizer_preserves_data_and_removes_ambiguous_metadata() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  write_bundle_restore_script "${tmp}/restore.sh"
  trap - RETURN
  # shellcheck disable=SC1090
  source <(sed -n '/^archive_members_safe() {/,/^}/p; /^archive_normalized_stream() {/,/^}/p' "${tmp}/restore.sh")
  trap 'rm -rf "$tmp"' RETURN
  python3 - "${tmp}/source.tgz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz", format=tarfile.PAX_FORMAT) as archive:
    members = [
        ("./prefix", tarfile.DIRTYPE, "", None),
        ("./prefix/file", tarfile.REGTYPE, "", b"normalizer payload\n"),
        ("./prefix/empty", tarfile.REGTYPE, "/etc/passwd", b""),
        ("./prefix/sym", tarfile.SYMTYPE, "/outside/../missing", None),
        ("./prefix/hard", tarfile.LNKTYPE, "./prefix/file", None),
        ("./prefix/pipe", tarfile.FIFOTYPE, "", None),
    ]
    for name, kind, target, payload in members:
        info = tarfile.TarInfo(name)
        info.type = kind
        info.linkname = target
        info.mode, info.uid, info.gid, info.mtime = 0o640, 123, 456, 1234
        info.size = len(payload) if payload is not None else 512
        info.pax_headers = {"comment": "discard irrelevant extension metadata"}
        archive.addfile(info, io.BytesIO(payload) if payload is not None else None)
PY
  archive_members_safe "${tmp}/source.tgz" prefix
  archive_normalized_stream "${tmp}/source.tgz" >"${tmp}/normalized.tar"
  python3 - "${tmp}/normalized.tar" <<'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:") as archive:
    members = {member.name: member for member in archive}
    assert set(members) == {"prefix", "prefix/file", "prefix/empty", "prefix/sym",
                            "prefix/hard", "prefix/pipe"}
    assert archive.extractfile(members["prefix/file"]).read() == b"normalizer payload\n"
    assert archive.extractfile(members["prefix/empty"]).read() == b""
    assert members["prefix/empty"].isreg() and members["prefix/empty"].linkname == ""
    assert members["prefix/sym"].issym()
    assert members["prefix/sym"].linkname == "/outside/../missing"
    assert members["prefix/hard"].islnk() and members["prefix/hard"].linkname == "prefix/file"
    assert members["prefix/pipe"].isfifo()
    for member in members.values():
        assert member.pax_headers == {}
        assert (member.mode, member.uid, member.gid, member.mtime) == (0o640, 123, 456, 1234)
        if not member.isreg():
            assert member.size == 0
PY
}

test_restore_data_diagnostics_are_private_and_nonintrusive() {
  local tmp BUNDLE_DIR output rc=0 logfile mode
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  BUNDLE_DIR="${tmp}/bundle"
  mkdir -p "$BUNDLE_DIR"
  printf 'manifest\n' >"${BUNDLE_DIR}/manifest.json"
  write_bundle_restore_script "${BUNDLE_DIR}/restore.sh"
  generate_bundle_checksums "$BUNDLE_DIR"
  trap - RETURN
  # shellcheck disable=SC1090
  source <(sed -n '/^restore_data_with_diagnostics() {/,/^}/p' "${BUNDLE_DIR}/restore.sh")
  trap 'rm -rf "$tmp"' RETURN

  output="$(restore_data_with_diagnostics '命名卷：success' bash -c 'printf noisy; printf stderr >&2')"
  [[ -z "$output" ]]
  [[ -z "$(find "$tmp" -maxdepth 1 -type f -name 'docker-migrate-data.*' -print)" ]]

  output="$(restore_data_with_diagnostics '命名卷：failure' bash -c \
    'printf "first line retained only in the log\n"; for i in {1..25}; do printf "detail %s\n" "$i"; done; printf "tar: cannot extract file\n" >&2; exit 37' 2>&1)" || rc=$?
  [[ "$rc" -eq 37 ]]
  [[ "$output" == *'命名卷：failure'* && "$output" == *'退出码：37'* ]]
  [[ "$output" == *'tar: cannot extract file'* ]]
  [[ "$output" != *'first line retained only in the log'* ]]
  logfile="$(sed -n 's/^详细日志：//p' <<<"$output")"
  [[ -f "$logfile" && "$logfile" == "${BUNDLE_DIR}/../docker-migrate-data."* ]]
  mode="$(stat -c '%a' "$logfile" 2>/dev/null || stat -f '%Lp' "$logfile")"
  [[ "$mode" == 600 ]]
  grep -Fq 'first line retained only in the log' "$logfile"
  grep -Fq 'tar: cannot extract file' "$logfile"
  verify_bundle_checksums "$BUNDLE_DIR" >/dev/null
}

test_restore_interruption_keeps_final_summary_visible() {
  local tmp BUNDLE_DIR output rc logfile handler expected_status
  # shellcheck disable=SC2034
  local RESTORE_COMMIT_STARTED=0 TRANSACTION_ACTIVE=1 RESTORE_TRANSACTION_DIR=""
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  BUNDLE_DIR="${tmp}/bundle"
  mkdir -p "$BUNDLE_DIR"
  write_bundle_restore_script "${BUNDLE_DIR}/restore.sh"
  trap - RETURN
  # shellcheck disable=SC1090
  source <(sed -n \
    '/^restore_data_with_diagnostics() {/,/^}/p; /^restore_diagnostic_output() {/,/^}/p; /^restore_nontransaction_exit_handler() {/,/^}/p; /^transaction_exit_handler() {/,/^}/p' \
    "${BUNDLE_DIR}/restore.sh")
  trap 'rm -rf "$tmp"' RETURN

  transaction_release_lock() { :; }
  transaction_rollback() { printf '回滚进度可见\n'; }
  restore_finish_result() { printf '最终摘要：%s\n' "$1"; }
  interrupt_data_callback() {
    printf 'callback-private-details\n'
    exit 143
  }

  for handler in restore_nontransaction_exit_handler transaction_exit_handler; do
    rc=0
    expected_status="INTERRUPTED"
    [[ "$handler" != transaction_exit_handler ]] || expected_status="INTERRUPTED_ROLLED_BACK"
    output="$(
      (
        if [[ "$handler" == transaction_exit_handler ]]; then
          trap transaction_exit_handler EXIT
        else
          trap restore_nontransaction_exit_handler EXIT
        fi
        restore_data_with_diagnostics '命名卷：interrupted' interrupt_data_callback
      ) 2>&1
    )" || rc=$?
    [[ "$rc" -eq 143 ]]
    [[ "$output" == *"最终摘要：${expected_status}"* ]]
    [[ "$output" != *'callback-private-details'* ]]
    if [[ "$handler" == transaction_exit_handler ]]; then
      [[ "$output" == *'回滚进度可见'* ]]
    fi
    logfile="$(sed -n 's/^详细日志：//p' <<<"$output")"
    [[ -f "$logfile" ]]
    grep -Fq 'callback-private-details' "$logfile"
  done
}

test_compose_env_file_parser() {
  local tmp
  local -a actual expected
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  cat >"${tmp}/compose.yml" <<'YAML'
services:
  scalar:
    env_file: .env.scalar
  list:
    env_file:
      - .env.first
      - path: config/.env.second
        required: false
YAML
  mapfile -t actual < <(compose_env_file_refs "${tmp}/compose.yml")
  expected=(.env.scalar .env.first config/.env.second)
  [[ "${actual[*]}" == "${expected[*]}" ]]
}

test_restore_client_cleanup_on_interrupts_and_errors() {
  local tmp base sentinel spec signal expected session output rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  base="${tmp}/restore base"
  mkdir -p "$base"
  sentinel="${base}/keep.txt"
  printf 'keep\n' >"$sentinel"

  for spec in INT:130 TERM:143 HUP:129; do
    signal="${spec%%:*}"
    expected="${spec##*:}"
    session="$(mktemp -d "${base}/restore.XXXXXX")"
    set +e
    output="$(
      (
        restore_client_arm_session_cleanup "$base" "$session"
        printf 'partial download\n' >"${session}/bundle.tar.gz.enc.partial"
        kill -s "$signal" "$BASHPID"
        sleep 5
      ) 2>&1
    )"
    rc=$?
    set -e

    [[ "$rc" -eq "$expected" ]]
    [[ ! -e "$session" ]]
    [[ "$(grep -Fc '已清理中断产生的下载与临时文件' <<<"$output")" -eq 1 ]]
  done

  session="$(mktemp -d "${base}/restore.XXXXXX")"
  set +e
  (
    restore_client_arm_session_cleanup "$base" "$session"
    printf 'partial download\n' >"${session}/bundle.tar.gz.partial"
    exit 56
  ) >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 56 ]]
  [[ ! -e "$session" ]]
  [[ "$(<"$sentinel")" == "keep" ]]
  [[ -z "$(find "$base" -mindepth 1 -maxdepth 1 -type d -name 'restore.*' -print -quit)" ]]
}

test_restore_client_cleanup_preserves_transaction_diagnostics() {
  local tmp base session rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  base="${tmp}/restore base"
  mkdir -p "$base"
  session="$(mktemp -d "${base}/restore.XXXXXX")"

  set +e
  (
    restore_client_arm_session_cleanup "$base" "$session"
    printf 'rollback diagnostics\n' >"${session}/restore-result.json"
    restore_client_begin_restore
    exit 23
  ) >/dev/null 2>&1
  rc=$?
  set -e

  [[ "$rc" -eq 23 ]]
  [[ "$(<"${session}/restore-result.json")" == "rollback diagnostics" ]]
}

test_external_bundle_digest() {
  local tmp digest url legacy_url secret iv mac
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  printf 'trusted bundle\n' >"${tmp}/bundle.tar.gz"
  digest="$(sha256_file "${tmp}/bundle.tar.gz")"
  secret="$(printf '01%.0s' {1..64})"
  iv="$(printf '23%.0s' {1..16})"
  mac="$(printf '45%.0s' {1..32})"
  url="http://192.0.2.1/token/bundle.tar.gz.enc#sha256=${digest}&enc=${BUNDLE_ENCRYPTION_SCHEME}&secret=${secret}&iv=${iv}&mac=${mac}"
  legacy_url="http://192.0.2.1/token/bundle.tar.gz#sha256=${digest}"

  [[ "$(bundle_download_url "$url")" == "http://192.0.2.1/token/bundle.tar.gz.enc" ]]
  [[ "$(bundle_expected_sha256 "$url")" == "$digest" ]]
  [[ "$(bundle_encryption_scheme "$url")" == "$BUNDLE_ENCRYPTION_SCHEME" ]]
  [[ "$(bundle_encryption_secret "$url")" == "$secret" ]]
  [[ "$(bundle_encryption_iv "$url")" == "$iv" ]]
  [[ "$(bundle_encryption_mac "$url")" == "$mac" ]]
  [[ "$(bundle_fragment_value "$url" missing)" == "" ]]
  [[ "$(restore_prompt_url "$url")" == "$url" ]]
  valid_hex_length "$secret" 128
  valid_hex_length "$iv" 32
  valid_hex_length "$mac" 64

  # Legacy plaintext links remain parseable and do not pretend to be encrypted.
  [[ "$(bundle_download_url "$legacy_url")" == "http://192.0.2.1/token/bundle.tar.gz" ]]
  [[ "$(bundle_expected_sha256 "$legacy_url")" == "$digest" ]]
  [[ -z "$(bundle_encryption_scheme "$legacy_url")" ]]
  [[ -z "$(bundle_encryption_secret "$legacy_url")" ]]
  [[ "$(restore_prompt_url "$legacy_url")" == "$legacy_url" ]]
  ! (restore_prompt_url 'file:///tmp/bundle.tar.gz#sha256=abc' >/dev/null 2>&1)
  ! (restore_prompt_url '--config.tar.gz#sha256=abc' >/dev/null 2>&1)
  valid_sha256 "$digest"
  verify_archive_sha256 "${tmp}/bundle.tar.gz" "$digest"

  printf 'tampered\n' >>"${tmp}/bundle.tar.gz"
  ! verify_archive_sha256 "${tmp}/bundle.tar.gz" "$digest"
  ! valid_sha256 not-a-digest
}

test_encrypted_bundle_round_trip() {
  local tmp marker secret encryption_key mac_key iv mac
  command -v openssl >/dev/null 2>&1 || return 0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  marker="docker-migrate-confidential-marker-$RANDOM-$$"
  secret="$(printf '0123456789abcdef%.0s' {1..8})"
  iv="00112233445566778899aabbccddeeff"
  encryption_key="$(bundle_secret_encryption_key "$secret")"
  mac_key="$(bundle_secret_mac_key "$secret")"
  printf '%s\n%s\n' "$marker" 'private migration payload' >"${tmp}/plain.tar.gz"

  bundle_encrypt_file "${tmp}/plain.tar.gz" "${tmp}/bundle.tar.gz.enc" "$encryption_key" "$iv"
  [[ -s "${tmp}/bundle.tar.gz.enc" ]]
  ! LC_ALL=C grep -aFq -- "$marker" "${tmp}/bundle.tar.gz.enc"

  mac="$(bundle_hmac_sha256_file "${tmp}/bundle.tar.gz.enc" "$mac_key" "$iv")"
  valid_sha256 "$mac"
  verify_bundle_hmac "${tmp}/bundle.tar.gz.enc" "$mac_key" "$iv" "$mac"
  bundle_decrypt_file "${tmp}/bundle.tar.gz.enc" "${tmp}/round-trip.tar.gz" "$encryption_key" "$iv"
  cmp -s "${tmp}/plain.tar.gz" "${tmp}/round-trip.tar.gz"
}

test_streaming_pack_encrypt_round_trip() {
  local tmp secret encryption_key mac_key iv digests sha mac extra
  command -v openssl >/dev/null 2>&1 || return 0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bundle/rid/meta"
  printf 'streamed migration payload\n' >"${tmp}/bundle/rid/meta/data.txt"
  secret="$(printf '0123456789abcdef%.0s' {1..8})"
  encryption_key="$(bundle_secret_encryption_key "$secret")"
  mac_key="$(bundle_secret_mac_key "$secret")"
  iv="00112233445566778899aabbccddeeff"

  digests="$(bundle_pack_encrypt_directory "${tmp}/bundle" rid \
    "${tmp}/bundle.tar.gz.enc" "$encryption_key" "$mac_key" "$iv")"
  IFS=$'\t' read -r sha mac extra <<<"$digests"
  [[ -z "$extra" ]]
  valid_sha256 "$sha"
  valid_sha256 "$mac"
  [[ "$sha" == "$(sha256_file "${tmp}/bundle.tar.gz.enc")" ]]
  [[ "$mac" == "$(bundle_hmac_sha256_file \
    "${tmp}/bundle.tar.gz.enc" "$mac_key" "$iv")" ]]
  verify_bundle_digests "${tmp}/bundle.tar.gz.enc" "$mac_key" "$iv" "$sha" "$mac"
  ! verify_bundle_digests "${tmp}/bundle.tar.gz.enc" "$mac_key" "$iv" \
    "$(printf '0%.0s' {1..64})" "$mac"

  bundle_decrypt_file "${tmp}/bundle.tar.gz.enc" "${tmp}/round-trip.tar.gz" \
    "$encryption_key" "$iv"
  mkdir -p "${tmp}/unpacked"
  tar -xzf "${tmp}/round-trip.tar.gz" -C "${tmp}/unpacked"
  cmp -s "${tmp}/bundle/rid/meta/data.txt" "${tmp}/unpacked/rid/meta/data.txt"

  # 任一上游步骤失败都不能留下可被误发布的密文文件。
  if (
    gzip_compress_stream() { return 42; }
    bundle_pack_encrypt_directory "${tmp}/bundle" rid "${tmp}/failed.enc" \
      "$encryption_key" "$mac_key" "$iv"
  ); then
    return 1
  fi
  [[ ! -e "${tmp}/failed.enc" ]]
}

test_batch_stop_uses_one_docker_call_and_verifies_all() {
  local tmp stop_calls inspect_calls
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/docker" <<'SH'
#!/bin/sh
case "$1" in
  stop)
    shift
    printf 'stop\t%s\n' "$*" >>"$DOCKER_CALL_LOG"
    ;;
  inspect)
    shift
    for name in "$@"; do :; done
    printf 'inspect\t%s\n' "$name" >>"$DOCKER_CALL_LOG"
    if [ "${FAIL_NAME:-}" = "$name" ]; then
      printf 'true\n'
    else
      printf 'false\n'
    fi
    ;;
  *) exit 97 ;;
esac
SH
  chmod +x "${tmp}/bin/docker"
  : >"${tmp}/docker.calls"

  PATH="${tmp}/bin:$PATH" DOCKER_CALL_LOG="${tmp}/docker.calls" \
    DOCKER_MIGRATE_PROGRESS_MODE=plain \
    docker_stop_batch_verified '批量停机测试' one two three >/dev/null 2>&1
  stop_calls="$(grep -c '^stop' "${tmp}/docker.calls")"
  inspect_calls="$(grep -c '^inspect' "${tmp}/docker.calls")"
  [[ "$stop_calls" -eq 1 ]]
  [[ "$inspect_calls" -eq 3 ]]

  ! PATH="${tmp}/bin:$PATH" DOCKER_CALL_LOG="${tmp}/docker.calls" FAIL_NAME=two \
    DOCKER_MIGRATE_PROGRESS_MODE=plain \
    docker_stop_batch_verified '批量停机失败测试' one two three >/dev/null 2>&1
}

test_encrypted_bundle_rejects_tampering() {
  local tmp secret wrong_secret encryption_key wrong_key mac_key wrong_mac_key iv mac bad_mac
  command -v openssl >/dev/null 2>&1 || return 0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  secret="$(printf '0123456789abcdef%.0s' {1..8})"
  wrong_secret="$(printf 'f%.0s' {1..128})"
  encryption_key="$(bundle_secret_encryption_key "$secret")"
  mac_key="$(bundle_secret_mac_key "$secret")"
  wrong_key="$(bundle_secret_encryption_key "$wrong_secret")"
  wrong_mac_key="$(bundle_secret_mac_key "$wrong_secret")"
  iv="00112233445566778899aabbccddeeff"
  printf 'authenticated migration payload\n' >"${tmp}/plain.tar.gz"

  bundle_encrypt_file "${tmp}/plain.tar.gz" "${tmp}/bundle.tar.gz.enc" "$encryption_key" "$iv"
  mac="$(bundle_hmac_sha256_file "${tmp}/bundle.tar.gz.enc" "$mac_key" "$iv")"

  # CTR has no built-in key check; a wrong key must at least produce different bytes.
  bundle_decrypt_file "${tmp}/bundle.tar.gz.enc" "${tmp}/wrong-key.tar.gz" "$wrong_key" "$iv"
  ! cmp -s "${tmp}/plain.tar.gz" "${tmp}/wrong-key.tar.gz"
  ! verify_bundle_hmac "${tmp}/bundle.tar.gz.enc" "$wrong_mac_key" "$iv" "$mac"

  cp "${tmp}/bundle.tar.gz.enc" "${tmp}/tampered.enc"
  printf 'tamper' >>"${tmp}/tampered.enc"
  ! verify_bundle_hmac "${tmp}/tampered.enc" "$mac_key" "$iv" "$mac"

  if [[ "${mac:0:1}" == "0" ]]; then
    bad_mac="1${mac:1}"
  else
    bad_mac="0${mac:1}"
  fi
  ! verify_bundle_hmac "${tmp}/bundle.tar.gz.enc" "$mac_key" "$iv" "$bad_mac"
  ! valid_hex_length short 128
}

test_mount_path_overlap_detection() {
  mount_paths_overlap /srv/data /srv/data
  mount_paths_overlap /srv/data /srv/data/cache
  mount_paths_overlap /srv/data/cache /srv/data
  mount_paths_overlap / /var/lib/docker
  ! mount_paths_overlap /srv/data /srv/database
  ! mount_paths_overlap /opt/app /opt/app2
}

test_manifest_rejects_unsafe_run_paths() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bundle/runs" "${tmp}/bundle/meta"
  printf '#!/usr/bin/env bash\n' >"${tmp}/bundle/runs/safe.sh"
  jq -n '[{Name:"/safe"}]' >"${tmp}/bundle/meta/safe.inspect.json"
  jq -n '{images:[],networks:[],projects:[],volumes:[],binds:[],runs:["runs/safe.sh"]}' \
    >"${tmp}/bundle/manifest.json"
  bundle_manifest_is_safe "${tmp}/bundle"

  jq -n '[{Name:"/different"}]' >"${tmp}/bundle/meta/safe.inspect.json"
  ! bundle_manifest_is_safe "${tmp}/bundle"
  jq -n '[{Name:"/safe"}]' >"${tmp}/bundle/meta/safe.inspect.json"

  jq -n '{images:[],networks:[],projects:[],volumes:[],binds:[],runs:["../evil.sh"]}' \
    >"${tmp}/bundle/manifest.json"
  ! bundle_manifest_is_safe "${tmp}/bundle"
}

test_manifest_rejects_control_characters_in_bind_paths() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bundle"
  jq -n --arg host $'/srv/data\tforged' '{
    images:[],networks:[],projects:[],volumes:[],runs:[],
    binds:[{host:$host,dest:"/data",file:"bind_data.tgz"}]
  }' >"${tmp}/bundle/manifest.json"
  ! bundle_manifest_is_safe "${tmp}/bundle"
}

test_manifest_validates_compose_working_directories() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bundle"
  jq -n '{
    images:[],networks:[],volumes:[],binds:[],runs:[],
    projects:[{name:"safe",working_dir:"/srv/app",files:[],config_files:[]}]
  }' >"${tmp}/bundle/manifest.json"
  bundle_manifest_is_safe "${tmp}/bundle"

  jq '.projects[0].working_dir = "relative/path"' "${tmp}/bundle/manifest.json" \
    >"${tmp}/bundle/manifest.invalid.json"
  mv "${tmp}/bundle/manifest.invalid.json" "${tmp}/bundle/manifest.json"
  ! bundle_manifest_is_safe "${tmp}/bundle"

  jq '.projects[0].working_dir = "/srv/../etc"' "${tmp}/bundle/manifest.json" \
    >"${tmp}/bundle/manifest.invalid.json"
  mv "${tmp}/bundle/manifest.invalid.json" "${tmp}/bundle/manifest.json"
  ! bundle_manifest_is_safe "${tmp}/bundle"
}

run_test "docker image save failure status is preserved" test_progress_propagates_failure
run_test "plain activity progress preserves failure status" test_activity_progress_plain_failure_contract
run_test "progress percentages are shown only for known totals" test_progress_render_reports_only_real_percentages
run_test "TTY progress redraw avoids intermediate blank frames" test_tty_progress_redraw_has_no_blank_frame
run_test "quick successful progress operations stay silent" test_quick_file_progress_is_silent
run_test "long activity emits only a numeric heartbeat" test_activity_progress_emits_heartbeat
run_test "activity progress preserves errexit and command stdin" test_activity_progress_preserves_shell_state_and_stdin
run_test "activity progress releases command substitution pipes" test_activity_progress_does_not_hold_command_substitution_open
run_test "activity progress releases process substitution pipes" test_activity_progress_does_not_hold_process_substitution_open
run_test "snapshot cleanup preserves records when Docker is unavailable" test_snapshot_cleanup_keeps_failed_records
run_test "final result summaries expose one unambiguous status" test_final_result_summaries_are_unambiguous
run_test "transfer instructions show one link and one clear workflow" test_transfer_instructions_are_concise
run_test "HTTP diagnostics show useful details once" test_http_diagnostics_show_details_once
run_test "Netcat fallback rejects unsupported CLI variants" test_netcat_fallback_rejects_unsupported_cli
run_test "generated restore scripts parse as Bash" test_generated_scripts_are_valid_bash
run_test "generated restore rejects an incomplete quiesce list" test_generated_quiesce_list_rejects_partial_pipeline
run_test "bundle checksum detects tampering" test_checksums_detect_tampering
run_test "top-level archive rejects unsafe members in two scans" test_archive_layout_rejects_unsafe_members_in_two_scans
run_test "inner archive checks structure while preserving normal links" test_inner_archive_members_validate_structure_not_symlink_targets
run_test "normalized archive preserves data without ambiguous headers" test_archive_normalizer_preserves_data_and_removes_ambiguous_metadata
run_test "restore data diagnostics are private and preserve bundle checksums" test_restore_data_diagnostics_are_private_and_nonintrusive
run_test "interrupted restore exposes final summary outside the data log" test_restore_interruption_keeps_final_summary_visible
run_test "Compose env_file parser handles scalar/list/long syntax" test_compose_env_file_parser
run_test "restore client cleans interrupted and failed preparation sessions" test_restore_client_cleanup_on_interrupts_and_errors
run_test "restore client preserves diagnostics after transaction handoff" test_restore_client_cleanup_preserves_transaction_diagnostics
run_test "encrypted and legacy URL fragments are parsed safely" test_external_bundle_digest
run_test "encrypted bundle round-trips without exposing plaintext" test_encrypted_bundle_round_trip
run_test "streaming compression and encryption preserves bundle and digests" test_streaming_pack_encrypt_round_trip
run_test "batch stop uses one Docker call and verifies every container" test_batch_stop_uses_one_docker_call_and_verifies_all
run_test "encrypted bundle rejects wrong keys and tampering" test_encrypted_bundle_rejects_tampering
run_test "bind mount overlap detection respects path boundaries" test_mount_path_overlap_detection
run_test "manifest rejects executable paths outside runs" test_manifest_rejects_unsafe_run_paths
run_test "manifest rejects control characters in bind paths" test_manifest_rejects_control_characters_in_bind_paths
run_test "manifest validates Compose working directories" test_manifest_validates_compose_working_directories

printf '\nTests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
