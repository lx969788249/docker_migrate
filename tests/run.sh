#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_MIGRATE_LIB_ONLY=1
# shellcheck source=../docker_migrate_perfect.sh
source "${ROOT_DIR}/docker_migrate_perfect.sh"

PASS_COUNT=0
FAIL_COUNT=0

run_test() {
  local name="$1"
  shift
  if ("$@"); then
    printf 'ok - %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

test_progress_propagates_failure() {
  local tmp rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  set +e
  progress_docker_save "${tmp}/images.tar" bash -c 'printf partial; exit 7' >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 7 ]]
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
