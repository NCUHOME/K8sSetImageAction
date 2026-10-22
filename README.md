# K8sSetImageAction

通过 Rancher API 更新 Kubernetes Deployment / DaemonSet / StatefulSet / CronJob 镜像的 GitHub Action

## 特性

- ✅ 轻量级 Shell 脚本实现（composite action，无需构建镜像）
- ✅ 支持所有 Rancher 管理的 K8s 集群
- ✅ 支持 Deployment、DaemonSet、StatefulSet 和 CronJob
- ✅ 自动重试（最多 5 次；4xx 客户端错误不重试）
- ✅ 可选等待部署完成（支持 Deployment / DaemonSet / StatefulSet）
- ✅ 更新时写入 `kubectl.kubernetes.io/restartedAt` 注解，强制滚动重启以拉取新镜像

## 使用方法

```yaml
- name: Update Deployment
  uses: NCUHOME/K8sSetImageAction@v1
  with:
    server: "https://some.rancher.com" # Rancher Server Addr
    token: ${{ secrets.CATTLE_TOKEN }} # Rancher API Bearer Token
    namespace: "control"
    workload: "apicenter"
    image: "image.url:version"
    type: "daemonsets" # 可选, 默认 'deployments', 支持 deployments/daemonsets/statefulsets/cronjobs
    container: "1" # 可选, 容器索引, 默认 0
    wait: "true" # 可选, 等待部署完全可用, 默认 false（CronJob 不支持）
    waittimeout: "300" # 可选, 等待超时秒数, 默认 300
    cluster: "local" # 可选, 集群名称, 默认 'local'
```

## 运行依赖

runner 上需要 `bash`、`curl`、`jq >= 1.5`（GitHub 托管 runner 均自带）。

## 说明

- `server` 格式为 `https://hostname[:port][/path]`，支持反向代理的子路径，也支持 IPv6 字面量（如 `https://[::1]:8443`）。
- `wait: "true"` 会等到 `observedGeneration` 追上 `generation`，且所有副本都已更新并可用：
  - Deployment / StatefulSet：`replicas` / `updatedReplicas` / `availableReplicas`
  - DaemonSet：`desiredNumberScheduled` / `updatedNumberScheduled` / `numberAvailable`
  - StatefulSet 设置了 `partition` 时，只要求 ordinal >= partition 的 Pod 更新完成
  - Deployment 报 `ProgressDeadlineExceeded` 时立即失败，不再等满 `waittimeout`
  - 副本数为 0 时视为已完成（与 `kubectl rollout status` 一致）
- CronJob 没有“可用副本”概念，`type: cronjobs` 配合 `wait: "true"` 会在发出请求前直接报错。
- 每次更新都会刷新 `restartedAt` 注解，即使镜像未变化也会触发滚动重启；重试共用同一时间戳，不会重复触发。
- 并发更新同一 workload 时以最后一次写入为准，不做冲突检测。
- 生产环境建议把 action 固定到 commit SHA（如 `@<sha>`），避免 tag 被移动带来的供应链风险。

## 测试

```bash
bash tests/run.sh
```

用 mock curl 模拟 Rancher API，覆盖四种 workload 的请求路径、wait 状态判定、超时、重试与输入校验，无需真实集群。
