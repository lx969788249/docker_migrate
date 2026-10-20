wait_http http://localhost:8090/actuator/health/readiness
for _ in $(seq 1 60); do
  curl -fsS http://localhost:8090/ 2>/dev/null | grep -q 'Halo Migrated Site' && break
  sleep 3
done
expect_contains "首页显示数据库里的站点标题" "$(curl -fsS http://localhost:8090/)" "Halo Migrated Site"
