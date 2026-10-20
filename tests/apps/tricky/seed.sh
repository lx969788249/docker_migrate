printf 'tricky-bind-migrated\n' >data/bind.txt
docker exec "$(service_container dm_tricky api)" sh -c 'echo api-state-migrated >/srv/state/seed.txt'
docker exec "$(service_container dm_tricky worker)" sh -c 'echo anon-volume-migrated >/srv/anon/seed.txt'
docker exec dm_standalone sh -c 'echo standalone-migrated >/data/seed.txt'
wait_http http://localhost:8084/
