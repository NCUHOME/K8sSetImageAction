## 修改需求

### 需求:移除 apk upgrade
Dockerfile 构建时禁止执行 `apk upgrade`，以确保构建可复现性。

#### 场景:Dockerfile 构建
- **当** 构建 Docker 镜像
- **那么** 系统必须仅执行 `apk add --no-cache` 安装依赖，禁止执行 `apk upgrade`

### 需求:安装 bash
Dockerfile 必须安装 bash 包以支持脚本的 bash shebang。

#### 场景:安装 bash
- **当** 构建 Docker 镜像
- **那么** 系统必须在 `apk add` 中包含 `bash`
