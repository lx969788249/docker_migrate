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
  grep -Fq '保存镜像 images.tar：失败' <<<"$output"
  ! grep -Fq '保存镜像 images.tar：完成' <<<"$output"
}

test_activity_progress_plain_failure_contract() {
  local output rc label='测试失败传播'
  set +e
  output="$(DOCKER_MIGRATE_PROGRESS_MODE=plain \
    run_with_activity "$label" bash -c 'exit 7' 2>&1)"
  rc=$?
  set -e

  [[ "$rc" -eq 7 ]]
  [[ "$(grep -Fc "[进度] ${label}：开始" <<<"$output")" -eq 1 ]]
  [[ "$(grep -Fc "[进度] ${label}：失败" <<<"$output")" -eq 1 ]]
  ! grep -Fq "[进度] ${label}：完成" <<<"$output"
}

test_progress_render_reports_only_real_percentages() {
  local known unknown clamped
  known="$(progress_render '已知总量' 50 100 0)"
  grep -Fq '50%' <<<"$known"

  unknown="$(progress_render '未知总量' 2048 0 0)"
  grep -Fq '已处理 2KB' <<<"$unknown"
  [[ "$unknown" != *%* ]]

  clamped="$(progress_render '超出总量' 150 100 0)"
  grep -Fq '100%' <<<"$clamped"
  grep -Fq '100B/100B' <<<"$clamped"
}

test_file_progress_plain_reports_written_bytes() {
  local tmp output label='测试文件写入'
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  output="$(DOCKER_MIGRATE_PROGRESS_MODE=plain \
    run_with_file_progress "$label" "${tmp}/output.bin" 0 \
    bash -c 'printf data >"$1"' _ "${tmp}/output.bin" 2>&1)"

  [[ "$(<"${tmp}/output.bin")" == 'data' ]]
  [[ "$(grep -Fc "[进度] ${label}：开始" <<<"$output")" -eq 1 ]]
  [[ "$(grep -Fc "[进度] ${label}：完成" <<<"$output")" -eq 1 ]]
  grep -Fq '已处理 4B' <<<"$output"
  ! grep -Fq "[进度] ${label}：失败" <<<"$output"
}

test_activity_progress_emits_heartbeat() {
  local output label='测试运行心跳'
  output="$(DOCKER_MIGRATE_PROGRESS_INTERVAL=1 \
    run_with_activity "$label" bash -c 'sleep 2' 2>&1)"
  grep -Fq "[进度] ${label}：仍在执行" <<<"$output"
  grep -Fq '无需按键' <<<"$output"
  grep -Fq "[进度] ${label}：完成" <<<"$output"
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
  local success rolled_back incomplete source
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

test_archive_layout_rejects_symlinks() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/safe/root" "${tmp}/unsafe/root"
  printf 'ok\n' >"${tmp}/safe/root/file"
  tar -czf "${tmp}/safe.tar.gz" -C "${tmp}/safe" root
  archive_layout_is_safe "${tmp}/safe.tar.gz"
  ln -s /etc/passwd "${tmp}/unsafe/root/link"
  tar -czf "${tmp}/unsafe.tar.gz" -C "${tmp}/unsafe" root
  ! archive_layout_is_safe "${tmp}/unsafe.tar.gz"
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
run_test "plain file progress reports bytes written" test_file_progress_plain_reports_written_bytes
run_test "activity progress emits a non-TTY heartbeat" test_activity_progress_emits_heartbeat
run_test "activity progress preserves errexit and command stdin" test_activity_progress_preserves_shell_state_and_stdin
run_test "snapshot cleanup preserves records when Docker is unavailable" test_snapshot_cleanup_keeps_failed_records
run_test "final result summaries expose one unambiguous status" test_final_result_summaries_are_unambiguous
run_test "generated restore scripts parse as Bash" test_generated_scripts_are_valid_bash
run_test "bundle checksum detects tampering" test_checksums_detect_tampering
run_test "top-level archive rejects symlinks" test_archive_layout_rejects_symlinks
run_test "Compose env_file parser handles scalar/list/long syntax" test_compose_env_file_parser
run_test "encrypted and legacy URL fragments are parsed safely" test_external_bundle_digest
run_test "encrypted bundle round-trips without exposing plaintext" test_encrypted_bundle_round_trip
run_test "encrypted bundle rejects wrong keys and tampering" test_encrypted_bundle_rejects_tampering
run_test "bind mount overlap detection respects path boundaries" test_mount_path_overlap_detection
run_test "manifest rejects executable paths outside runs" test_manifest_rejects_unsafe_run_paths
run_test "manifest rejects control characters in bind paths" test_manifest_rejects_control_characters_in_bind_paths
run_test "manifest validates Compose working directories" test_manifest_validates_compose_working_directories

printf '\nTests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
