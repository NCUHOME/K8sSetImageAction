## 为什么

代码审查发现了多个问题，其中最严重的是容器名硬编码 `container-N` 导致 Strategic Merge Patch 无法正确匹配已有容器，几乎必然会在实际使用中创建多余容器或更新失败。此外还有 POSIX 兼容性、超时逻辑、错误提示等方面的问题需要一并修复。

## 变更内容

- **修复容器名匹配**：先 GET 当前 workload，按索引取出真实容器名，再构建 PATCH payload
- **修复 POSIX 兼容性**：将 shebang 改为 `#!/bin/bash` 或消除 `local` 关键字
- **优化超时逻辑**：移除循环末尾的死代码，统一超时判断
- **改进错误提示**：列出具体缺失的参数名
- **添加重试退避**：将固定 1 秒改为递增退避
- **Dockerfile 优化**：移除不必要的 `apk upgrade`
- **补充 .gitignore**：添加常见临时文件规则
- **README 完善**：补充 `statefulsets` 类型说明

## 功能 (Capabilities)

### 新增功能

### 修改功能

- `set-image`: 容器名匹配逻辑、重试策略、错误提示、POSIX 兼容性
- `docker-build`: Dockerfile 构建优化
- `docs`: README 和 .gitignore 完善

## 影响

- `set-image.sh` — 核心脚本，主要逻辑变更
- `Dockerfile` — 构建层优化
- `.gitignore` — 新增规则
- `README.md` — 文档更新
