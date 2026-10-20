# 等自动安装完成，再通过 WebDAV 上传一个文件。
for _ in $(seq 1 200); do
  curl -fsS --max-time 10 http://localhost:8083/status.php 2>/dev/null | grep -q '"installed":true' && break
  sleep 3
done
expect_contains "自动安装完成" "$(curl -fsS http://localhost:8083/status.php)" '"installed":true'
printf 'nextcloud-file-migrated\n' >/tmp/dm.txt
curl -fsS -o /dev/null -u dmadmin:Dm-Test-Pass-123 -T /tmp/dm.txt \
  http://localhost:8083/remote.php/dav/files/dmadmin/dm.txt
