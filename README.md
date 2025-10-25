⸻


# 🐳 Docker Migrate — 一键迁移你的 Docker 容器

[![Shell Script](https://img.shields.io/badge/language-Bash-blue.svg)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Works%20with-Docker-orange.svg)](https://www.docker.com/)
[![GitHub stars](https://img.shields.io/github/stars/lx969788249/docker_migrate.svg?style=social&label=Star)](https://github.com/lx969788249/docker_migrate/stargazers)

> 零配置 · 零依赖 · 零 SSH  
> 一条命令迁移整个 Docker 应用 —— **越简单越可靠**

---

## ✨ 项目简介

`docker_migrate` 是一个极简高可用的 **Docker 一键迁移工具**。  
无需复杂设置，无需手动同步文件，它可以自动打包当前服务器上运行的 Docker 容器、镜像、数据卷和配置文件，然后在目标服务器上通过 **一个脚本 + 一个链接** 即可完成完整还原。

> 目标理念：**简单 > 稳定 > 可恢复**

---

## 🚀 功能亮点

- 🧱 **Compose 优先识别**：自动打包 Compose 项目及其依赖  
- 💾 **离线可恢复**：自动生成 `images.tar`，新机可离线启动  
- 🧩 **卷/绑定分包**：防止冲突、支持增量式恢复  
- 🔁 **幂等恢复**：重复执行不报错，可安全重试  
- 🌐 **自动检测端口/IP**：自动选择空闲端口并显示正确的本机 IP  
- 🧹 **优雅清理**：HTTP 服务自动清理，不留后台进程  
- 📦 **一键打包下载**：生成单文件 `RID.tar.gz`，更方便迁移  
- 🧠 **极简恢复脚本**：`auto_restore.sh` 只需粘贴链接，全自动恢复

---

## 🧭 使用方法

### 🖥️ 旧服务器上执行

```bash
bash docker_migrate_perfect.sh

脚本会：
	1.	自动检测所有正在运行的容器
	2.	打包镜像、卷、绑定目录和 Compose 文件
	3.	启动一个 HTTP 服务并显示下载地址：

[OK] 目录浏览： http://192.168.1.88:8080/AbCdEf1234/
[OK] 一键包下载： http://192.168.1.88:8080/AbCdEf1234.tar.gz


⸻

💻 新服务器上执行

下载恢复脚本：

curl -O https://raw.githubusercontent.com/lx969788249/docker_migrate/master/auto_restore.sh
chmod +x auto_restore.sh

运行恢复程序：

./auto_restore.sh

然后粘贴旧服务器显示的 .tar.gz 链接（例如 http://192.168.1.88:8080/AbCdEf1234.tar.gz）。

脚本将自动：
	1.	下载迁移包
	2.	解压
	3.	执行 restore.sh
	4.	启动所有容器

最后，你可以执行：

docker ps

验证恢复是否成功 ✅

⸻

📁 迁移包结构

bundle/
 └── <RID>/
     ├── images.tar          # 镜像离线包
     ├── manifest.json       # 元数据
     ├── restore.sh          # 新机恢复脚本
     ├── compose/            # Compose 项目文件
     ├── volumes/            # 命名卷归档 (vol_*.tgz)
     ├── binds/              # 绑定目录归档 (bind_*.tgz)
     └── runs/               # 非 Compose 容器 docker run 脚本


⸻

⚙️ 高级用法

指定容器并不中断服务：

bash docker_migrate_perfect.sh --include=lsky-pro,mysql --no-stop

自定义 HTTP 端口：

PORT=9090 bash docker_migrate_perfect.sh


⸻

🧰 环境要求

项目	要求
操作系统	Linux
必需命令	docker, jq, python3, tar, gzip
权限	需能执行 docker 命令（root 或 docker 组）


⸻

⚠️ 注意事项
	•	脚本通过 HTTP 明文 提供迁移包，请仅在 可信内网 使用
	•	若迁移数据库容器，建议停机打包确保数据一致性
	•	数据量较大时，打包与下载过程可能需要较长时间
	•	新机需已安装 Docker 环境

⸻

📦 快速迁移流程总结

步骤	操作
旧服务器	bash docker_migrate_perfect.sh
复制输出的链接	例如：http://192.168.1.88:8080/AbCdEf1234.tar.gz
新服务器	./auto_restore.sh + 粘贴链接
完成	自动恢复所有容器与配置


⸻

🧑‍💻 作者寄语

“能跑、能用、能重来，就是最好的迁移工具。”

这个项目追求：
	•	让小白也能迁移 Docker 应用
	•	一行命令就能备份 + 一行命令就能恢复

⸻

❤️ 支持项目

如果这个工具帮到了你，请给它点个 ⭐️
👉 Star 本项目

欢迎提交 Issue / PR 改进脚本，让更多人受益。

⸻

📜 License

MIT License © lx969788249

⸻


---
