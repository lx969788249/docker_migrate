# 真实服务器迁移测试清单

CI 在单台 Ubuntu runner 上用同一个 Docker 模拟“两台服务器”，覆盖不到真实网络、防火墙、
不同发行版和不同 Docker 版本。发版前建议用两台**可以随时重装的测试 VPS**按本清单走一遍。

> 不要在生产服务器上做这项测试。旧服务器（A）和新服务器（B）最好是不同发行版，
> 例如 A = Debian 12，B = Rocky 9 或 Ubuntu 24.04；有条件的话 B 选一台纯 IPv6 的机器。

## 1. 在 A 上准备测试容器

```bash
docker network create --subnet 172.28.0.0/24 testnet
docker volume create testvol
mkdir -p /srv/test/cfg /srv/test/data && echo cfg >/srv/test/cfg/app.conf && echo data >/srv/test/data/a.txt
ln -s /srv/test/data /srv/test-link

# 常见参数组合：只读挂载、/etc/localtime、端口、资源限制、自定义网络与静态 IP
docker run -d --name web --restart unless-stopped -p 8081:80 \
  -v /etc/localtime:/etc/localtime:ro -v /srv/test/cfg:/etc/nginx/conf.d:ro \
  --memory 128m --cpus 0.5 --network testnet --ip 172.28.0.10 nginx:alpine

# 数据库：数据卷 + 健康检查
docker run -d --name db -e MYSQL_ROOT_PASSWORD=test -v testvol:/var/lib/mysql \
  --health-cmd 'mysqladmin ping -ptest' --health-interval 5s mysql:8

# 共享网络命名空间（sidecar）+ 软链接 bind
docker run -d --name side --network container:web -v /srv/test-link:/data alpine sleep 1d

# 容器内未挂载的改动（应通过可写层快照迁移）
docker exec web sh -c 'echo inside >/usr/share/nginx/html/inside.txt'

# 一个 Compose 多服务项目
mkdir -p /srv/compose-demo && cd /srv/compose-demo && cat >compose.yml <<'EOF'
services:
  app:
    image: nginx:alpine
    ports: ["8082:80"]
    volumes: ["./html:/usr/share/nginx/html:ro", "/etc/localtime:/etc/localtime:ro"]
  cache:
    image: redis:7-alpine
    volumes: ["redisdata:/data"]
volumes:
  redisdata:
EOF
mkdir -p html && echo compose >html/index.html && docker compose up -d
docker exec db mysql -ptest -e 'create database migrated; create table migrated.t(v int); insert into migrated.t values (42);'
docker pause side 2>/dev/null || true   # 验证暂停状态也能保留
```

记录迁移前的状态，供之后对比：

```bash
for c in web db side; do docker inspect "$c" >/root/before-$c.json; done
```

## 2. 备份（在 A 上）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lx969788249/docker_migrate/master/docker_migrate_perfect.sh)
```

选 `1`，回车选择全部，停机选 `Y`，复制链接。核对输出：

- [ ] `/etc/localtime` 显示 `[SKIP] 宿主机系统路径…`
- [ ] `/srv/test-link` 显示 `bind 源是软链接，备份真实目录`
- [ ] `web` 显示 `[SNAPSHOT]…可写层有改动`，其余显示 `沿用原镜像`
- [ ] 链接下方提示了需要放行的端口
- [ ] 备份过程中 `docker ps` 里业务容器停止，链接出现后已恢复运行

## 3. 恢复（在 B 上）

先确认 B 的防火墙和安全组已放行 A 的下载端口，然后运行同一条命令，选 `2`，粘贴链接。

- [ ] 结果显示 `✅ 恢复成功`，容器数量正确（暂停 1 个）
- [ ] `curl localhost:8081/inside.txt` 返回 `inside`（可写层改动已迁移）
- [ ] `curl localhost:8082` 返回 `compose`
- [ ] `docker exec db mysql -ptest -e 'select * from migrated.t'` 返回 42
- [ ] `docker inspect -f '{{.HostConfig.NetworkMode}}' side` 指向新的 `web` 容器 ID
- [ ] `ls -l /srv/test-link` 是指向 `/srv/test/data` 的软链接
- [ ] B 的 `/etc/localtime` 没有被改成 A 的时区：`ls -l /etc/localtime`
- [ ] `docker inspect web` 的端口、内存、CPU、网络 IP 与 A 上的 `/root/before-web.json` 一致
- [ ] `nginx:alpine`、`mysql:8` 仍以原镜像名运行，可以正常 `docker pull` 升级（`web` 除外，它使用快照镜像）

## 4. 回到 A

- [ ] 按回车后显示 `源端任务已安全结束`，`docker ps` 中所有容器状态与迁移前一致
- [ ] 工作目录下没有遗留 `bundle/` 临时文件

## 5. 失败场景（可选）

- 在 B 上先手动占用 8081 端口（`python3 -m http.server 8081`）再恢复：应显示端口冲突并**安全回滚**，B 上原有服务不受影响。
- 恢复进行到一半时按 `Ctrl+C`：应显示 `已安全回滚`。
- 用错误的链接（改动 `secret=` 中的一个字符）：应在解压前拒绝。

发现问题时，请把两端最后的“Docker 迁移结果”摘要、`docker version` 和发行版信息附到 issue 里。
