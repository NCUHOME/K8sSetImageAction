## 1. CronJob 支持

- [x] 1.1 更新 `validate_workload_type` 白名单，添加 `cronjobs`
- [x] 1.2 更新 API URL 构建逻辑，CronJob 使用 `batch/v1` API group
- [x] 1.3 更新 `get_container_name`，CronJob 使用 `spec.jobTemplate.spec.template.spec.containers` 路径读取容器列表
- [x] 1.4 更新 `update_image`，CronJob 使用 `spec.jobTemplate.spec.template.spec.containers` 路径构建 patch body
- [x] 1.5 在 wait 逻辑中添加 CronJob 拒绝处理，报错退出

## 2. 可配置 wait 超时

- [x] 2.1 读取 `INPUT_WAITTIMEOUT` 输入，默认值 `300`
- [x] 2.2 添加 `validate_wait_timeout` 函数，校验为正整数
- [x] 2.3 将 wait 逻辑中的 `TIMEOUT=300` 替换为用户输入值

## 3. 配置与文档

- [x] 3.1 更新 `action.yaml`，添加 `waittimeout` 输入参数定义
- [x] 3.2 更新 `README.md`，补充 cronjobs 类型和 waittimeout 参数说明
