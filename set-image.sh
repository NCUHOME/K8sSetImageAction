#!/bin/sh
# K8s Set Image Action - 通过 Rancher API 更新 Kubernetes Workload 镜像

set -e

# 依赖检查
for cmd in jq curl; do
    if ! command -v $cmd > /dev/null 2>&1; then
        echo "错误: 未找到必需的命令 '$cmd'"
        exit 1
    fi
done

# 读取环境变量
BACKEND="${INPUT_BACKEND}"
TOKEN="${INPUT_TOKEN}"
CLUSTER="${INPUT_CLUSTER:-local}"
NAMESPACE="${INPUT_NAMESPACE}"
TYPE="${INPUT_TYPE:-deployments}"
WORKLOAD="${INPUT_WORKLOAD}"
CONTAINER="${INPUT_CONTAINER:-0}"
IMAGE="${INPUT_IMAGE}"
WAIT="${INPUT_WAIT:-false}"

# 验证 K8s 资源名称 (RFC 1123)
validate_k8s_name() {
    local name="$1"
    local field="$2"
    
    if [ -z "$name" ]; then
        echo "错误: ${field} 不能为空"
        exit 1
    fi
    
    if ! echo "$name" | grep -qE '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
        echo "错误: ${field} 格式无效: ${name}"
        echo "只允许小写字母、数字和连字符，且不能以连字符开头或结尾"
        exit 1
    fi
    
    if [ ${#name} -gt 253 ]; then
        echo "错误: ${field} 长度超过 253 字符"
        exit 1
    fi
}

validate_container_index() {
    local index="$1"
    
    if ! echo "$index" | grep -qE '^[0-9]+$'; then
        echo "错误: container 必须是非负整数"
        exit 1
    fi
    
    if [ "$index" -gt 99 ]; then
        echo "错误: container 索引超出范围 (0-99)"
        exit 1
    fi
}

validate_workload_type() {
    local type="$1"
    
    case "$type" in
        deployments|daemonsets|statefulsets)
            ;;
        *)
            echo "错误: 不支持的 workload 类型: ${type}"
            echo "支持: deployments, daemonsets, statefulsets"
            exit 1
            ;;
    esac
}

validate_image() {
    local image="$1"
    
    if [ -z "$image" ]; then
        echo "错误: image 不能为空"
        exit 1
    fi
    
    if ! echo "$image" | grep -qE '^[a-zA-Z0-9._:/@-]+$'; then
        echo "错误: image 格式无效: ${image}"
        echo "只允许字母、数字、点、连字符、下划线、斜杠、冒号和 @"
        exit 1
    fi
    
    if [ ${#image} -gt 512 ]; then
        echo "错误: image 长度超过 512 字符"
        exit 1
    fi
}

validate_token() {
    local token="$1"
    
    if [ -z "$token" ]; then
        echo "错误: token 不能为空"
        exit 1
    fi
    
    # 允许冒号以支持 Rancher token-xxx:yyyy 格式
    if ! echo "$token" | grep -qE '^[a-zA-Z0-9._:-]+$'; then
        echo "错误: token 包含非法字符"
        echo "只允许字母、数字、点、连字符、下划线和冒号"
        exit 1
    fi
    
    if [ ${#token} -gt 1024 ]; then
        echo "错误: token 长度超过 1024 字符"
        exit 1
    fi
}

validate_backend() {
    local url="$1"
    
    if ! echo "$url" | grep -qE '^https://[a-zA-Z0-9.-]+(:[0-9]+)?$'; then
        echo "错误: backend URL 格式无效或不安全"
        echo "格式: https://hostname[:port]"
        exit 1
    fi
}

urlencode() {
    local string="$1"
    # 这样写可以避免换行符问题
    printf '%s' "$string" | jq -Rr @uri
}

# 参数验证
if [ -z "$BACKEND" ] || [ -z "$TOKEN" ] || [ -z "$NAMESPACE" ] || [ -z "$WORKLOAD" ] || [ -z "$IMAGE" ]; then
    echo "错误: 缺少必需参数"
    echo "必需: backend, token, namespace, workload, image"
    exit 1
fi

validate_backend "$BACKEND"
validate_token "$TOKEN"
validate_k8s_name "$NAMESPACE" "namespace"
validate_k8s_name "$WORKLOAD" "workload"
validate_k8s_name "$CLUSTER" "cluster"
validate_workload_type "$TYPE"
validate_container_index "$CONTAINER"
validate_image "$IMAGE"

# 构建 API URL
BACKEND="${BACKEND%/}"
NAMESPACE_ENCODED=$(urlencode "$NAMESPACE")
WORKLOAD_ENCODED=$(urlencode "$WORKLOAD")
CLUSTER_ENCODED=$(urlencode "$CLUSTER")
API_URL="${BACKEND}/k8s/clusters/${CLUSTER_ENCODED}/apis/apps/v1/namespaces/${NAMESPACE_ENCODED}/${TYPE}/${WORKLOAD_ENCODED}"

echo "=== K8s Set Image Action ==="
echo "API URL: ${API_URL}"
echo "镜像: ${IMAGE}"
echo "容器索引: ${CONTAINER}"
echo ""

# 更新镜像
update_image() {
    local attempt=$1
    echo "[尝试 ${attempt}/5] 更新镜像..."

    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # 使用 Strategic Merge Patch 会自动创建不存在的字段
    PAYLOAD=$(jq -n \
        --argjson container "$CONTAINER" \
        --arg image "$IMAGE" \
        --arg timestamp "$TIMESTAMP" \
        '{
            "spec": {
                "template": {
                    "metadata": {
                        "annotations": {
                            "kubectl.kubernetes.io/restartedAt": $timestamp
                        }
                    },
                    "spec": {
                        "containers": [
                            {
                                "name": ("container-" + ($container | tostring)),
                                "image": $image
                            }
                        ]
                    }
                }
            }
        }')

    HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/response.json \
        -X PATCH \
        -H "User-Agent: curl/7.72.0" \
        -H "Accept: */*" \
        -H "Content-Type: application/strategic-merge-patch+json" \
        -H "Authorization: bearer ${TOKEN}" \
        -d "$PAYLOAD" \
        "$API_URL")

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
        echo "✓ 镜像更新成功 (强制重启于 ${TIMESTAMP})"
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

# 重试逻辑
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

# 等待部署完成
if [ "$WAIT" = "true" ]; then
    echo ""
    echo "=== 等待部署完成 ==="

    TIMEOUT=300
    ELAPSED=0
    RETRY_COUNT=0
    MAX_RETRY=5

    while [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 2
        ELAPSED=$((ELAPSED + 2))

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

        RETRY_COUNT=0

        # 解析状态字段
        TARGET_GEN=$(jq -r '.metadata.generation // 0' /tmp/status.json)
        OBSERVED_GEN=$(jq -r '.status.observedGeneration // -1' /tmp/status.json)
        REPLICAS=$(jq -r '.status.replicas // 0' /tmp/status.json)
        UPDATED_REPLICAS=$(jq -r '.status.updatedReplicas // 0' /tmp/status.json)
        AVAILABLE=$(jq -r '.status.availableReplicas // 0' /tmp/status.json)
        
        echo "[${ELAPSED}s] Gen: ${OBSERVED_GEN}/${TARGET_GEN} | Replicas: ${AVAILABLE}/${REPLICAS} (Updated: ${UPDATED_REPLICAS})"

        # 成功条件: observedGeneration >= generation && updatedReplicas == replicas == availableReplicas > 0
        if [ "$TARGET_GEN" != "0" ] && \
           [ "$OBSERVED_GEN" -ge "$TARGET_GEN" ] && \
           [ "$UPDATED_REPLICAS" -eq "$REPLICAS" ] && \
           [ "$AVAILABLE" -eq "$REPLICAS" ] && \
           [ "$REPLICAS" -gt 0 ]; then
            echo "✓ 部署成功：新版本已完全可用"
            break
        fi

        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "错误: 等待超时，部署未在 ${TIMEOUT} 秒内完成"
            echo "最终状态:"
            jq .status /tmp/status.json
            exit 1
        fi
    done
fi

echo ""
echo "=== 完成 ==="
