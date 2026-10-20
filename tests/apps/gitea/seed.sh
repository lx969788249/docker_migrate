# 建管理员和一个带 README 的仓库：账号在数据库里，仓库文件在卷里。
wait_http http://localhost:3000/api/healthz
c="$(service_container "$APP_PROJECT" server)"
docker exec -u git "$c" gitea admin user create --username dmadmin \
  --password Dm-Test-Pass-123 --email dm@example.com --admin --must-change-password=false >/dev/null
curl -fsS -o /dev/null -u dmadmin:Dm-Test-Pass-123 -H 'Content-Type: application/json' \
  -d '{"name":"dm-repo","auto_init":true,"readme":"Default","description":"gitea-migrated"}' \
  http://localhost:3000/api/v1/user/repos
