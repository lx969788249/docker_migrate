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
  local tmp digest url
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  printf 'trusted bundle\n' >"${tmp}/bundle.tar.gz"
  digest="$(sha256_file "${tmp}/bundle.tar.gz")"
  url="http://192.0.2.1/token/bundle.tar.gz#sha256=${digest}"

  [[ "$(bundle_download_url "$url")" == "http://192.0.2.1/token/bundle.tar.gz" ]]
  [[ "$(bundle_expected_sha256 "$url")" == "$digest" ]]
  valid_sha256 "$digest"
  verify_archive_sha256 "${tmp}/bundle.tar.gz" "$digest"

  printf 'tampered\n' >>"${tmp}/bundle.tar.gz"
  ! verify_archive_sha256 "${tmp}/bundle.tar.gz" "$digest"
  ! valid_sha256 not-a-digest
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
  mkdir -p "${tmp}/bundle/runs"
  printf '#!/usr/bin/env bash\n' >"${tmp}/bundle/runs/safe.sh"
  jq -n '{images:[],networks:[],projects:[],volumes:[],binds:[],runs:["runs/safe.sh"]}' \
    >"${tmp}/bundle/manifest.json"
  bundle_manifest_is_safe "${tmp}/bundle"

  jq -n '{images:[],networks:[],projects:[],volumes:[],binds:[],runs:["../evil.sh"]}' \
    >"${tmp}/bundle/manifest.json"
  ! bundle_manifest_is_safe "${tmp}/bundle"
}

run_test "docker image save failure status is preserved" test_progress_propagates_failure
run_test "generated restore scripts parse as Bash" test_generated_scripts_are_valid_bash
run_test "bundle checksum detects tampering" test_checksums_detect_tampering
run_test "top-level archive rejects symlinks" test_archive_layout_rejects_symlinks
run_test "Compose env_file parser handles scalar/list/long syntax" test_compose_env_file_parser
run_test "external bundle digest pins the downloaded archive" test_external_bundle_digest
run_test "bind mount overlap detection respects path boundaries" test_mount_path_overlap_detection
run_test "manifest rejects executable paths outside runs" test_manifest_rejects_unsafe_run_paths

printf '\nTests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
