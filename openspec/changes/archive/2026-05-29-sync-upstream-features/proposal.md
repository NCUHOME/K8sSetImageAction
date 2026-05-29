## 为什么

上游仓库 MMXK8sSetImageAction 在分叉后新增了 CronJob 工作负载支持和可配置等待超时。当前 sh 版本缺失这两个功能，需要同步以保持功能完备。

## 变更内容

- **新增** CronJob 工作负载类型支持（`batch/v1` API，patch body 路径含 `jobTemplate.spec`）
- **新增** 可配置 wait 超时（`waittimeout` 输入参数，默认 300 秒）
- 不同步代理支持（curl 原生支持，无需改代码）和自定义 body patch（违背 sh 版本简洁定位）

## 功能 (Capabilities)

### 新增功能
- `cronjob-support`: 支持 CronJob 工作负载类型的镜像更新
- `configurable-wait-timeout`: 支持自定义部署等待超时时间

### 修改功能
（无）

## 影响

- `set-image.sh`: 新增 CronJob 类型的 API URL 构建、patch body 生成、验证白名单更新；新增 `waittimeout` 输入读取和解析
- `action.yaml`: 新增 `waittimeout` 输入参数定义
- `README.md`: 更新支持的工作负载类型和输入参数文档
