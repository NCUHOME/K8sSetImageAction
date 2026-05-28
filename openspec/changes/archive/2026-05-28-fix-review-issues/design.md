## 上下文

K8sSetImageAction 是一个通过 Rancher API 更新 K8s Workload 镜像的 GitHub Action。代码审查发现了 8 个问题，其中容器名硬编码是最严重的功能性 bug。

当前状态：脚本使用 `container-N` 作为容器名构建 PATCH payload，但 K8s 中容器名通常是自定义名称（如 `nginx`、`app`），导致 Strategic Merge Patch 无法匹配已有容器。

## 目标 / 非目标

**目标：**
- 修复容器名匹配逻辑，确保 PATCH 正确更新目标容器
- 修复 POSIX 兼容性问题
- 改进重试策略和错误提示
- 优化 Dockerfile 和文档

**非目标：**
- 重构整体架构
- 添加新功能（如支持 CronJob、Job 等其他 workload 类型）
- 添加测试框架

## 决策

### 1. 容器名获取方式

**决策**：在 PATCH 前先 GET 当前 workload，用 `jq` 按索引取出真实容器名。

**替代方案**：
- A) 改用容器名作为输入参数 — 增加用户负担，且索引更直观
- B) 使用 JSON Patch (RFC 6902) 的 `/spec/template/spec/containers/0/image` — 需要改 Content-Type，且 Rancher 对 Strategic Merge Patch 支持更好

**理由**：方案对用户透明，无需改输入参数，且保持 Strategic Merge Patch 的兼容性。

### 2. POSIX 兼容性处理

**决策**：将 shebang 从 `#!/bin/sh` 改为 `#!/bin/bash`。

**替代方案**：
- A) 去掉 `local` 关键字改用子 shell — 可读性差
- B) 保持 `#!/bin/sh` 但加注释说明 — 不够健壮

**理由**：Alpine 镜像支持 bash（需 `apk add bash`），改动最小且保证兼容性。

### 3. 重试退避策略

**决策**：改为 `sleep $i`（1s, 2s, 3s, 4s, 5s）的线性退避。

**替代方案**：
- A) 指数退避 — 对 5 次重试来说过于复杂
- B) 保持固定 1 秒 — 对 API 压力不够友好

**理由**：线性退避实现简单，对 5 次重试场景足够。

## 风险 / 权衡

- **[风险] 改 shebang 需要安装 bash** → 在 Dockerfile 中添加 `apk add --no-cache bash`，镜像体积增加约 5MB
- **[风险] GET 请求增加一次 API 调用** → 仅在 PATCH 前调用一次，影响可忽略
- **[权衡] 容器索引越界时不自动回退到索引 0** → 保持明确报错，避免静默错误
