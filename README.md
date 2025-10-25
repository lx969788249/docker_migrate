# 🐳 Docker Migrate — 一键迁移你的 Docker 容器

> 一条命令迁移你的 Docker 应用：镜像、数据卷、绑定目录、Compose 配置全自动打包恢复。

---

## ✨ 功能特点
- 🚀 一键打包并生成下载链接  
- 🧱 自动识别并还原 Docker Compose 项目  
- 💾 离线可恢复（含镜像 `images.tar`）  
- 🧩 支持命名卷与绑定目录完整迁移  
- 🌐 自动检测空闲端口与本机 IP  
- 🔁 新服务器自动下载、解压、恢复  

---

## 🚀 食用方法

### 🖥️ 在旧服务器执行：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lx969788249/docker_migrate/master/docker_migrate_perfect.sh)
```
执行后会生成迁移包并显示下载链接，例如：

http://192.168.1.88:8080/AbCdEf1234.tar.gz


⸻

### 💻 在新服务器执行：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lx969788249/docker_migrate/master/auto_restore.sh)
```
然后粘贴旧服务器输出的链接（以 .tar.gz 结尾）即可自动下载并恢复所有容器。

⸻

🧑‍💻 作者

MIT License © lx969788249

