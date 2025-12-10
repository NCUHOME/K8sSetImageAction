# K8sSetImageAction

通过 Rancher API 更新 Kubernetes Deployment/DaemonSet 镜像的 GitHub Action

## 特性

- ✅ 轻量级 Shell 脚本实现
- ✅ 支持所有 Rancher 管理的 K8s 集群
- ✅ 支持 Deployment 和 DaemonSet
- ✅ 自动重试（最多 5 次）
- ✅ 可选等待部署完成

## 使用方法

```yaml
- name: Update Deployment
  uses: MultiMx/K8sSetImageAction@v0.7
  with:
    backend: "https://some.rancher.com"
    token: ${{ secrets.CATTLE_TOKEN }} # Rancher API Bearer Token
    namespace: "control"
    workload: "apicenter"
    image: "image.url:version"
    type: "daemonsets" # 可选, 默认 'deployments'
    container: "1" # 可选, 容器索引, 默认 0
    wait: "true" # 可选, 等待部署完全可用, 默认 false
    cluster: "local" # 可选, 集群名称, 默认 'local'
```
