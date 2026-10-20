# 通过初始化页面完成安装：站点标题存在数据库里，首页会显示它。
wait_http http://localhost:8090/actuator/health/readiness
jar="$(mktemp)"
page="$(curl -fsS -c "$jar" -b "$jar" http://localhost:8090/system/setup)"
csrf="$(grep -oE 'name="_csrf"[^>]*value="[^"]+"' <<<"$page" | sed -E 's/.*value="([^"]+)".*/\1/' | head -n1 || true)"
[[ -n "$csrf" ]] || csrf="$(awk '$6 == "XSRF-TOKEN" {print $7}' "$jar" | tail -n1)"
code="$(curl -sS -o /tmp/halo-setup.html -w '%{http_code}' -c "$jar" -b "$jar" \
  -H "X-XSRF-TOKEN: ${csrf}" \
  --data-urlencode "_csrf=${csrf}" \
  --data-urlencode 'siteTitle=Halo Migrated Site' \
  --data-urlencode 'username=dmadmin' \
  --data-urlencode 'password=DmTestPass123' \
  --data-urlencode 'confirmPassword=DmTestPass123' \
  --data-urlencode 'email=dm@example.com' \
  --data-urlencode 'language=zh-CN' \
  --data-urlencode 'externalUrl=http://localhost:8090/' \
  http://localhost:8090/system/setup)"
[[ "$code" =~ ^(200|302|303)$ ]] || {
  echo "初始化失败：HTTP ${code}" >&2
  head -c 2000 /tmp/halo-setup.html >&2
  exit 1
}
for _ in $(seq 1 60); do
  curl -fsS http://localhost:8090/ 2>/dev/null | grep -q 'Halo Migrated Site' && break
  sleep 3
done
expect_contains "初始化完成" "$(curl -fsS http://localhost:8090/)" "Halo Migrated Site"
