# 个人自部署 Web

本目录将 Go 服务和前端资源打包成一个容器，SQLite 保存实例的任务事实。首期只支持一位 owner、多设备在线访问；当前功能和未完成门禁见[实施记录](../../docs/tasks/noonmark-web-self-hosted/README.md)。

## 从源码构建

Linux 开发机需要 Go 1.27.0、Node 22.22.3、npm 10.9.8、GCC／静态 libc、Python 3、bubblewrap、Docker BuildKit。源码保持在当前 checkout；本机 `.work` 指向 `/share/broker/noonmark-build`，其他机器须在运行前设置独立绝对路径 `NOONMARK_WORK_ROOT`。

```bash
set -euo pipefail
source scripts/web/env release-validation
scripts/web/package
export NOONMARK_IMAGE="$(cat "$NOONMARK_BUILD_ROOT/image.txt")"
```

`package` 先执行锁定依赖安装、Go static build、TypeScript 检查和 Vite build。Go 与前端构建时，源码挂载为只读，只有外置根可写。Dockerfile 使用三个 named build contexts 读取编译产物、前端资源和 CA bundle；BUILD 中没有应用源码副本，镜像不含编译器。每轮 `manifest.json` 记录源码内容 hash 和产物 digest，源码在构建中变化会阻断结果。

本入口只创建本地 `noonmark-local` 镜像，不推送 registry。Compose 没有虚构的公开镜像默认值，`NOONMARK_IMAGE` 必须显式提供。

## 初始化隔离体验实例

以下例子使用本轮新建资料，适合开发验收。正式实例应由操作者选定专用数据目录，不能复用测试 run。

```bash
export NOONMARK_DATA_DIR="$NOONMARK_RUN_ROOT/databases/instance"
mkdir -m 700 "$NOONMARK_DATA_DIR"
export NOONMARK_UID="$(id -u)"
export NOONMARK_GID="$(id -g)"
if docker info --format '{{json .SecurityOptions}}' | python3 -c 'import json,sys; sys.exit(0 if "name=rootless" in json.load(sys.stdin) else 1)'; then
  export NOONMARK_UID=0 NOONMARK_GID=0
fi
export NOONMARK_PUBLIC_ORIGIN=http://127.0.0.1:8080

read -r -s -p 'Owner password: ' noonmark_owner_password
printf '\n'
printf '%s\n' "$noonmark_owner_password" | docker run --rm -i \
  --read-only --user "$NOONMARK_UID:$NOONMARK_GID" \
  --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --mount "type=bind,src=$NOONMARK_DATA_DIR,dst=/data" \
  "$NOONMARK_IMAGE" init --data-dir /data --timezone Asia/Singapore --password-stdin
unset noonmark_owner_password

docker compose -f deploy/self-hosted/compose.yaml -p "noonmark-$NOONMARK_RUN_ID" run --rm --service-ports noonmark
```

密码通过 stdin 传入，命令参数及 Compose 配置不含默认凭证。rootful Docker 使用数据目录 owner 的非 root UID／GID。rootless Docker 使用 `NOONMARK_UID=0`、`NOONMARK_GID=0`，让 namespace 内的 UID 0 映射到宿主非特权用户；该模式的容器进程 UID 确实为 0，镜像默认身份仍为 `65532:65532`。两种模式均保留 `cap_drop: ALL`、`no-new-privileges` 与只读 rootfs，不执行递归 `chown`。共享目录必须提前存在，Compose 不自动创建它。

页面从 `http://127.0.0.1:8080` 打开。Docker bridge 将宿主 loopback 连接转换为网关来源时，还须通过 `NOONMARK_TRUSTED_PROXY` 显式信任这个实际网关的单地址 CIDR，且保留宿主端口的 `127.0.0.1` 绑定；不得配置任意来源 CIDR 来放宽认证传输边界。

LAN／公开访问须配置 HTTPS 反向代理，将 `NOONMARK_PUBLIC_ORIGIN` 改为浏览器使用的完整 origin，并用 `NOONMARK_TRUSTED_PROXY` 指定代理实际来源的 CIDR。未配置 TLS 或受信代理的 HTTPS origin 会被拒绝启动。SQLite volume 必须具备可靠的本机文件锁及 fsync 语义，不得放在同步目录或网络文件系统。测试机使用 virtiofs 的通过证据，只证明该测试环境的进程崩溃行为。

## 验证与运行边界

```bash
scripts/web/check
```

该入口要求路径／只读源码守卫、实际文件系统探针、Go vet／race tests、前端构建、镜像打包及真实浏览器 E2E 全部成功。缺少浏览器、Docker、测试入口或依赖时失败。CI 使用 GitHub-hosted Linux runner，独立于原生 macOS 工作流；不据此声称 Mac App、format 7 或多架构发行已验收。

`/data` 是唯一实例持久目录，`/tmp` 是临时 tmpfs，镜像 rootfs 只读。不要把运行中的 SQLite 目录直接复制当作一致备份；备份和恢复必须走 CLI，并按当前实现的恢复条件停止写入。测试结束只处理本轮带 UUID 的容器和数据，不执行全局 Docker prune。
