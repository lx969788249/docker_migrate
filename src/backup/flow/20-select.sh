#####################################
# 容器选择（支持 compose 分组）
#####################################
stage_begin 2 7 "选择容器"
if [[ -n "$INCLUDE_LIST" ]]; then
  declare -A INCLUDE_ID_BY_NAME=()
  include_container_count=0
  while IFS=$'\t' read -r id n; do
    [[ -n "$id" && -n "$n" ]] || continue
    INCLUDE_ID_BY_NAME["$n"]="$id"
    include_container_count=$((include_container_count + 1))
  done < <(docker ps -a --format '{{.ID}}\t{{.Names}}')
  ((include_container_count > 0)) || {
    error_user "本机没有任何容器（运行中或已停止）"
    exit 1
  }
  IFS=',' read -r -a NAMES <<<"$INCLUDE_LIST"
  for n in "${NAMES[@]}"; do
    n="$(echo "$n" | xargs)"
    [[ -z "$n" ]] && continue
    # 一次性建立精确 name -> ID 索引，避免每个 --include 名称都重新扫描 Docker。
    id="${INCLUDE_ID_BY_NAME[$n]:-}"
    if [[ -n "$id" ]]; then
      IDS+=("$id")
    else
      warn_user "未找到容器：$n"
    fi
  done
  ((${#IDS[@]})) || {
    error_user "--include 没有匹配到任何容器" "执行 docker ps -a 确认容器名称"
    exit 1
  }
else
  mapfile -t PS_LINES < <(docker ps -a --format '{{.ID}} {{.Names}}')
  ((${#PS_LINES[@]})) || {
    error_user "本机没有任何容器（运行中或已停止）"
    exit 1
  }

  declare -a STANDALONE_IDS=()
  declare -a STANDALONE_NAMES=()
  declare -A NAME_OF_ID=()
  declare -A GROUP_IDS=()
  declare -A GROUP_LABELS=()
  declare -A GROUP_SEEN=()
  declare -a GROUP_KEYS=()
  declare -a PANEL_CONTAINERS=()
  declare -A PANEL_WARN_OF=()

  scan_total=${#PS_LINES[@]}
  scan_index=0
  detail "识别容器与 Compose 分组（共 ${scan_total} 个）"
  for line in "${PS_LINES[@]}"; do
    scan_index=$((scan_index + 1))
    id="${line%% *}"
    cname="${line#* }"
    [[ -z "$cname" || "$cname" == "$id" ]] && cname="$id"
    progress_count "识别容器" "$scan_index" "$scan_total" "$cname"
    NAME_OF_ID["$id"]="$cname"

    j="$(docker inspect "$id")"
    proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
    wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")

    # 面板管理容器检测：btpanel/baota/1Panel 自身 — 标记警告
    panel_warn=""
    img_name="$(jq -r '.[0].Config.Image // ""' <<<"$j")"
    case "$img_name" in
      *btpanel* | *baota* | *1panel* | *1Panel*)
        PANEL_CONTAINERS+=("$id")
        panel_warn=" [⚡ 面板管理容器，迁移可能导致管理界面异常]"
        ;;
    esac
    # 检测挂载了面板关键路径的容器
    mounts_json="$(jq -r '.[0].Mounts[]?.Source // empty' <<<"$j" 2>/dev/null || true)"
    case "$mounts_json" in
      *"/www/server/panel/"* | *"/opt/1panel/"*)
        if [[ -z "$panel_warn" ]]; then
          PANEL_CONTAINERS+=("$id")
          panel_warn=" [⚡ 挂载了面板关键路径，请确认是否为管理容器]"
        fi
        ;;
    esac
    PANEL_WARN_OF["$id"]="$panel_warn"
    # 兼容 docker-compose v1（无 working_dir label）：将 v1 的 project 容器也归入 compose 组。
    # v1 缺少 working_dir 时，使用 compose config_files 中第一个文件的父目录作为 wdir。
    if [[ -z "$wdir" && -n "$proj" ]]; then
      cfgs_raw=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$j")
      if [[ -n "$cfgs_raw" ]]; then
        mapfile -t cfgs_arr < <(compose_config_files_split "$cfgs_raw")
        for cfg in "${cfgs_arr[@]}"; do
          cfg="${cfg#./}"
          if [[ -n "$cfg" ]]; then
            d="$(dirname "$cfg")"
            if [[ "$cfg" == /* ]]; then wdir="$d"; else wdir="${PWD}/${d}"; fi
            break
          fi
        done
      fi
    fi
    if [[ -n "$proj" && -n "$wdir" ]]; then
      key="${proj}|${wdir}"
      if [[ -z "${GROUP_SEEN[$key]:-}" ]]; then
        GROUP_SEEN["$key"]=1
        GROUP_IDS["$key"]="$id"
        GROUP_LABELS["$key"]="$cname"
        GROUP_KEYS+=("$key")
      else
        GROUP_IDS["$key"]="${GROUP_IDS[$key]} $id"
        GROUP_LABELS["$key"]="${GROUP_LABELS[$key]} $cname"
      fi
    else
      STANDALONE_IDS+=("$id")
      STANDALONE_NAMES+=("$cname")
    fi
  done

  # 关键修复：只有一个容器的 compose 项目归类为“独立容器”。
  # 这样 danmu_api 这类单容器项目会走 docker run 恢复路径，从 inspect 还原 -p 端口。
  if ((${#GROUP_KEYS[@]})); then
    declare -a TRUE_GROUP_KEYS=()
    for key in "${GROUP_KEYS[@]}"; do
      cnt=0
      for cid in ${GROUP_IDS[$key]}; do cnt=$((cnt + 1)); done
      if ((cnt > 1)); then
        TRUE_GROUP_KEYS+=("$key")
      else
        for cid in ${GROUP_IDS[$key]}; do
          STANDALONE_IDS+=("$cid")
          STANDALONE_NAMES+=("${NAME_OF_ID[$cid]}")
        done
      fi
    done
    GROUP_KEYS=("${TRUE_GROUP_KEYS[@]}")
  fi

  declare -a MENU_KIND=()
  declare -a MENU_VAL=()
  idx=0
  stage_hold
  if ((${#STANDALONE_IDS[@]})); then
    BLUE "独立 docker 容器："
    for i in "${!STANDALONE_IDS[@]}"; do
      idx=$((idx + 1))
      id="${STANDALONE_IDS[$i]}"
      name="${STANDALONE_NAMES[$i]}"
      pw="${PANEL_WARN_OF[$id]:-}"
      printf " %2d) %s%s\n" "$idx" "$name" "$pw"
      MENU_KIND[$idx]="single"
      MENU_VAL[$idx]="$id"
    done
    echo ""
  fi

  if ((${#PANEL_CONTAINERS[@]})); then
    YEL " ⚡ 提示：检测到面板管理容器（btpanel/1Panel/baota），迁移可能导致面板界面异常。"
    YEL "    建议仅迁移业务容器，排除面板管理容器。"
    echo ""
  fi

  if ((${#GROUP_KEYS[@]})); then
    BLUE "docker compose 容器组："
    for key in "${GROUP_KEYS[@]}"; do
      idx=$((idx + 1))
      label_display=""
      for cname in ${GROUP_LABELS[$key]}; do label_display+="〖${cname}〗"; done
      printf " %2d) %s\n" "$idx" "$label_display"
      MENU_KIND[$idx]="compose"
      MENU_VAL[$idx]="$key"
    done
    echo ""
  fi

  if ((idx == 0)); then
    error_user "没有可迁移的容器"
    exit 1
  fi

  if [[ ! -t 0 ]]; then
    error_user "非交互模式无法选择容器" "用 --include=容器名1,容器名2 指定要迁移的容器"
    exit 1
  fi
  read -rp "请输入要迁移的序号 [回车=全部 / 逗号分隔，如 1,3]： " PICK
  if [[ -z "$PICK" ]]; then
    IDS=("${STANDALONE_IDS[@]}")
    for key in "${GROUP_KEYS[@]}"; do
      for cid in ${GROUP_IDS[$key]}; do IDS+=("$cid"); done
    done
  else
    IFS=',' read -r -a INDEX_LIST <<<"$PICK"
    declare -A SEEN_ID=()
    for t in "${INDEX_LIST[@]}"; do
      t="$(echo "$t" | xargs)"
      [[ -z "$t" ]] && continue
      if ! [[ "$t" =~ ^[0-9]+$ ]]; then
        warn_user "忽略无效的序号：$t"
        continue
      fi
      num="$t"
      if ((num < 1 || num > idx)); then
        warn_user "忽略超出范围的序号：$t"
        continue
      fi
      kind="${MENU_KIND[$num]}"
      val="${MENU_VAL[$num]}"
      if [[ "$kind" == "single" ]]; then
        cid="$val"
        if [[ -z "${SEEN_ID[$cid]:-}" ]]; then
          SEEN_ID["$cid"]=1
          IDS+=("$cid")
        fi
      elif [[ "$kind" == "compose" ]]; then
        for cid in ${GROUP_IDS[$val]}; do
          if [[ -z "${SEEN_ID[$cid]:-}" ]]; then
            SEEN_ID["$cid"]=1
            IDS+=("$cid")
          fi
        done
      fi
    done
    ((${#IDS[@]})) || {
      error_user "没有选择任何容器"
      exit 1
    }
  fi
fi

#####################################
# 自动纳入被依附的容器
#####################################
# --network/--pid/--ipc container:X 的容器离开 X 无法启动，自动把 X 一并迁移。
dependency_added=1
while ((dependency_added == 1)); do
  dependency_added=0
  for id in "${IDS[@]}"; do
    while IFS= read -r dep_mode; do
      [[ "$dep_mode" == container:* ]] || continue
      dep_ref="${dep_mode#container:}"
      dep_id="$(docker inspect -f '{{.Id}}' "$dep_ref" 2>/dev/null || true)"
      if [[ -z "$dep_id" ]]; then
        BACKUP_FAILURES+=("容器 ${id} 依附的容器 ${dep_ref:0:12} 不存在")
        continue
      fi
      dep_selected=0
      for existing in "${IDS[@]}"; do
        [[ "$dep_id" != "$existing"* ]] || dep_selected=1
      done
      ((dep_selected == 0)) || continue
      dep_name="$(docker inspect -f '{{.Name}}' "$dep_id" 2>/dev/null | sed 's#^/##')"
      warn_user "自动加入被依附的容器 ${dep_name:-${dep_id:0:12}}（选中的容器要借用它的网络，必须一起迁移）"
      IDS+=("${dep_id:0:12}")
      dependency_added=1
    done < <(docker inspect -f '{{.HostConfig.NetworkMode}}
{{.HostConfig.PidMode}}
{{.HostConfig.IpcMode}}' "$id" 2>/dev/null || true)
    ((dependency_added == 0)) || break
  done
done

# shellcheck disable=SC2154
stage_end "${#IDS[@]} 个容器"
