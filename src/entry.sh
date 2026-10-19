if [[ "${DOCKER_MIGRATE_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

#####################################
# 模式选择：1) 备份并传输 2) 下载并恢复
#####################################
REQUESTED_MODE=""
RESTORE_URL=""
declare -a ORIGINAL_ARGS=("$@")
for ((arg_i = 0; arg_i < ${#ORIGINAL_ARGS[@]}; arg_i++)); do
  case "${ORIGINAL_ARGS[$arg_i]}" in
    -h | --help)
      show_help
      exit 0
      ;;
    --backup) REQUESTED_MODE=1 ;;
    --diagnose) REQUESTED_MODE=diagnose ;;
    --verbose | -v) DOCKER_MIGRATE_VERBOSE=1 ;;
    --check=*)
      REQUESTED_MODE=2
      export RESTORE_CHECK_ONLY=1
      RESTORE_URL="${ORIGINAL_ARGS[$arg_i]#*=}"
      ;;
    --restore=*)
      REQUESTED_MODE=2
      RESTORE_URL="${ORIGINAL_ARGS[$arg_i]#*=}"
      ;;
    --restore)
      REQUESTED_MODE=2
      if ((arg_i + 1 < ${#ORIGINAL_ARGS[@]})) &&
        [[ "${ORIGINAL_ARGS[$((arg_i + 1))]}" != --* ]]; then
        RESTORE_URL="${ORIGINAL_ARGS[$((arg_i + 1))]}"
      fi
      ;;
  esac
done

export DOCKER_MIGRATE_VERBOSE="${DOCKER_MIGRATE_VERBOSE:-0}"

if [[ -n "$REQUESTED_MODE" ]]; then
  MODE_PICK="$REQUESTED_MODE"
elif [[ -t 0 ]]; then
  show_banner
  echo "请选择功能："
  echo " 1) 备份容器并传输"
  echo " 2) 下载备份并恢复"
  read -rp "请输入序号 [回车=1]：" MODE_PICK || true
  MODE_PICK="${MODE_PICK:-1}"
else
  MODE_PICK=1
fi

case "$MODE_PICK" in
  1) : ;;
  diagnose)
    run_diagnose
    exit 0
    ;;
  2)
    restore_main "$RESTORE_URL"
    exit 0
    ;;
  *)
    RED "[ERR] 无效选择：${MODE_PICK}"
    exit 1
    ;;
esac
