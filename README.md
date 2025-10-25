# 🐳 Docker 一键迁移脚本

极简、高可用的 Docker 容器迁移工具。
设计目标：简单到只需一条命令，却尽量不翻车。

⸻

✨ 功能特性
	•	🚀 一键迁移：打包容器、数据、镜像，并通过 HTTP 提供下载
	•	🧱 Compose 优先：自动识别并打包 docker-compose 项目
	•	📦 离线可恢复：保存 images.tar，新机不联网也能启动
	•	🧩 卷/绑定分包：独立归档，避免混乱与冲突
	•	🔁 幂等恢复：重复执行不报错，支持部分重试
	•	🌐 智能端口/IP：HTTP 自动选择空闲端口，优先真实网卡 IP
	•	🧹 优雅清理：脚本退出自动回收 HTTP 服务，无残留进程
	•	🧠 无需 rsync/ssh：完全自包含，0 依赖

⸻

🧭 使用方法

在旧服务器（源机器）执行：

bash docker_migrate_perfect.sh

脚本会：
	1.	自动检测所有运行中的容器
	2.	让你选择要迁移的容器（或默认全部）
	3.	打包数据、卷、镜像、compose 文件
	4.	启动一个 HTTP 服务器并显示下载地址

执行完成后，终端会打印类似：

[OK] 下载地址： http://192.168.1.88:8080/uJ3N9XkfDq/


⸻

在新服务器（目标机器）：
	1.	打开上面的链接，下载整个文件夹（保持层级）
	2.	进入目录并执行：

bash restore.sh


	3.	查看容器是否运行：

docker ps



⸻

🔧 无人值守/自动化用法

# 指定容器 + 不停机打包
bash docker_migrate_perfect.sh --include=lsky-pro,mysql --no-stop

可与定时任务或 CI/CD 流程结合。

⸻

📁 迁移包结构

bundle/
 └── XXXXXXXXXX/
     ├── images.tar          # 镜像离线包
     ├── manifest.json       # 元数据
     ├── restore.sh          # 新机一键恢复脚本
     ├── compose/            # Compose 项目文件
     ├── volumes/            # 命名卷归档 (vol_*.tgz)
     ├── binds/              # 绑定目录归档 (bind_*.tgz)
     └── runs/               # 非 Compose 容器 docker run 脚本


⸻

⚠️ 注意事项
	•	本脚本通过 HTTP 明文传输，仅适用于可信内网。
	•	若需更高安全性，请在迁移后关闭 http.server。
	•	数据量大时，打包与传输可能较慢。
	•	若有数据库容器，请在迁移后检查数据一致性。

⸻

🧑‍💻 作者建议

“能跑、能用、能重来，就是最好的备份脚本。”

本脚本优先保障：
> 简洁  > 可恢复  > 不需要任何复杂命令。
