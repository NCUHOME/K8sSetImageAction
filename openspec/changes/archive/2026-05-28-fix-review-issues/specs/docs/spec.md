## 修改需求

### 需求:README 补充 statefulsets
README 文档必须在 type 参数说明中列出所有支持的 workload 类型，包括 `statefulsets`。

#### 场景:type 参数文档
- **当** 用户查看 README 的使用示例
- **那么** 文档必须注明 type 支持 `deployments`、`daemonsets`、`statefulsets` 三种类型

### 需求:.gitignore 完善
.gitignore 必须包含常见临时文件和编辑器文件的忽略规则。

#### 场景:忽略规则
- **当** 项目根目录存在临时文件（如 `.swp`、`.tmp`）
- **那么** git 必须忽略这些文件
