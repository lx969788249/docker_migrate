wait_http http://localhost:8090/actuator/health/readiness
expect_contains "数据库里的标签" \
  "$(curl -fsS -u dmadmin:Dm-Test-Pass-123 http://localhost:8090/apis/content.halo.run/v1alpha1/tags/dm-tag)" \
  "halo-migrated"
