# 迁移包摘要、加密与解密。

bundle_download_url() {
  printf '%s\n' "${1%%#*}"
}

bundle_fragment_value() {
  local url="$1" key="$2" fragment pair
  local -a fragment_parts=()
  [[ "$url" == *#* ]] || {
    printf '\n'
    return 0
  }
  fragment="${url#*#}"
  IFS='&' read -r -a fragment_parts <<<"$fragment"
  for pair in "${fragment_parts[@]}"; do
    if [[ "${pair%%=*}" == "$key" && "$pair" == *=* ]]; then
      printf '%s\n' "${pair#*=}"
      return 0
    fi
  done
  printf '\n'
}

bundle_expected_sha256() {
  bundle_fragment_value "$1" sha256
}

bundle_encryption_scheme() {
  bundle_fragment_value "$1" enc
}

bundle_encryption_secret() {
  bundle_fragment_value "$1" secret
}

bundle_encryption_iv() {
  bundle_fragment_value "$1" iv
}

bundle_encryption_mac() {
  bundle_fragment_value "$1" mac
}

valid_sha256() {
  [[ "$1" =~ ^[[:xdigit:]]{64}$ ]]
}

valid_hex_length() {
  local value="$1" expected_length="$2"
  [[ "$expected_length" =~ ^[0-9]+$ ]] || return 2
  ((${#value} == expected_length)) && [[ "$value" =~ ^[[:xdigit:]]+$ ]]
}

bundle_secret_encryption_key() {
  local secret="$1"
  valid_hex_length "$secret" 128 || return 1
  printf '%s\n' "${secret:0:64}"
}

bundle_secret_mac_key() {
  local secret="$1"
  valid_hex_length "$secret" 128 || return 1
  printf '%s\n' "${secret:64:64}"
}

bundle_hmac_sha256_file() {
  local file="$1" mac_key="$2" iv="$3" digest
  [[ -f "$file" ]] || return 1
  valid_hex_length "$mac_key" 64 || return 2
  valid_hex_length "$iv" 32 || return 2
  command -v openssl >/dev/null 2>&1 || return 127
  # openssl enc 不提供 AEAD；使用独立密钥认证“版本 + IV + 密文”，并在解密前验证。
  digest="$({
    printf 'docker-migrate:%s\0%s\0' "$BUNDLE_ENCRYPTION_SCHEME" "${iv,,}"
    cat -- "$file"
  } | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${mac_key}" 2>/dev/null | awk '{print $NF}')" || return 1
  valid_sha256 "$digest" || return 1
  printf '%s\n' "${digest,,}"
}

bundle_file_digests() {
  local file="$1" mac_key="$2" iv="$3"
  local result sha mac extra
  [[ -f "$file" ]] || return 1
  valid_hex_length "$mac_key" 64 || return 2
  valid_hex_length "$iv" 32 || return 2

  # Python 可在一次顺序读取中同时计算来源 SHA 与 encrypt-then-MAC 摘要。
  # 它是可选加速路径；极简系统仍回退到现有 OpenSSL/SHA 工具，不影响可用性。
  if command -v python3 >/dev/null 2>&1; then
    result="$(python3 -c '
import hashlib
import hmac
import sys

path, key_hex, iv, scheme = sys.argv[1:]
sha = hashlib.sha256()
mac = hmac.new(bytes.fromhex(key_hex), digestmod=hashlib.sha256)
mac.update(b"docker-migrate:" + scheme.encode() + b"\0" + iv.lower().encode() + b"\0")
with open(path, "rb", buffering=0) as source:
    while True:
        chunk = source.read(1024 * 1024)
        if not chunk:
            break
        sha.update(chunk)
        mac.update(chunk)
print(sha.hexdigest() + "\t" + mac.hexdigest())
' "$file" "$mac_key" "$iv" "$BUNDLE_ENCRYPTION_SCHEME")" || return 1
  else
    sha="$(sha256_file "$file")" || return 1
    mac="$(bundle_hmac_sha256_file "$file" "$mac_key" "$iv")" || return 1
    result="${sha}"$'\t'"${mac}"
  fi

  IFS=$'\t' read -r sha mac extra <<<"$result"
  [[ -z "$extra" ]] || return 1
  valid_sha256 "$sha" && valid_sha256 "$mac" || return 1
  printf '%s\t%s\n' "${sha,,}" "${mac,,}"
}

verify_bundle_digests() {
  local file="$1" mac_key="$2" iv="$3" expected_sha="$4" expected_mac="$5"
  local actual_sha actual_mac extra
  valid_sha256 "$expected_sha" && valid_sha256 "$expected_mac" || return 2
  IFS=$'\t' read -r actual_sha actual_mac extra < <(
    bundle_file_digests "$file" "$mac_key" "$iv"
  ) || return 1
  [[ -z "$extra" ]] || return 1
  [[ "${actual_sha,,}" == "${expected_sha,,}" &&
    "${actual_mac,,}" == "${expected_mac,,}" ]]
}

gzip_compress_stream() {
  local level="${DOCKER_MIGRATE_GZIP_LEVEL:-6}"
  [[ "$level" =~ ^[1-9]$ ]] || level=6
  if command -v pigz >/dev/null 2>&1; then
    pigz "-${level}" -c
  else
    gzip "-${level}" -c
  fi
}

bundle_pack_encrypt_directory() {
  local bundle_root="$1" member="$2" output="$3"
  local encryption_key="$4" mac_key="$5" iv="$6"
  local result sha mac extra rc=0
  [[ -d "${bundle_root}/${member}" ]] || return 1
  valid_hex_length "$encryption_key" 64 || return 2
  valid_hex_length "$mac_key" 64 || return 2
  valid_hex_length "$iv" 32 || return 2
  command -v openssl >/dev/null 2>&1 || return 127
  rm -f -- "$output"

  if command -v python3 >/dev/null 2>&1; then
    # 压缩、加密、落盘和两个摘要在同一条流水线完成：不再生成明文 tar.gz，
    # 密文也无需为了 HMAC/SHA 再从磁盘完整读取一次。
    if result="$(
      tar -C "$bundle_root" -cf - "$member" |
        gzip_compress_stream |
        openssl enc -aes-256-ctr -nosalt -K "$encryption_key" -iv "$iv" |
        python3 -c '
import hashlib
import hmac
import sys

output, key_hex, iv, scheme = sys.argv[1:]
sha = hashlib.sha256()
mac = hmac.new(bytes.fromhex(key_hex), digestmod=hashlib.sha256)
mac.update(b"docker-migrate:" + scheme.encode() + b"\0" + iv.lower().encode() + b"\0")
with open(output, "wb", buffering=0) as target:
    while True:
        chunk = sys.stdin.buffer.read(1024 * 1024)
        if not chunk:
            break
        target.write(chunk)
        sha.update(chunk)
        mac.update(chunk)
print(sha.hexdigest() + "\t" + mac.hexdigest())
' "$output" "$mac_key" "$iv" "$BUNDLE_ENCRYPTION_SCHEME"
    )"; then
      :
    else
      rc=$?
      rm -f -- "$output"
      return "$rc"
    fi
  else
    # 无 Python 时仍保留流式压缩加密和格式兼容，只在生成后回退为摘要扫描。
    if tar -C "$bundle_root" -cf - "$member" |
      gzip_compress_stream |
      openssl enc -aes-256-ctr -nosalt -K "$encryption_key" -iv "$iv" \
        -out "$output"; then
      result="$(bundle_file_digests "$output" "$mac_key" "$iv")" || {
        rc=$?
        rm -f -- "$output"
        return "$rc"
      }
    else
      rc=$?
      rm -f -- "$output"
      return "$rc"
    fi
  fi

  IFS=$'\t' read -r sha mac extra <<<"$result"
  if [[ -n "$extra" ]] || ! valid_sha256 "$sha" || ! valid_sha256 "$mac"; then
    rm -f -- "$output"
    return 1
  fi
  printf '%s\t%s\n' "${sha,,}" "${mac,,}"
}

bundle_decrypt_file() {
  local input="$1" output="$2" encryption_key="$3" iv="$4"
  local partial="${output}.partial.$$"
  [[ -f "$input" && "$input" != "$output" ]] || return 1
  valid_hex_length "$encryption_key" 64 || return 2
  valid_hex_length "$iv" 32 || return 2
  command -v openssl >/dev/null 2>&1 || return 127
  rm -f "$partial"
  if openssl enc -d -aes-256-ctr -nosalt -K "$encryption_key" -iv "$iv" \
    -in "$input" -out "$partial"; then
    mv "$partial" "$output"
  else
    rm -f "$partial"
    return 1
  fi
}
