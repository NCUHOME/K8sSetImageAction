# 可选：把 action 作为独立容器镜像运行（GitHub Actions 走 composite，不依赖本文件）
FROM alpine:3.20

# 安装必要工具: curl (HTTP 请求), jq (JSON 处理), bash (脚本执行)
RUN apk add --no-cache bash curl jq tzdata \
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo 'Asia/Shanghai' > /etc/timezone

# 复制 Shell 脚本
COPY set-image.sh /usr/bin/set-image.sh
RUN chmod +x /usr/bin/set-image.sh

# 以非 root 运行，脚本只需写 /tmp
RUN adduser -D -u 10001 runner
USER 10001

WORKDIR /data

ENTRYPOINT ["/usr/bin/set-image.sh"]
