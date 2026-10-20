wait_http http://localhost:8083/status.php
expect_contains "安装状态" "$(curl -fsS http://localhost:8083/status.php)" '"installed":true'
expect_contains "上传的文件" \
  "$(curl -fsS -u dmadmin:Dm-Test-Pass-123 http://localhost:8083/remote.php/dav/files/dmadmin/dm.txt)" \
  "nextcloud-file-migrated"
