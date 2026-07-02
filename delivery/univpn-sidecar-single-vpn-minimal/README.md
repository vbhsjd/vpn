# UniVPN 单 VPN Sidecar

这个镜像在容器内运行一个 UniVPN CLI 连接。它主要面向 Kubernetes 工作负载：业务容器启动前先由 VPN 容器建立隧道；同时也可以作为独立的特权容器进行冒烟测试。

这个版本刻意去掉桌面、X11、VNC 和双 VPN 行为，目标是保持 sidecar 小、可预测，并且能干净退出。

## 关键行为

- 只围绕 `UniVPNCS` 运行命令行客户端。
- 每个容器只维护一个 VPN 配置。
- 支持通过 `VPN_SERVER`、`VPN_PORT` 和 `VPN_PROFILE_NAME` 自动生成配置。
- 支持通过挂载配置、`VPN_CONFIG_PATH` 或 `VPN_CONFIG_B64` 走快速启动路径。
- 健康检查基于 UniVPN 进程、隧道路由和隧道网卡状态。
- 优雅终止：`connect.exp` 捕获 `SIGTERM`/`SIGINT` 后，会向 `UniVPNCS` 发送 `q`，短暂等待断开完成；只有必要时才由 entrypoint 强制结束进程。

## 第三方安装包

仓库不包含 UniVPN Linux 安装包。构建前请把厂商提供的安装包放到 Dockerfile 同级目录：

```text
delivery/univpn-sidecar-single-vpn-minimal/univpn-linux-64-10781.18.1.0512.run
```

不要把安装包提交到 Git。仓库的 `.gitignore` 和本目录的 `.dockerignore` 默认都会排除 `*.run`。

## 环境变量

正常登录需要：

- `VPN_SERVER`
- `VPN_PORT`
- `VPN_USER`
- `VPN_PASSWORD`
- `VPN_PROFILE_NAME`

常用运行参数：

- `UNIVPN_CONNECT_TIMEOUT=120`
- `UNIVPN_MENU_SCAN_TIMEOUT=2`
- `UNIVPN_READY_POLL_INTERVAL=1`
- `UNIVPN_AUTOGENERATE_PROFILE=true`
- `UNIVPN_BOOTSTRAP_PROFILE=true`
- `UNIVPN_PROFILE_SETTLE_SECONDS=2`
- `UNIVPN_IMPORTED_PROFILE_SETTLE_SECONDS=0`
- `UNIVPN_DISCONNECT_TIMEOUT=15`
- `UNIVPN_DISCONNECT_WAIT=3`
- `UNIVPN_TUNNEL_IFACES=tun0`

可选的配置预加载方式：

- `VPN_CONFIG_PATH=/usr/local/UniVPN/config/office.ini`
- `VPN_CONFIG_B64=<base64-encoded-profile>`

## 构建

```bash
cd delivery/univpn-sidecar-single-vpn-minimal
./build.sh dev
```

默认镜像名是 `univpn-sidecar`，所以上面的命令会构建：

```text
univpn-sidecar:dev
```

如果网络环境需要，可以覆盖基础镜像或 apt 镜像源：

```bash
BASE_IMAGE=ubuntu:22.04 APT_MIRROR=http://mirror.example.com/ubuntu ./build.sh dev
```

## Docker 冒烟测试

```bash
cd delivery/univpn-sidecar-single-vpn-minimal
cp examples/.env.example .env
mkdir -p config logs

docker run -d \
  --name univpn-sidecar-test \
  --privileged \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add SYS_MODULE \
  --device /dev/net/tun:/dev/net/tun \
  --env-file .env \
  -v "$PWD/config:/usr/local/UniVPN/config" \
  -v "$PWD/logs:/usr/local/UniVPN/log" \
  univpn-sidecar:dev
```

## Kubernetes

本目录包含两个示例清单：

- `k8s-res-univpn.yaml`：独立 Deployment，并带一个示例 Secret。
- `k8s-sidecar-initcontainer-example.yaml`：initContainer/sidecar 模式，适合必须等待 VPN 路由就绪后再启动的业务容器。

容器需要：

- 特权模式，或等价的 `/dev/net/tun` 权限。
- `NET_ADMIN`
- `NET_RAW`
- 在需要设置 tun 设备或内核模块的环境中，需要 `SYS_MODULE`。
- 从宿主机挂载 `/dev/net/tun`，或由容器运行时直接提供该设备。

真实 VPN 配置应放在 Kubernetes Secret 或你自己的密钥管理系统中。示例清单只使用占位值。

## 校验

```bash
bash -n build.sh entrypoint.sh healthcheck.sh
expect -n configure.exp
expect -n connect.exp
kubectl apply --dry-run=client -f k8s-res-univpn.yaml
kubectl apply --dry-run=client -f k8s-sidecar-initcontainer-example.yaml
```

不同版本的 Expect 可能会让 `expect -n` 输出警告；如果存在语法错误，它仍应返回非零退出码。

## 运维说明

- 这个镜像按单 VPN 设计。每条 VPN 隧道使用一个容器。
- 登录耗时主要仍由服务端认证和路由下发决定。
- 如果容器被强杀后服务端保留过期会话，应优先使用正常的 Kubernetes 终止流程，让 `q` 断开逻辑有机会执行。
