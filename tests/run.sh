#!/bin/bash
# shellcheck disable=SC2016,SC2034
# 端到端测试：用 mock curl 替代 Rancher API，验证 set-image.sh 的关键行为
# 用法: bash tests/run.sh

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/set-image.sh"
STATE=$(mktemp -d)
trap 'rm -rf "$STATE"' EXIT

export MOCK_STATE="$STATE"
MOCK_BIN="$STATE/bin"
mkdir -p "$MOCK_BIN"
cp "$ROOT/tests/mock-curl" "$MOCK_BIN/curl"
chmod +x "$MOCK_BIN/curl"

PASS=0
FAIL=0

WORKLOAD='{"spec":{"template":{"spec":{"containers":[{"name":"app","image":"old:1"},{"name":"side","image":"s:1"}]}}}}'
CRONJOB='{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"job","image":"old"}]}}}}}}'

reset() {
    rm -f "$STATE"/patch-calls "$STATE"/get-calls "$STATE"/payload-*.json \
          "$STATE"/patch-seq "$STATE"/seen-auth "$STATE"/all-args
}

check() {
    if eval "$2"; then
        echo "  PASS  $1"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $1"
        tail -n 6 "$STATE/out.log" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
}

# 公共环境变量：调用方通过 stdin 方式覆盖不会生效，所以统一在这里 export
run() {
    PATH="$MOCK_BIN:$PATH" INPUT_SERVER="${INPUT_SERVER:-https://rancher.test}" \
        INPUT_TOKEN="${INPUT_TOKEN:-token-a:b}" INPUT_NAMESPACE="${INPUT_NAMESPACE:-default}" \
        INPUT_WORKLOAD="${INPUT_WORKLOAD:-web}" INPUT_IMAGE="${INPUT_IMAGE:-nginx:1.27}" \
        INPUT_TYPE="${INPUT_TYPE:-deployments}" INPUT_CONTAINER="${INPUT_CONTAINER:-0}" \
        INPUT_WAIT="${INPUT_WAIT:-false}" INPUT_WAITTIMEOUT="${INPUT_WAITTIMEOUT:-10}" \
        INPUT_CLUSTER="${INPUT_CLUSTER:-local}" \
        bash "$SCRIPT" > "$STATE/out.log" 2>&1
}

echo "== 1. Deployment wait 成功 =="
reset
MOCK_WORKLOAD="$WORKLOAD" \
MOCK_STATUS='{"metadata":{"generation":7},"status":{"observedGeneration":7,"replicas":3,"updatedReplicas":3,"availableReplicas":3}}' \
INPUT_WAIT=true run
RC=$?
check "退出码 0" '[ "$RC" -eq 0 ]'
check "payload 使用真实容器名和镜像" 'jq -e ".spec.template.spec.containers[0].name==\"app\" and .spec.template.spec.containers[0].image==\"nginx:1.27\"" "$STATE/payload-1.json" >/dev/null'
check "写入 restartedAt 注解" 'jq -e ".spec.template.metadata.annotations[\"kubectl.kubernetes.io/restartedAt\"]" "$STATE/payload-1.json" >/dev/null'

echo "== 2. DaemonSet wait 使用 DaemonSet 状态字段 =="
reset
MOCK_WORKLOAD="$WORKLOAD" \
MOCK_STATUS='{"metadata":{"generation":3},"status":{"observedGeneration":3,"desiredNumberScheduled":5,"updatedNumberScheduled":5,"numberAvailable":5}}' \
INPUT_TYPE=daemonsets INPUT_WAIT=true run
RC=$?
check "退出码 0" '[ "$RC" -eq 0 ]'

echo "== 3. 最后一次轮询成功不误报超时 =="
reset
MOCK_WORKLOAD="$WORKLOAD" \
MOCK_STATUS_FIRST='{"metadata":{"generation":2},"status":{"observedGeneration":2,"replicas":3,"updatedReplicas":0,"availableReplicas":3}}' \
MOCK_STATUS='{"metadata":{"generation":2},"status":{"observedGeneration":2,"replicas":3,"updatedReplicas":3,"availableReplicas":3}}' \
INPUT_WAIT=true INPUT_WAITTIMEOUT=4 run
RC=$?
check "退出码 0" '[ "$RC" -eq 0 ]'

echo "== 4. 真正超时 =="
reset
MOCK_WORKLOAD="$WORKLOAD" \
MOCK_STATUS='{"metadata":{"generation":2},"status":{"observedGeneration":2,"replicas":3,"updatedReplicas":1,"availableReplicas":3}}' \
INPUT_WAIT=true INPUT_WAITTIMEOUT=2 run
check "退出码非 0" '[ $? -ne 0 ]'
check "提示等待超时" 'grep -q "等待超时" "$STATE/out.log"'

echo "== 5. CronJob + wait 在发请求前拒绝 =="
reset
MOCK_WORKLOAD="$CRONJOB" \
INPUT_TYPE=cronjobs INPUT_WORKLOAD=nightly INPUT_WAIT=true run
RC=$?
check "退出码非 0" '[ "$RC" -ne 0 ]'
check "未发出任何请求" '[ ! -f "$STATE/get-calls" ] && [ ! -f "$STATE/patch-calls" ]'
check "提示 CronJob 不支持 wait" 'grep -q "CronJob 不支持 wait" "$STATE/out.log"'

echo "== 6. 4xx 不重试 =="
reset
MOCK_WORKLOAD="$WORKLOAD" MOCK_PATCH_CODE=403 run
RC=$?
check "退出码非 0" '[ "$RC" -ne 0 ]'
check "PATCH 只调用 1 次" '[ "$(wc -l < "$STATE/patch-calls" | tr -d " ")" = "1" ]'

echo "== 7. 5xx 重试后成功且 payload 幂等 =="
reset
printf '500\n200\n' > "$STATE/patch-seq"
MOCK_WORKLOAD="$WORKLOAD" run
RC=$?
check "退出码 0" '[ "$RC" -eq 0 ]'
check "PATCH 调用 2 次" '[ "$(wc -l < "$STATE/patch-calls" | tr -d " ")" = "2" ]'
check "两次 payload 完全一致" 'cmp -s "$STATE/payload-1.json" "$STATE/payload-2.json"'

echo "== 8. 输入校验（换行 / echo -n 边界） =="
for bad in $'nginx:1.0\n; curl evil' '-n'; do
    reset
    INPUT_IMAGE="$bad" run
    RC=$?
    check "镜像 '$bad' 被拒绝" '[ "$RC" -ne 0 ]'
done
reset
INPUT_TOKEN=$'token-a:b\nx' run
RC=$?
check "token 含换行被拒绝" '[ "$RC" -ne 0 ]'

echo "== 9. server 子路径 / IPv6 / 非法协议 =="
reset
MOCK_WORKLOAD="$WORKLOAD" INPUT_SERVER=https://rancher.test/rancher run
RC=$?
check "子路径可用" '[ "$RC" -eq 0 ]'
check "URL 拼接正确" 'grep -q "rancher.test/rancher/k8s/clusters" "$STATE/out.log"'
reset
MOCK_WORKLOAD="$WORKLOAD" INPUT_SERVER='https://[::1]:8443' run
RC=$?
check "IPv6 可用" '[ "$RC" -eq 0 ]'
reset
INPUT_SERVER=http://rancher.test run
RC=$?
check "http 被拒绝" '[ "$RC" -ne 0 ]'

echo "== 10. token 不出现在命令行参数 =="
reset
MOCK_WORKLOAD="$WORKLOAD" INPUT_TOKEN=token-secret:xyz run
RC=$?
check "退出码 0" '[ "$RC" -eq 0 ]'
check "token 通过 curl --config 传入" 'grep -q "Authorization: bearer token-secret:xyz" "$STATE/seen-auth"'
check "命令行参数中无 token" '! grep -q "token-secret" "$STATE/all-args"'

echo "== 11. 副本数为 0 视为完成 =="
reset
MOCK_WORKLOAD="$WORKLOAD" \
MOCK_STATUS='{"metadata":{"generation":9},"status":{"observedGeneration":9,"replicas":0,"updatedReplicas":0,"availableReplicas":0}}' \
INPUT_WAIT=true INPUT_WAITTIMEOUT=4 run
RC=$?
check "退出码 0" '[ "$RC" -eq 0 ]'

echo "== 12. StatefulSet partition =="
reset
MOCK_WORKLOAD="$WORKLOAD" \
MOCK_STATUS='{"metadata":{"generation":4},"spec":{"updateStrategy":{"rollingUpdate":{"partition":1}}},"status":{"observedGeneration":4,"replicas":3,"updatedReplicas":2,"availableReplicas":3}}' \
INPUT_TYPE=statefulsets INPUT_WAIT=true INPUT_WAITTIMEOUT=6 run
RC=$?
check "退出码 0" '[ "$RC" -eq 0 ]'

echo "== 13. ProgressDeadlineExceeded 快速失败 =="
reset
START=$SECONDS
MOCK_WORKLOAD="$WORKLOAD" \
MOCK_STATUS='{"metadata":{"generation":2},"status":{"observedGeneration":2,"replicas":3,"updatedReplicas":1,"availableReplicas":2,"conditions":[{"type":"Progressing","status":"False","reason":"ProgressDeadlineExceeded","message":"ReplicaSet has timed out progressing."}]}}' \
INPUT_WAIT=true INPUT_WAITTIMEOUT=30 run
RC=$?
COST=$((SECONDS - START))
check "退出码非 0" '[ "$RC" -ne 0 ]'
check "提示 ProgressDeadlineExceeded" 'grep -q "ProgressDeadlineExceeded" "$STATE/out.log"'
check "未等满超时 (${COST}s < 10s)" '[ "$COST" -lt 10 ]'

echo
echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" -eq 0 ]
