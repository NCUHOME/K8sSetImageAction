#!/bin/bash
# K8s Set Image Action - 通过 Rancher API 更新 Kubernetes Workload 镜像

set -euo pipefail

# 依赖检查
for cmd in jq curl; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        echo "错误: 未找到必需的命令 '$cmd'" >&2
        exit 1
    fi
done

# 临时目录：避免固定路径在并发 job / 自托管 runner 上互相覆盖
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

CURL_OPTS=(-sS --connect-timeout 10 --max-time 30)
POLL_OPTS=(-sS --connect-timeout 5 --max-time 10)

# 读取环境变量
BACKEND="${INPUT_SERVER:-}"
TOKEN="${INPUT_TOKEN:-}"
CLUSTER="${INPUT_CLUSTER:-local}"
NAMESPACE="${INPUT_NAMESPACE:-}"
TYPE="${INPUT_TYPE:-deployments}"
WORKLOAD="${INPUT_WORKLOAD:-}"
CONTAINER="${INPUT_CONTAINER:-0}"
IMAGE="${INPUT_IMAGE:-}"
WAIT=$(printf '%s' "${INPUT_WAIT:-false}" | tr '[:upper:]' '[:lower:]')
WAITTIMEOUT="${INPUT_WAITTIMEOUT:-300}"

# 验证 K8s 资源名称 (RFC 1123 DNS label，上限 63)
validate_k8s_name() {
    local name="$1"
    local field="$2"

    if [ -z "$name" ]; then
        echo "错误: ${field} 不能为空" >&2
        exit 1
    fi

    # 用 [[ =~ ]] 而非 grep：grep 逐行匹配，含换行的输入可以绕过校验
    if [[ ! "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        echo "错误: ${field} 格式无效: ${name}" >&2
        echo "只允许小写字母、数字和连字符，且不能以连字符开头或结尾" >&2
        exit 1
    fi

    if [ ${#name} -gt 63 ]; then
        echo "错误: ${field} 长度超过 63 字符" >&2
        exit 1
    fi
}

# Rancher 集群 ID/名称：允许大写、点和下划线（displayName 可能含大写）
validate_cluster_name() {
    local name="$1"

    if [ -z "$name" ]; then
        echo "错误: cluster 不能为空" >&2
        exit 1
    fi

    if [[ ! "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
        echo "错误: cluster 格式无效: ${name}" >&2
        echo "只允许字母、数字、点、连字符和下划线，且不能以非字母数字开头或结尾" >&2
        exit 1
    fi

    if [ ${#name} -gt 253 ]; then
        echo "错误: cluster 长度超过 253 字符" >&2
        exit 1
    fi
}

validate_container_index() {
    local index="$1"

    if [[ ! "$index" =~ ^([0-9]|[1-9][0-9])$ ]]; then
        echo "错误: container 必须是 0-99 之间的整数" >&2
        exit 1
    fi
}

validate_wait_timeout() {
    local timeout="$1"

    if [[ ! "$timeout" =~ ^[1-9][0-9]{0,5}$ ]]; then
        echo "错误: waittimeout 必须是 1-999999 之间的正整数" >&2
        exit 1
    fi
}

validate_workload_type() {
    local type="$1"

    case "$type" in
        deployments|daemonsets|statefulsets|cronjobs)
            ;;
        *)
            echo "错误: 不支持的 workload 类型: ${type}" >&2
            echo "支持: deployments, daemonsets, statefulsets, cronjobs" >&2
            exit 1
            ;;
    esac
}

validate_wait_flag() {
    local wait="$1"

    case "$wait" in
        true|false)
            ;;
        *)
            echo "错误: wait 只支持 true 或 false: ${wait}" >&2
            exit 1
            ;;
    esac
}

validate_image() {
    local image="$1"

    if [ -z "$image" ]; then
        echo "错误: image 不能为空" >&2
        exit 1
    fi

    if [[ ! "$image" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$ ]]; then
        echo "错误: image 格式无效: ${image}" >&2
        echo "只允许字母、数字、点、连字符、下划线、斜杠、冒号和 @" >&2
        exit 1
    fi

    if [ ${#image} -gt 512 ]; then
        echo "错误: image 长度超过 512 字符" >&2
        exit 1
    fi
}

validate_token() {
    local token="$1"

    if [ -z "$token" ]; then
        echo "错误: token 不能为空" >&2
        exit 1
    fi

    # 允许冒号以支持 Rancher token-xxx:yyyy 格式
    if [[ ! "$token" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
        echo "错误: token 包含非法字符" >&2
        echo "只允许字母、数字、点、连字符、下划线和冒号" >&2
        exit 1
    fi

    if [ ${#token} -gt 1024 ]; then
        echo "错误: token 长度超过 1024 字符" >&2
        exit 1
    fi
}

validate_backend() {
    local url="$1"

    # 主机支持域名和 IPv6 字面量，可带端口和子路径（Rancher 反代在 /rancher 之类的前缀下）
    if [[ ! "$url" =~ ^https://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; then
        echo "错误: backend URL 格式无效或不安全" >&2
        echo "格式: https://hostname[:port][/path]，hostname 也可以是 [IPv6]" >&2
        exit 1
    fi
}

urlencode() {
    local string="$1"
    # 这样写可以避免换行符问题
    printf '%s' "$string" | jq -Rr @uri
}

# 参数验证
MISSING=""
[ -z "$BACKEND" ] && MISSING="${MISSING} server"
[ -z "$TOKEN" ] && MISSING="${MISSING} token"
[ -z "$NAMESPACE" ] && MISSING="${MISSING} namespace"
[ -z "$WORKLOAD" ] && MISSING="${MISSING} workload"
[ -z "$IMAGE" ] && MISSING="${MISSING} image"

if [ -n "$MISSING" ]; then
    echo "错误: 缺少必需参数:${MISSING}" >&2
    exit 1
fi

validate_backend "$BACKEND"
validate_token "$TOKEN"
validate_k8s_name "$NAMESPACE" "namespace"
validate_k8s_name "$WORKLOAD" "workload"
validate_cluster_name "$CLUSTER"
validate_workload_type "$TYPE"
validate_container_index "$CONTAINER"
validate_wait_flag "$WAIT"
validate_image "$IMAGE"
validate_wait_timeout "$WAITTIMEOUT"

# CronJob 没有"可用副本"概念：必须在发出写请求之前拒绝，
# 否则会出现"镜像已更新，但 job 报错退出"的半成功状态
if [ "$TYPE" = "cronjobs" ] && [ "$WAIT" = "true" ]; then
    echo "错误: CronJob 不支持 wait" >&2
    exit 1
fi

# 把 token 写进 600 权限的 curl 配置文件，避免出现在进程命令行（ps 可见）里
AUTH_CONF="$WORKDIR/curl-auth.conf"
(umask 077; printf 'header = "Authorization: bearer %s"\n' "$TOKEN" > "$AUTH_CONF")

# 整个运行周期共用一个时间戳：重试时 payload 完全相同，避免重复触发滚动重启
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 构建 API URL
while [ "${BACKEND%/}" != "$BACKEND" ]; do
    BACKEND="${BACKEND%/}"
done
NAMESPACE_ENCODED=$(urlencode "$NAMESPACE")
WORKLOAD_ENCODED=$(urlencode "$WORKLOAD")
CLUSTER_ENCODED=$(urlencode "$CLUSTER")

if [ "$TYPE" = "cronjobs" ]; then
    API_URL="${BACKEND}/k8s/clusters/${CLUSTER_ENCODED}/apis/batch/v1/namespaces/${NAMESPACE_ENCODED}/cronjobs/${WORKLOAD_ENCODED}"
else
    API_URL="${BACKEND}/k8s/clusters/${CLUSTER_ENCODED}/apis/apps/v1/namespaces/${NAMESPACE_ENCODED}/${TYPE}/${WORKLOAD_ENCODED}"
fi

echo "=== K8s Set Image Action ==="
echo "API URL: ${API_URL}"
echo "镜像: ${IMAGE}"
echo "容器索引: ${CONTAINER}"
echo ""

# CronJob 的容器路径与 apps 类型不同
if [ "$TYPE" = "cronjobs" ]; then
    CONTAINER_PATH=".spec.jobTemplate.spec.template.spec.containers"
else
    CONTAINER_PATH=".spec.template.spec.containers"
fi

# 获取真实容器名
get_container_name() {
    local index=$1
    local container_count
    local HTTP_CODE

    HTTP_CODE=$(curl "${CURL_OPTS[@]}" --config "$AUTH_CONF" \
        -w "%{http_code}" -o "$WORKDIR/workload.json" \
        "$API_URL") || true

    if [ "$HTTP_CODE" != "200" ]; then
        echo "错误: 无法获取 workload 信息 (HTTP ${HTTP_CODE})" >&2
        if [ -s "$WORKDIR/workload.json" ]; then
            echo "响应内容:" >&2
            cat "$WORKDIR/workload.json" >&2
            echo "" >&2
        fi
        exit 1
    fi

    if ! container_count=$(jq "${CONTAINER_PATH} | length" "$WORKDIR/workload.json" 2>/dev/null); then
        echo "错误: 无法解析 workload 响应" >&2
        exit 1
    fi

    if [ "$index" -ge "$container_count" ]; then
        echo "错误: container 索引 ${index} 超出范围 (共 ${container_count} 个容器)" >&2
        exit 1
    fi

    jq -r "${CONTAINER_PATH}[${index}].name" "$WORKDIR/workload.json"
}

# 更新镜像
update_image() {
    local attempt=$1
    local container_name=$2
    local PAYLOAD
    local HTTP_CODE

    echo "[尝试 ${attempt}/5] 更新镜像..."

    if [ "$TYPE" = "cronjobs" ]; then
        PAYLOAD=$(jq -n \
            --arg name "$container_name" \
            --arg image "$IMAGE" \
            --arg timestamp "$TIMESTAMP" \
            '{
                "spec": {
                    "jobTemplate": {
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
                                            "name": $name,
                                            "image": $image
                                        }
                                    ]
                                }
                            }
                        }
                    }
                }
            }')
    else
        PAYLOAD=$(jq -n \
            --arg name "$container_name" \
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
                                    "name": $name,
                                    "image": $image
                                }
                            ]
                        }
                    }
                }
            }')
    fi

    HTTP_CODE=$(curl "${CURL_OPTS[@]}" --config "$AUTH_CONF" \
        -w "%{http_code}" -o "$WORKDIR/response.json" \
        -X PATCH \
        -H "User-Agent: K8sSetImageAction" \
        -H "Accept: */*" \
        -H "Content-Type: application/strategic-merge-patch+json" \
        -d "$PAYLOAD" \
        "$API_URL") || true

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
        echo "✓ 镜像更新成功 (强制重启于 ${TIMESTAMP})"
        return 0
    fi

    echo "✗ 请求失败 (HTTP ${HTTP_CODE})" >&2
    if [ -s "$WORKDIR/response.json" ]; then
        cat "$WORKDIR/response.json" >&2
        echo "" >&2
    fi

    # 4xx 是客户端错误（token 无效、资源不存在等），重试没有意义
    if [ "${HTTP_CODE:0:1}" = "4" ]; then
        return 2
    fi

    return 1
}

# 获取真实容器名
CONTAINER_NAME=$(get_container_name "$CONTAINER")
if [ -z "$CONTAINER_NAME" ] || [ "$CONTAINER_NAME" = "null" ]; then
    echo "错误: 无法解析容器名" >&2
    exit 1
fi
echo "目标容器: ${CONTAINER_NAME}"

# 重试逻辑（4xx 不重试）
for i in 1 2 3 4 5; do
    rc=0
    update_image "$i" "$CONTAINER_NAME" || rc=$?

    if [ "$rc" -eq 0 ]; then
        break
    fi

    if [ "$rc" -eq 2 ]; then
        echo "错误: 请求被拒绝，不再重试" >&2
        exit 1
    fi

    if [ "$i" -eq 5 ]; then
        echo "错误: 达到最大重试次数" >&2
        exit 1
    fi

    echo "等待 ${i} 秒后重试..."
    sleep "$i"
done

# 判断滚动更新是否完成
# Deployment/StatefulSet 用 replicas / updatedReplicas / availableReplicas
# DaemonSet 用 desiredNumberScheduled / updatedNumberScheduled / numberAvailable
is_rollout_complete() {
    local file="$1"
    local target
    local observed
    local replicas
    local updated
    local available
    local expected
    local partition

    target=$(jq -r '.metadata.generation // 0' "$file")
    observed=$(jq -r '.status.observedGeneration // -1' "$file")

    if [ "$target" = "0" ] || [ "$observed" -lt "$target" ]; then
        echo "[${ELAPSED}s] Gen: ${observed}/${target} | 控制器尚未观察到新版本"
        return 1
    fi

    # 只有 observedGeneration 追上 generation 后，Progressing=False 才是本次发布的结果；
    # 否则可能是上一次失败遗留在对象上的旧 condition
    if has_progress_deadline_exceeded "$file"; then
        echo "错误: 滚动更新已失败 (ProgressDeadlineExceeded)" >&2
        jq -r '.status.conditions[]? | select(.type == "Progressing") | .message' "$file" >&2 2>/dev/null || true
        exit 1
    fi

    if [ "$TYPE" = "daemonsets" ]; then
        replicas=$(jq -r '.status.desiredNumberScheduled // 0' "$file")
        updated=$(jq -r '.status.updatedNumberScheduled // 0' "$file")
        available=$(jq -r '.status.numberAvailable // 0' "$file")
        expected=$replicas
    else
        replicas=$(jq -r '.status.replicas // 0' "$file")
        updated=$(jq -r '.status.updatedReplicas // 0' "$file")
        expected=$replicas

        if [ "$TYPE" = "statefulsets" ]; then
            # availableReplicas 在 K8s 1.22 之前不存在，回退到 readyReplicas
            available=$(jq -r '.status.availableReplicas // .status.readyReplicas // 0' "$file")
            # partition > 0 表示只滚动更新 ordinal >= partition 的 Pod，按 partition 计算期望值
            partition=$(jq -r '.spec.updateStrategy.rollingUpdate.partition // 0' "$file")
            if [ "$partition" -gt 0 ]; then
                expected=$((replicas - partition))
                if [ "$expected" -lt 0 ]; then
                    expected=0
                fi
            fi
        else
            available=$(jq -r '.status.availableReplicas // 0' "$file")
        fi
    fi

    echo "[${ELAPSED}s] Gen: ${observed}/${target} | Available: ${available}/${replicas} (Updated: ${updated}/${expected})"

    # 副本数为 0 时视为已完成（与 kubectl rollout status 行为一致）
    if [ "$replicas" -eq 0 ]; then
        return 0
    fi

    [ "$updated" -eq "$expected" ] && [ "$available" -eq "$replicas" ]
}

# Deployment 明确报告滚动失败时立即退出，不必等满 waittimeout
has_progress_deadline_exceeded() {
    local file="$1"

    jq -e '[.status.conditions[]? | select(.type == "Progressing" and .reason == "ProgressDeadlineExceeded")] | length > 0' \
        "$file" > /dev/null 2>&1
}

# 等待部署完成
if [ "$WAIT" = "true" ]; then
    echo ""
    echo "=== 等待部署完成 ==="

    TIMEOUT=$WAITTIMEOUT
    START=$SECONDS
    ELAPSED=0
    RETRY_COUNT=0
    MAX_RETRY=5
    READY=0

    # 用真实时钟而非累加 2s，避免 curl 耗时让实际等待远超 waittimeout
    while :; do
        ELAPSED=$((SECONDS - START))
        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            break
        fi

        sleep 2

        ELAPSED=$((SECONDS - START))

        HTTP_CODE=$(curl "${POLL_OPTS[@]}" --config "$AUTH_CONF" \
            -w "%{http_code}" -o "$WORKDIR/status.json" \
            "$API_URL") || true

        if [ "$HTTP_CODE" != "200" ]; then
            RETRY_COUNT=$((RETRY_COUNT + 1))
            echo "⚠ 获取部署状态失败 (${RETRY_COUNT}/${MAX_RETRY})"

            if [ "$RETRY_COUNT" -ge "$MAX_RETRY" ]; then
                echo "错误: 无法获取部署状态" >&2
                exit 1
            fi
            continue
        fi

        RETRY_COUNT=0

        if is_rollout_complete "$WORKDIR/status.json"; then
            echo "✓ 部署成功：新版本已完全可用"
            READY=1
            break
        fi
    done

    # 用 READY 标志而不是比较 ELAPSED：最后一次轮询成功时 ELAPSED 恰好等于 TIMEOUT
    if [ "$READY" -ne 1 ]; then
        echo "错误: 等待超时，部署未在 ${TIMEOUT} 秒内完成" >&2
        echo "最终状态:" >&2
        jq .status "$WORKDIR/status.json" >&2 2>/dev/null || true
        exit 1
    fi
fi

echo ""
echo "=== 完成 ==="
