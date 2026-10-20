# 注册第一个用户并写一条笔记。登录凭证放在带 Secure 标记的 Cookie 里，
# curl 不会在 http 下自动带上，所以从响应头里取出来手动发送。
wait_http http://localhost:5230/healthz
token="$(curl -fsS -D - -o /dev/null -X POST \
  'http://localhost:5230/api/v1/auth/signup?username=dmadmin&password=Dm-Test-Pass-123' |
  grep -oiE 'memos\.access-token=[^;]+' | head -n1 | cut -d= -f2-)"
[[ -n "$token" ]] || {
  echo "注册后没有拿到登录凭证" >&2
  exit 1
}
curl -fsS -o /dev/null -H "Cookie: memos.access-token=${token}" -H "Authorization: Bearer ${token}" \
  -H 'Content-Type: application/json' \
  -d '{"content":"memo-migrated","visibility":"PRIVATE"}' http://localhost:5230/api/v1/memos
