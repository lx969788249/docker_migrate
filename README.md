# **🐳 Docker Migrate — 一键迁移 Docker 的强大工具**

_碎碎念：作为一名MJJ，Docker迁移总是让我头痛，一次两次还好，迁移次数多了难免会厌烦。每次进行备份、恢复，再手动创建网络和环境，都让我感到十分头疼。于是，我萌生了一个想法：干脆编写一个一键迁移脚本，一劳永逸地解决这些问题。就这样，这个迁移脚本应运而生。希望这个脚本能够给大家的玩机生涯带来一点点的帮助_

> 🚀 全自动迁移 Docker：镜像、网络、数据卷、绑定目录、Compose 配置、1Panel 应用——统统打包恢复，一步到位！

## **✨ 功能亮点**

-   🔍 **全面兼容 docker run、docker compose 以及 1Panel 部署的容器**
-   📦 **完整迁移你的 Docker 环境**
    -   Docker 镜像
    -   命名卷（volume）
    -   绑定目录（bind mount）
    -   Docker 网络
    -   Compose 配置文件（包括 1Panel 的绝对路径 YAML） 可以说，原服务器什么样，新服务器就什么样。
-   🔁 **新服务器一键恢复，方便快捷** 自动解压、重建卷、恢复绑定目录、加载 Compose 配置，并自动启动容器。
-   🔐 **安全的迁移包传输方式，防止文件泄露** 使用随机 Token 的安全路径： [http://IP:PORT/](http://IP:PORT/)/.tar.gz 非目标路径一律返回 404，避免端口扫描导致文件泄露。
-   ⚙️ **简单易上手，小白也能爽用** 开箱即用，即使是新手也能轻松完成服务器迁移。

## **🧭 使用方法**

## **🖥️ ① 在旧服务器执行命令**

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/lx969788249/docker_migrate/master/docker_migrate_perfect.sh)
```

复制最后输出的链接，例： [http://192.168.1.1:8080/XyZ83mqP10/Mlq1n3069T.tar.gz](http://192.168.1.1:8080/XyZ83mqP10/Mlq1n3069T.tar.gz)

## **💻 ② 在新服务器执行命令**

运行恢复脚本：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/lx969788249/docker_migrate/master/auto_restore.sh)
```

粘贴刚刚复制的链接，脚本会自动下载，解压恢复所有容器

## **⚠️ 注意事项**

-   HTTP 传输为明文，建议仅在可信网络中使用。
-   对于数据库类服务，建议选择停机备份以确保数据一致性。
-   如果你的容器路径非常特殊（如挂载到无权限路径），需确保 root 用户有访问权限。
-   脚本刚刚完成，可能会有诸多BUG，请谅解，遇到BUG请提Issue，我会尽快修复。

## **⭐️ 支持一下**

## 如果这个项目对你有帮助，欢迎点个 Star！[https://github.com/lx969788249/docker\_migrate](https://github.com/lx969788249/docker_migrate)

也欢迎提交 Issue 或 PR，一起优化功能。

## **🧑‍💻 作者**

## MIT License © lx969788249
