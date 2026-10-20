# 在 Uptime Kuma 的数据库里写一条设置。
wait_http http://localhost:3001/ '200|302'
c="$(service_container "$APP_PROJECT" uptime-kuma)"
docker exec -w /app "$c" node -e '
const sqlite3 = require("@louislam/sqlite3");
const db = new sqlite3.Database("/app/data/kuma.db");
db.run("INSERT INTO setting (key, value, type) VALUES (?, ?, ?)",
  ["dmMarker", JSON.stringify("kuma-migrated"), "general"],
  (err) => { if (err) { console.error(err); process.exit(1); } db.close(); });
'
