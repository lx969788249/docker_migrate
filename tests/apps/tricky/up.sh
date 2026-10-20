# 先建独立网络再启动 Compose：Compose 的网络会自动拿到下一个网段，
# 恢复时如果顺序反了，独立网络原来的网段会被 Compose 占走。
docker network create dm_standalone_net >/dev/null
docker network create --subnet 10.123.0.0/24 dm_shared >/dev/null
docker run -d --name dm_standalone --restart unless-stopped \
  --network dm_standalone_net -v dm_standalone_data:/data \
  alpine:3.20 sleep infinity >/dev/null
docker network connect --ip 10.123.0.50 dm_shared dm_standalone
docker compose -p dm_tricky -f compose.yml -f compose.override.yml -f compose.extra.yml \
  up -d --build --wait --wait-timeout 300
