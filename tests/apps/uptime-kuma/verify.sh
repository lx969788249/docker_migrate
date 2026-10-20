wait_http http://localhost:3001/ '200|302'
echo "  ✓ 网页可以打开"
c="$(service_container "$APP_PROJECT" uptime-kuma)"
value="$(docker exec -w /app "$c" node -e '
const sqlite3 = require("@louislam/sqlite3");
const db = new sqlite3.Database("/app/data/kuma.db");
db.get("SELECT value FROM setting WHERE key = ?", ["dmMarker"],
  (err, row) => { if (err) { console.error(err); process.exit(1); } console.log(row ? row.value : ""); db.close(); });
')"
expect_contains "数据库里的设置" "$value" "kuma-migrated"
