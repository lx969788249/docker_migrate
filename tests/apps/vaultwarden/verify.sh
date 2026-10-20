wait_http http://localhost:8082/alive
jar="$(mktemp)"
curl -fsS -o /dev/null -c "$jar" --data-urlencode 'token=dm-admin-token-for-tests' http://localhost:8082/admin
expect_contains "管理后台里的用户" "$(curl -fsS -b "$jar" http://localhost:8082/admin/users)" "dm-migrated@example.com"
