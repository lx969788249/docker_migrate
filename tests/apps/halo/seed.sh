# 建一个标签（存在数据库里）。
wait_http http://localhost:8090/actuator/health/readiness
api=http://localhost:8090/apis/content.halo.run/v1alpha1/tags
retry 120 curl -fsS -o /dev/null -u dmadmin:Dm-Test-Pass-123 "$api"
curl -fsS -o /dev/null -u dmadmin:Dm-Test-Pass-123 -H 'Content-Type: application/json' -d '{
  "apiVersion": "content.halo.run/v1alpha1", "kind": "Tag",
  "metadata": {"name": "dm-tag"},
  "spec": {"displayName": "halo-migrated", "slug": "halo-migrated"}
}' "$api"
