# shellcheck shell=bash
# 在模拟服务器里输出所有容器的关键配置，用来比较迁移前后是否一致。
# 镜像名不比较：容器里有改动时会迁移成快照镜像，名字不同但内容一致。
# 匿名卷的编号是随机生成的，只比较挂载位置。
set -euo pipefail
docker ps -aq | while read -r id; do
  docker inspect "$id" | jq -c '.[0] | {
    name: (.Name | ltrimstr("/")),
    state: .State.Status,
    health: (.State.Health.Status // ""),
    restart: .HostConfig.RestartPolicy.Name,
    project: (.Config.Labels["com.docker.compose.project"] // ""),
    service: (.Config.Labels["com.docker.compose.service"] // ""),
    ports: [(.HostConfig.PortBindings // {}) | to_entries[] | .key as $c | .value[]? |
      "\(.HostIp // "")\(if (.HostIp // "") == "" then "" else ":" end)\(.HostPort)->\($c)"] | sort,
    networks: [(.NetworkSettings.Networks // {}) | keys[]] | sort,
    mounts: [.Mounts[]? | "\(.Type):\(if .Type != "volume" then .Source elif (.Name | test("^[0-9a-f]{64}$")) then "<匿名卷>" else .Name end)->\(.Destination)\(if .RW then "" else ":ro" end)"] | sort,
    env: (.Config.Env // [] | sort),
    cmd: .Config.Cmd
  }'
done | jq -s 'sort_by(.name)'
