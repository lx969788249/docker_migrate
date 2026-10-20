# 一台模拟服务器：自带独立 Docker 的容器，装好脚本需要的命令。
FROM docker:27.5-dind
RUN apk add --no-cache bash coreutils curl findutils gzip iproute2 iptables jq openssl procps python3 tar
# 只用本机 unix socket，不需要 TLS。
ENV DOCKER_TLS_CERTDIR=
