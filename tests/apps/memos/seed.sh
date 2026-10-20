# 注册第一个用户并写一条笔记。
wait_http http://localhost:5230/healthz
jar="$(mktemp)"
curl -fsS -o /dev/null -c "$jar" -X POST \
  'http://localhost:5230/api/v1/auth/signup?username=dmadmin&password=Dm-Test-Pass-123'
curl -fsS -o /dev/null -b "$jar" -H 'Content-Type: application/json' \
  -d '{"content":"memo-migrated","visibility":"PRIVATE"}' http://localhost:5230/api/v1/memos
