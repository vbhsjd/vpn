# UniVPN Sidecar 容器

本仓库把 UniVPN Linux 命令行客户端打包成容器镜像，适用于主业务容器启动前必须先建立 VPN 隧道的 Kubernetes 工作负载。公开源码只保留当前实际使用的单 VPN sidecar/initContainer 方案。

## 提供什么

- 轻量的 UniVPN CLI 容器，不包含桌面、VNC 或多 VPN 逻辑。
- 支持通过 `VPN_SERVER`、`VPN_PORT` 和 `VPN_PROFILE_NAME` 快速生成连接配置。
- 支持通过挂载 `.ini` 文件或 `VPN_CONFIG_B64` 预加载配置。
- 提供 Kubernetes sidecar/initContainer 示例，适合需要等待 VPN 隧道就绪后再启动业务容器的场景。
- 支持优雅退出：Kubernetes 停止容器时，包装脚本会先向 `UniVPNCS` 发送 `q` 断开连接，然后才回退到进程终止。

## 目录结构

- `delivery/univpn-sidecar-single-vpn-minimal/`：sidecar 镜像的 Docker 构建文件、运行脚本、健康检查和 Kubernetes 示例。

## 第三方二进制说明

UniVPN Linux 安装包是第三方二进制文件，本仓库不会重新分发。构建镜像前，请把厂商提供的安装包放到：

```text
delivery/univpn-sidecar-single-vpn-minimal/univpn-linux-64-10781.18.1.0512.run
```

本仓库的 MIT 许可证只适用于这里的脚本、Kubernetes 清单和文档，不授予重新分发 UniVPN 客户端的权利。

## 快速开始

```bash
cd delivery/univpn-sidecar-single-vpn-minimal
cp examples/.env.example .env
./build.sh dev
docker run -d --name univpn-sidecar-test \
  --privileged \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add SYS_MODULE \
  --device /dev/net/tun:/dev/net/tun \
  --env-file .env \
  univpn-sidecar:dev
```

Kubernetes 示例见：

- `delivery/univpn-sidecar-single-vpn-minimal/k8s-res-univpn.yaml`
- `delivery/univpn-sidecar-single-vpn-minimal/k8s-sidecar-initcontainer-example.yaml`

## 安全说明

不要提交真实 VPN 账号密码、生成后的配置、厂商安装包、运行日志或本地镜像压缩包。真实配置应放在 Kubernetes Secret、私有 `.env` 文件或你自己的密钥管理系统中。
