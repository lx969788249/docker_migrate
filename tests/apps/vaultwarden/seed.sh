# 用管理后台邀请一个用户，用户记录存在 SQLite 数据库里。
wait_http http://localhost:8082/alive
jar="$(mktemp)"
curl -fsS -o /dev/null -c "$jar" --data-urlencode 'token=dm-admin-token-for-tests' http://localhost:8082/admin
curl -fsS -o /dev/null -b "$jar" -H 'Content-Type: application/json' \
  -d '{"email":"dm-migrated@example.com"}' http://localhost:8082/admin/invite
