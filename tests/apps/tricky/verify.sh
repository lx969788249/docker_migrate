wait_http http://localhost:8084/
expect_contains "现场构建的镜像" "$(curl -fsS http://localhost:8084/)" "tricky-built-image"
expect_contains "相对路径挂载的数据" "$(curl -fsS http://localhost:8084/data/bind.txt)" "tricky-bind-migrated"
web="$(service_container dm_tricky web)"
expect_contains "override 文件里的环境变量" "$(docker exec "$web" env)" "APP_LAYER=override"
expect_contains "env_file 里的环境变量" "$(docker exec "$web" env)" "APP_MESSAGE=from-env-file"
expect_contains "第三个配置文件里的服务" "$(docker ps --format '{{.Names}}')" "dm_tricky-worker-1"
expect_contains "命名卷里的数据" "$(docker exec "$(service_container dm_tricky worker)" cat /srv/state/seed.txt)" "api-state-migrated"
expect_contains "匿名卷里的数据" "$(docker exec "$(service_container dm_tricky worker)" cat /srv/anon/seed.txt)" "anon-volume-migrated"
expect_contains "独立容器的数据" "$(docker exec dm_standalone cat /data/seed.txt)" "standalone-migrated"
expect_contains "外部网络的网段" "$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' dm_shared)" "10.123.0.0/24"
expect_contains "独立容器的固定 IP" \
  "$(docker inspect -f '{{(index .NetworkSettings.Networks "dm_shared").IPAMConfig.IPv4Address}}' dm_standalone)" "10.123.0.50"
if docker ps -a --format '{{.Names}}' | grep -q debug; then
  echo "profiles 里的 debug 服务不应该被创建" >&2
  exit 1
fi
echo "  ✓ profiles 里的 debug 服务没有被创建"
