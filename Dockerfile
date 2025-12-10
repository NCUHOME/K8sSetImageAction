FROM alpine:latest

# 安装必要工具: curl (HTTP 请求) 和 jq (JSON 处理)
RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache curl jq tzdata && \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo 'Asia/Shanghai' >/etc/timezone && \
    rm -rf /var/cache/apk/*

# 复制 Shell 脚本
COPY set-image.sh /usr/bin/set-image.sh

# 设置执行权限
RUN chmod +x /usr/bin/set-image.sh

WORKDIR /data

# 执行脚本
ENTRYPOINT ["/usr/bin/set-image.sh"]