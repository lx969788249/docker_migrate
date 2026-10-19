#####################################
# 生成单容器恢复脚本
#####################################
write_run_script() {
  local name="$1"
  local out="$2"
  cat >"$out" <<'RUN_SH'
# @include templates/run.sh
RUN_SH
  # 安全转义容器名中的 \ / &，防止 sed 替换出错
  local escaped_name="$name"
  escaped_name="${escaped_name//\\/\\\\}" # \ → \\
  escaped_name="${escaped_name//\//\\/}"  # / → \/
  escaped_name="${escaped_name//&/\\&}"   # & → \&
  local rendered="${out}.rendered"
  sed "s/__NAME__/${escaped_name}/g" "$out" >"$rendered"
  mv "$rendered" "$out"
  chmod +x "$out"
}

#####################################
# 生成恢复主脚本
#####################################
write_bundle_restore_script() {
  local out="$1"
  cat >"$out" <<'REST_SH'
# @include templates/restore.sh
REST_SH
  chmod +x "$out"
}
