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

# ============================================
# 输入验证函数
# ============================================

# 验证 Kubernetes 资源名称格式 (RFC 1123 子域名)
validate_k8s_name() {
    local name="$1"
    local field="$2"
    
    if [ -z "$name" ]; then
        echo "错误: ${field} 不能为空"
        exit 1
    fi
    
    # K8s 资源名称规则: 小写字母、数字、连字符，不能以连字符开头或结尾
    if ! echo "$name" | grep -qE '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
        echo "错误: ${field} 格式无效: ${name}"
        echo "只允许小写字母、数字和连字符，且不能以连字符开头或结尾"
        exit 1
    fi
    
    # 长度限制 (K8s 限制为 253 字符)
    if [ ${#name} -gt 253 ]; then
        echo "错误: ${field} 长度超过 253 字符"
        exit 1
    fi
}

# 验证容器索引
validate_container_index() {
    local index="$1"
    
    if ! echo "$index" | grep -qE '^[0-9]+$'; then
        echo "错误: container 必须是非负整数"
        exit 1
    fi
    
    # 合理的容器索引范围 (0-99)
    if [ "$index" -gt 99 ]; then
        echo "错误: container 索引超出合理范围 (0-99)"
        exit 1
    fi
}

# 验证 workload 类型 (白名单)
validate_workload_type() {
    local type="$1"
    
    case "$type" in
        deployments|daemonsets|statefulsets)
            ;;
        *)
            echo "错误: 不支持的 workload 类型: ${type}"
            echo "支持的类型: deployments, daemonsets, statefulsets"
            exit 1
            ;;
    esac
}

# 验证镜像名称格式
validate_image() {
    local image="$1"
    
    if [ -z "$image" ]; then
        echo "错误: image 不能为空"
        exit 1
    fi
    
    # 基本的镜像名称格式验证 (允许 registry/repo:tag 格式)
    # 允许字母、数字、点、连字符、下划线、斜杠、冒号
    if ! echo "$image" | grep -qE '^[a-zA-Z0-9._:/-]+$'; then
        echo "错误: image 格式无效: ${image}"
        echo "只允许字母、数字、点、连字符、下划线、斜杠和冒号"
        exit 1
    fi
}

# URL 编码函数
urlencode() {
    local string="$1"
    # 使用 jq 进行 URL 编码
    echo "$string" | jq -sRr @uri
}

# ============================================
# 参数验证
# ============================================

# 检查必需参数
if [ -z "$BACKEND" ] || [ -z "$TOKEN" ] || [ -z "$NAMESPACE" ] || [ -z "$WORKLOAD" ] || [ -z "$IMAGE" ]; then
    echo "错误: 缺少必需参数"
    echo "必需: backend, token, namespace, workload, image"
    exit 1
fi

# 验证各个参数
validate_k8s_name "$NAMESPACE" "namespace"
validate_k8s_name "$WORKLOAD" "workload"
validate_k8s_name "$CLUSTER" "cluster"
validate_workload_type "$TYPE"
validate_container_index "$CONTAINER"
validate_image "$IMAGE"

# 验证 BACKEND URL 格式
if ! echo "$BACKEND" | grep -qE '^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$'; then
    echo "错误: backend URL 格式无效"
    echo "格式: http(s)://hostname[:port]"
    exit 1
fi

# 移除 BACKEND 末尾的斜杠
BACKEND="${BACKEND%/}"

# 构建 API URL (使用 URL 编码)
NAMESPACE_ENCODED=$(urlencode "$NAMESPACE")
WORKLOAD_ENCODED=$(urlencode "$WORKLOAD")
CLUSTER_ENCODED=$(urlencode "$CLUSTER")
API_URL="${BACKEND}/k8s/clusters/${CLUSTER_ENCODED}/apis/apps/v1/namespaces/${NAMESPACE_ENCODED}/${TYPE}/${WORKLOAD_ENCODED}"

echo "=== K8s Set Image Action ==="
echo "API URL: ${API_URL}"
echo "镜像: ${IMAGE}"
echo "容器索引: ${CONTAINER}"
echo ""

# 更新镜像函数
update_image() {
    local attempt=$1
    echo "[尝试 ${attempt}/5] 更新镜像..."

    # 使用 jq 安全地构造 JSON Patch payload
    # 通过 --arg 传递参数，jq 会自动处理转义
    PAYLOAD=$(jq -n \
        --arg container "$CONTAINER" \
        --arg image "$IMAGE" \
        '[{
            "op": "replace",
            "path": ("/spec/template/spec/containers/" + $container + "/image"),
            "value": $image
        }]')

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
