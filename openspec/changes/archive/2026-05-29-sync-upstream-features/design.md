## 上下文

当前 `set-image.sh` 通过 Rancher API 代理更新 K8s 工作负载镜像，支持 Deployment、DaemonSet、StatefulSet。上游 MMXK8sSetImageAction 在 Node.js 重写后新增了 CronJob 支持和可配置等待超时。本次变更将这两个功能移植到 sh 版本。

## 目标 / 非目标

**目标：**
- 支持 CronJob 工作负载类型的镜像更新
- 支持自定义 wait 超时时间

**非目标：**
- 不同步代理支持（curl 原生处理）
- 不同步自定义 body patch（违背 sh 版本定位）
- 不引入新的外部依赖

## 决策

### 1. CronJob API 路径构建

**选择**: 根据 `TYPE` 变量条件切换 API group

- `deployments`/`daemonsets`/`statefulsets` → `apis/apps/v1/namespaces/{ns}/{type}/{name}`
- `cronjobs` → `apis/batch/v1/namespaces/{ns}/cronjobs/{name}`

**理由**: CronJob 属于 `batch` API group，与 `apps` 不同。通过在 URL 构建处用 if/else 分支处理，改动最小。

### 2. CronJob Patch Body 路径

**选择**: CronJob 使用 `spec.jobTemplate.spec.template.spec.containers` 路径

**理由**: 这是 K8s CronJob 的标准结构，Job template 嵌套在 `jobTemplate` 下。需要单独的 body 构建逻辑。

### 3. CronJob Wait 行为

**选择**: CronJob 拒绝 wait 请求，直接报错退出

**理由**: CronJob 没有"可用"状态的概念，等待无意义。与上游行为一致。

### 4. 等待超时参数设计

**选择**: 新增 `waittimeout` 输入参数，默认值 `300`，单位秒

**理由**: 保持与现有脚本中 `TIMEOUT=300` 的一致性，用秒而非毫秒更符合 shell 脚本习惯。需要添加正整数校验。

## 风险 / 权衡

- [CronJob get_container_name 路径不同] → 需要对 CronJob 使用 `spec.jobTemplate.spec.template.spec.containers` 读取容器列表，复用函数时需传递路径参数或分支处理
- [waittimeout 输入为字符串] → 需要校验为正整数，防止注入和非法值
