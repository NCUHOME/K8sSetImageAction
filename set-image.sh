#!/bin/sh
# K8s Set Image Action - Shell 脚本版本
# 通过 Rancher API 更新 Deployment/DaemonSet 镜像

set -e

# 读取环境变量 (GitHub Action 会设置 INPUT_* 前缀)
BACKEND="${INPUT_BACKEND}"
TOKEN="${INPUT_TOKEN}"
CLUSTER="${INPUT_CLUSTER:-local}"
NAMESPACE="${INPUT_NAMESPACE}"
TYPE="${INPUT_TYPE:-deployments}"
WORKLOAD="${INPUT_WORKLOAD}"
CONTAINER="${INPUT_CONTAINER:-0}"
IMAGE="${INPUT_IMAGE}"
WAIT="${INPUT_WAIT:-false}"

# 参数验证
if [ -z "$BACKEND" ] || [ -z "$TOKEN" ] || [ -z "$NAMESPACE" ] || [ -z "$WORKLOAD" ] || [ -z "$IMAGE" ]; then
    echo "错误: 缺少必需参数"
    echo "必需: backend, token, namespace, workload, image"
    exit 1
fi

# 移除 BACKEND 末尾的斜杠
BACKEND="${BACKEND%/}"

# 构建 API URL
API_URL="${BACKEND}/k8s/clusters/${CLUSTER}/apis/apps/v1/namespaces/${NAMESPACE}/${TYPE}/${WORKLOAD}"

echo "=== K8s Set Image Action ==="
echo "API URL: ${API_URL}"
echo "镜像: ${IMAGE}"
echo "容器索引: ${CONTAINER}"
echo ""

# 更新镜像函数
update_image() {
    local attempt=$1
    echo "[尝试 ${attempt}/5] 更新镜像..."

    # 构建 JSON Patch payload
    PAYLOAD="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/${CONTAINER}/image\", \"value\": \"${IMAGE}\"}]"

    # 调用 Rancher API
    HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/response.json \
        -X PATCH \
        -H "User-Agent: curl/7.72.0" \
        -H "Accept: */*" \
        -H "Content-Type: application/json-patch+json" \
        -H "Authorization: bearer ${TOKEN}" \
        -d "$PAYLOAD" \
        "$API_URL")

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
        echo "✓ 镜像更新成功"
        return 0
    else
        echo "✗ 请求失败 (HTTP ${HTTP_CODE})"
        if [ -f /tmp/response.json ]; then
            cat /tmp/response.json
            echo ""
        fi
        return 1
    fi
}

# 重试逻辑 (最多 5 次)
for i in 1 2 3 4 5; do
    if update_image $i; then
        break
    fi

    if [ $i -eq 5 ]; then
        echo "错误: 达到最大重试次数"
        exit 1
    fi

    echo "等待 1 秒后重试..."
    sleep 1
done

# 等待部署可用 (如果启用)
if [ "$WAIT" = "true" ]; then
    echo ""
    echo "=== 等待部署完成 ==="

    TIMEOUT=300  # 5 分钟超时
    ELAPSED=0
    RETRY_COUNT=0
    MAX_RETRY=5

    while [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 1
        ELAPSED=$((ELAPSED + 1))

        # 获取部署状态
        HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/status.json \
            -H "Authorization: bearer ${TOKEN}" \
            "$API_URL")

        if [ "$HTTP_CODE" != "200" ]; then
            RETRY_COUNT=$((RETRY_COUNT + 1))
            echo "⚠ 获取部署状态失败 (${RETRY_COUNT}/${MAX_RETRY})"

            if [ $RETRY_COUNT -ge $MAX_RETRY ]; then
                echo "错误: 无法获取部署状态"
                exit 1
            fi
            continue
        fi

        # 重置重试计数
        RETRY_COUNT=0

        # 解析 JSON 获取 replicas 和 availableReplicas
        REPLICAS=$(jq -r '.status.replicas // 0' /tmp/status.json)
        AVAILABLE=$(jq -r '.status.availableReplicas // 0' /tmp/status.json)

        echo "[${ELAPSED}s] Replicas: ${AVAILABLE}/${REPLICAS}"

        # 检查是否全部可用
        if [ "$REPLICAS" != "0" ] && [ "$REPLICAS" = "$AVAILABLE" ]; then
            echo "✓ 部署已完全可用"
            break
        fi

        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "错误: 等待超时"
            exit 1
        fi
    done
fi

echo ""
echo "=== 完成 ==="
