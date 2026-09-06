# docker-w11

在 Docker 里跑 Windows 11 虚拟机（底座 [dockurr/windows](https://github.com/dockur/windows)）。
本仓库同时管两件事：一台自建安装实例（装机 + OEM 首登自动化），以及一个开箱即用的基础镜像
[ghcr.io/yorkane/win11-base](https://github.com/yorkane/win11-base)（装好的盘烘进镜像，新容器直接进桌面）。

> 动手前先读 [AGENTS.md](AGENTS.md)（工具入口、转义四层链、判读标准、禁止事项）。
> 部署实录：[deploy.md](deploy.md)（唯一文档：装机、操控、瘦身转基础镜像、.env 注入、桌面形态）。
> 可复用代码与脚本已抽成技能 win11-docker（`~/.codex/skills/win11-docker/`）。

## 两种用法

### 1）要一台干净的 Win11（推荐）：基础镜像 + .env

`docker-compose.base.yml` 拉起 `ghcr.io/yorkane/win11-base:latest`，不跑安装程序，约一分钟后直接进桌面。
账户名、密码、KMS 全部来自本机 `.env`，镜像里不含任何密钥：

    cp .env.example .env      # 填真实值
    chmod 600 .env
    docker compose -f docker-compose.base.yml up -d

    ssh <WIN11_USER>@127.0.0.1 -p <WIN11_PORT_SSH>   # 落地就是 PowerShell

端口不填就是**固定入口族**（= 标准端口 +10000）：RDP 13389、noVNC 18006、SSH 10022、
Chrome CDP 19222（仅宿主回环），容器名 w11-13389。要一台端口再 +1000
偏移、独立卷的固定测试机：

    docker compose --env-file .env.test -f docker-compose.base.yml -p w11-test up -d

改密码后要生效：`docker compose -f docker-compose.base.yml up -d --force-recreate`。注入只在容器启动时
跑一次，只改 `.env` 不重建不会生效；值没变则整轮 no-op、不重启。

### 2）自建安装实例（win11-en：装机 + OEM 首登自动化）

`docker-compose.yml` 挂 `./data`（含 `custom.iso`）与 `./oem`：首次启动走无人值守安装，
首登自动执行 `oem/install.bat`（KMS 激活、纯黑桌面、OpenSSH Server）。安装期账户用 `.env` 里的
`WIN11_INSTALL_USER`/`WIN11_INSTALL_PASSWORD`，与运行期注入的 `WIN11_USER`/`WIN11_PASSWORD` 是两套，别混。

    bash scripts/start.sh

## 密钥：只用 .env

`.env` 只留在本机（600 权限），`.gitignore` 已排除；仓库只提交 `.env.example` 占位模板。
`docker-compose.base.yml` 把 `WIN11_USER`/`WIN11_PASSWORD` 用 `${VAR:?}` 标成必填：缺 `.env` 直接失败，
不会用镜像里那个公开初始密码把机器起起来。端口、内存、CPU、容器名都是 `${VAR:-默认值}`，
多实例并行只改 `.env`、不动 compose 文件。

| 变量 | 用途 |
| --- | --- |
| `WIN11_INSTALL_USER` / `WIN11_INSTALL_PASSWORD` | 安装期账户（dockur answer file，仅自建安装实例） |
| `WIN11_USER` / `WIN11_PASSWORD` | 运行期注入 guest 的账户与密码（必填） |
| `WIN11_INIT_USER` / `WIN11_INIT_PASSWORD` | guest 盘当前生效的初始凭据，默认 aigc/aigc |
| `WIN11_KMS` / `WIN11_KMS_KEY` | KMS `host[:port]` 与可选 GVLK；留空则跳过激活 |
| `WIN11_RAM_SIZE` / `WIN11_CPU_CORES` | VM 资源 |
| `WIN11_PORT_VNC` / `WIN11_PORT_RDP` / `WIN11_PORT_SSH` / `WIN11_PORT_CDP` | 宿主端口覆盖：**默认不设**，默认值就是固定入口族（RDP 13389 / noVNC 18006 / SSH 10022 / CDP 19222）；在这里写它们会覆盖约定（deploy.md 6.9） |
| `WIN11_CONTAINER_NAME` | 容器名与主机名，默认 w11-13389 |
| `WIN11_GUEST_IP` / `WIN11_INJECT_TIMEOUT` | 跳过 guest 发现 / 注入等待秒数 |
| `WIN11_DESKTOP` | 桌面形态：默认 on（纯黑+无图标+任务栏常显、图标左对齐、无搜索框、无商店图钉），off 保持原生桌面 |

## 目录

    docker-w11/
    ├── .env.example              # 密钥模板（提交）；.env 是本地真实值（不提交）
    ├── docker-compose.base.yml   # 基础镜像：纯注入，命名卷收种子盘
    ├── docker-compose.yml        # 自建安装实例 win11-en
    ├── image/                    # 基础镜像构建上下文（Dockerfile + win11-inject.sh + start.sh + seed/）
    ├── repo/                     # ghcr 镜像公开仓库的工作副本
    ├── oem/                      # -> VM C:\OEM，首登自动化
    ├── shared/                   # SMB 双向：VM 内 \\host.lan\Data
    ├── data/                     # win11-en 的 /storage（custom.iso、磁盘、windows.* 状态）
    └── scripts/                  # 宿主侧工具（截图、清理、转基础镜像）

## 操作要点

- 进 VM 跑命令只有一条可靠通道：`python3 ~/.codex/skills/win11-docker/scripts/psx.py <ps1> [秒]`
- 一次性验收：`psx.py ~/.codex/skills/win11-docker/scripts/verify.ps1`（激活、纯黑桌面、sshd、activate.bat）
- 目视验证只用 `scripts/vnc_shot.py`；别用 RDP 截图（一连就抢占控制台、把桌面打到锁屏）
- 停机保留 2 分钟优雅期，强杀可能损坏 NTFS；`windows.*` 是安装态身份，删了会触发重装
- 把运行中的实例固化成基础镜像：`bash ~/.codex/skills/win11-docker/scripts/to_base_image.sh [实例目录]`
