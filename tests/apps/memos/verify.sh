wait_http http://localhost:5230/healthz
jar="$(mktemp)"
curl -fsS -o /dev/null -c "$jar" -X POST \
  'http://localhost:5230/api/v1/auth/signin?username=dmadmin&password=Dm-Test-Pass-123'
expect_contains "登录后看到原来的笔记" "$(curl -fsS -b "$jar" http://localhost:5230/api/v1/memos)" "memo-migrated"
