## 新增需求

### 需求:支持 CronJob 工作负载类型
系统必须支持通过 `type: cronjobs` 参数更新 CronJob 的容器镜像。当 type 为 `cronjobs` 时，API URL 必须使用 `batch/v1` API group，patch body 路径必须使用 `spec.jobTemplate.spec.template.spec.containers`。

#### 场景:更新 CronJob 镜像
- **当** 用户指定 `type=cronjobs`、`workload=my-cronjob`、`container=0`、`image=nginx:latest`
- **那么** 系统通过 `{backend}/k8s/clusters/{cluster}/apis/batch/v1/namespaces/{namespace}/cronjobs/{workload}` 获取容器名并 PATCH 镜像

#### 场景:CronJob 不支持等待
- **当** 用户指定 `type=cronjobs` 且 `wait=true`
- **那么** 系统必须报错退出并提示 CronJob 不支持等待

#### 场景:CronJob 容器索引超出范围
- **当** 用户指定的 container 索引大于等于 CronJob 中实际容器数量
- **那么** 系统必须报错退出并提示索引超出范围
