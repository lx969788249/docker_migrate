wait_http http://localhost:5230/healthz
token="$(curl -fsS -D - -o /dev/null -X POST \
  'http://localhost:5230/api/v1/auth/signin?username=dmadmin&password=Dm-Test-Pass-123' |
  grep -oiE 'memos\.access-token=[^;]+' | head -n1 | cut -d= -f2-)"
[[ -n "$token" ]] || {
  echo "登录后没有拿到登录凭证" >&2
  exit 1
}
expect_contains "登录后看到原来的笔记" \
  "$(curl -fsS -H "Cookie: memos.access-token=${token}" -H "Authorization: Bearer ${token}" \
    http://localhost:5230/api/v1/memos)" "memo-migrated"
