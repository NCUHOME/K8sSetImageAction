## 1. 容器名匹配修复

- [x] 1.1 修改 `update_image` 函数，在 PATCH 前先 GET 当前 workload 获取容器列表
- [x] 1.2 用 `jq` 按索引取出真实容器名，替换硬编码的 `container-N`
- [x] 1.3 添加容器索引越界的检查逻辑

## 2. 脚本兼容性与健壮性

- [x] 2.1 将 shebang 从 `#!/bin/sh` 改为 `#!/bin/bash`
- [x] 2.2 将重试等待从固定 1 秒改为 `sleep $i` 线性退避
- [x] 2.3 改进参数缺失的错误提示，列出具体缺失的参数名
- [x] 2.4 移除等待循环末尾的冗余超时检查

## 3. Dockerfile 优化

- [x] 3.1 移除 `apk upgrade` 命令
- [x] 3.2 在 `apk add` 中添加 `bash` 包

## 4. 文档完善

- [x] 4.1 在 README 的 type 参数说明中补充 `statefulsets`
- [x] 4.2 在 `.gitignore` 中添加 `.swp`、`.tmp` 等临时文件规则
