wait_http http://localhost:3000/api/healthz
expect_contains "仓库信息（数据库）" \
  "$(curl -fsS -u dmadmin:Dm-Test-Pass-123 http://localhost:3000/api/v1/repos/dmadmin/dm-repo)" "gitea-migrated"
expect_contains "仓库文件（卷）" \
  "$(curl -fsS -u dmadmin:Dm-Test-Pass-123 http://localhost:3000/dmadmin/dm-repo/raw/branch/main/README.md)" "dm-repo"
