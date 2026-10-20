wait_http http://localhost:8081/
expect_contains "首页显示数据库里的站点标题" "$(curl -fsS http://localhost:8081/)" "DM Migrated Blog"
expect_contains "上传的文件" "$(curl -fsS http://localhost:8081/wp-content/uploads/dm/file.txt)" "wp-upload-migrated"
