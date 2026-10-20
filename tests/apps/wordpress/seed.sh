# 完成安装（站点标题存在数据库里），再放一个上传文件（存在网站目录的卷里）。
wait_http http://localhost:8081/wp-admin/install.php
curl -fsS -o /dev/null --max-time 60 \
  --data-urlencode 'weblog_title=DM Migrated Blog' \
  --data-urlencode 'user_name=dmadmin' \
  --data-urlencode 'admin_password=Dm-Test-Pass-123' \
  --data-urlencode 'admin_password2=Dm-Test-Pass-123' \
  --data-urlencode 'pw_weak=1' \
  --data-urlencode 'admin_email=dm@example.com' \
  --data-urlencode 'blog_public=0' \
  'http://localhost:8081/wp-admin/install.php?step=2'
c="$(service_container "$APP_PROJECT" wordpress)"
docker exec "$c" sh -c 'mkdir -p /var/www/html/wp-content/uploads/dm && echo wp-upload-migrated >/var/www/html/wp-content/uploads/dm/file.txt'
expect_contains "安装完成" "$(curl -fsS http://localhost:8081/)" "DM Migrated Blog"
