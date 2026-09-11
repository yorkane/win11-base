---
name: win11-daily
description: 对 Docker 里的 Win11 实例（ghcr.io/yorkane/win11-base / win11-en）做日常操作：安装/卸载软件、打开 GUI 应用、把文件放进虚拟机、取回 guest 文件、扩 C 盘与挂数据盘、向 guest 剪贴板注入中文、跑一次性 PowerShell。当用户要求 安装 xxx / 卸载 xxx / 打开 xxx（浏览器、记事本、任意 exe）/ 保存 xxx 文件到虚拟机 / 从虚拟机拿文件 / 扩大磁盘 / 装 Chrome / 让 win11 里出现 xxx 时使用。不适用于装机、转基础镜像、多实例编排（那些走 README/AGENTS）。
---
 
# Win11 容器日常操作（装软件 / 开应用 / 传文件 / 扩盘 / 剪贴板）
 
所有子命令都在 2026-09-09 对 w11-test（全新卷）实测通过。**先定位实例，再动手**：
 
```bash
cd /path/to/docker-w11
set -a && . .env && set +a                                # 凭据只来自 .env（600）
export WIN11_SSH_PORT=10022                               # 主实例固定族；w11-test=11022，win11-en=2222
W=skills/win11-daily/scripts/w11.py
python3 $W status                                         # 先确认：控制台会话 Active、sshd Running
```
 
## 日常动作（全部预验证，直接执行）
 
| 用户说 | 执行 | 成功判据 |
|---|---|---|
| 安装 xxx | 先把包下载到宿主机（aria2c -x5），再 `python3 $W install <本地包> --skip-if <安装后必然存在的文件> --wait 300` | 输出 MARKER=hit 或 `python3 $W apps` 列出该条目 |
| 卸载 xxx | `python3 $W uninstall '<卸载表显示名子串>'` | 再跑 `apps` 不再列出 |
| 打开 xxx 应用 | `python3 $W open 'C:\\...\\xxx.exe' [参数]` | `SESS1=<非0>`（进程活在控制台会话）；最终验收 = vnc_shot 截图 |
| 保存 xxx 文件到虚拟机 | `python3 $W save <本地文件> 'C:\\Users\\<user>\\...\\名'` | `SAVE_OK`（SHA256 双向对过） |
| 从虚拟机取文件 | `python3 $W pull 'C:\\...\\名' <本地路径>` | 两边 GUESTHASH/LOCALSHA 相同 |
| 给 guest 送中文/粘贴内容 | `python3 $W clip <文本文件>`（或 `-` 走 stdin） | `CODES=` 里是文本的码点（中文会还原成 20320 这类） |
| 查装了啥 | `python3 $W apps` | NAME|VERSION|UninstallString |
| 跑一段 PowerShell | `python3 $W run x.ps1 [秒]` | 脚本自己打的键值行（别信 echo 完了就完） |
 
## 磁盘操作（全部实测，容量与镜像解耦）
 
三种动作按侵入性从低到高，优先从左往右选：
 
| 动作 | 命令 | 说明 |
|---|---|---|
| 体检 | `python3 $W disk` | DISK=虚拟盘大小 / PARTS=分区表 / GAP=yes=分区没吃满（该 --apply）|
| 扩 C 盘 | 宿主 .env 改 `WIN11_DISK_SIZE` → `docker compose -f docker-compose.base.yml up -d --force-recreate` → `python3 $W disk --apply` | dockur 只扩不缩（缩小直接报错退出）；分区扩展免重启（实测 35.7→79.7G）；要重建容器，冷启动 ~92s |
| 加数据盘（推荐） | `.env` 加 `WIN11_DISK2_SIZE=64G` → `docker compose -f docker-compose.base.yml -f docker-compose.disk2.yml up -d` → `python3 $W disk --apply` | 不碰系统盘/不重建系统卷；guest 新盘 RAW，脚本自动 diskpart 成 D:（NTFS label Data）；实测 32G→D: 31.9G |
 
要点：
 
- **数据盘放宿主大分区**：在 override 里把那条卷换成 bind `[/data/w11disk2:/storage2]`（宿主大分区空闲；qcow2 可增长，用多少占多少）。
- **最多 6 块**：dockur 认 `DISK2_SIZE..DISK6_SIZE` + `/storage2..6`（/run/disk.sh），每块一个卷。
- **qcow2 只增不减**：guest 里删文件不会释放宿主空间；要回收得 zero_free 后借底座容器 qemu-img convert 重压（README.md）。
- RAW 盘初始化 = SYSTEM 一次性任务跑 diskpart（Tiny11 无 Init-Disk/New-Partition cmdlet，SSH 令牌又被 UAC 过滤）。一次只初始化一块 RAW 盘（NOTE=multiple-raw-disks 时再跑一轮）。
- **只碰 RAW 盘**：已初始化的盘报 `DISKS=all-init` 空转，绝不改带分区的盘；缩容=宿主删卷，先确认 guest 无数据并向用户报告。
- `disk --apply` 可能 >30s（格式化+日志回读）：宿主侧按红线 6 后台化跑。
- 卷名前缀=compose 项目名（主实例 `w11-13389_win11-storage*`；`-p w11-test` → `w11-test_win11-storage*`），并行实例改端口族别丢 `-p`。
## 只有实测才知道的红线（脚本已封住，改脚本前必读）
 
1. **文件传输 = scp（SFTP 模式，路径用正斜杠）**。基础镜像实例没有 SMB：`\\host.lan\\Data`
   只有挂了 ./shared 的老装机实例才有，新实例脚本靠它取包 = STAGED=False + msiexec 1619（实测）。
   带 `-O`（legacy 协议）会报 `protocol error: filename does not match request`；guest 路径反斜杠会被当转义符。
2. **GUI 必须经 Interactive 一次性计划任务起**（principal=控制台自动登录用户）。sshd 子进程和
   SYSTEM 任务都在 session 0，`Start-Process` 起的窗口永远看不见。打开类任务不能等它结束——
   任务要等应用退出才结束（RESULT=267009 = still running，不是失败）。
3. **机器级 .msi 一律交给 msiexec**（直接把 .msi 路径起进任务 = 弹 GUI 安装向导；.msi 路径直跑
   是本项目微信事故的同款坑）。w11.py 已自动路由；UAC 过滤的 SSH 令牌装不了机器级 msi，
   `--system` 走 SYSTEM 一次性任务。NSIS 类（setup.exe /S）反而必须走登录用户 Interactive，
   否则快捷方式/注册表落进 SYSTEM profile。
4. **一次性计划任务的 tag 必须带 pid**：两个 agent 并发跑同名任务时，先退出的那个会把别人
   刚注册的任务注销掉（实测互相抢，安装凭空消失）。
5. **guest sshd 会限流**：scp 被中途杀死（Ctrl-C / 宿主会话回收）之后，新连接会在 kex 阶段被拒
   （kex_exchange_identification）。等 1-2 分钟或 `docker restart -t 120`（同卷重启 ~81s），
   别急着重装/改密。
6. **宿主侧跑 >30s 的子命令要后台化**：exec 会话 30s 截断，python 输出块缓冲 = 看不到中间进度。
   `setsid sh -c "timeout N python3 -u $W ... > /tmp/x.out 2>&1" &` + 轮询文件。
   长安装的 --wait 预算按包体大小给（159 MB Chrome 级 ≥ 300s）。
7. **session 0 的剪贴板是另一个站点**：`clip` 走 Interactive 任务 + 脚本自写日志（任务 action 带
   `> 同一日志` 的重定向会让那次写变成 0 字节，实测）。
8. **装完 ≠ 装好**：判据 = `apps` 有条目 或 marker 命中；起没起窗口 = `SESS1=` 或截图。
   看桌面永远用 vnc_shot（仓库版写死 8006，多实例先改端口），
   **绝不用 RDP 截图**（一连就锁屏抢控制台）。
 
## 装 Chrome 这类大包
 
`install <ChromeEnterprise.msi> --skip-if 'C:\Program Files\Google\Chrome\Application\chrome.exe' --wait 600`；
基础镜像本身自带 Chrome 注入（README.md），**先 `apps` 看是不是已经有了再装**。
打开直接 `open 'C:\Program Files\Google\Chrome\Application\chrome.exe' --new-window <url>`；
页面级任务不走 GUI，用 CDP：`playwright-cli attach --cdp=http://127.0.0.1:19222`（README.md）。
 
## 与既有体系的关系
 
- 装机 / 转基础镜像 / 多实例编排 / 桌面形态阶梯 → README/AGENTS.md。
- 本项目注入器已把 Chrome/CDP/剪贴板桥做成出厂能力，日常操作**不需要**再碰注入器。
- 看图：`vnc_shot.py ws://127.0.0.1:<vnc口>/websockify /tmp/x.png`，再在 exec isolate 内 `await tools.view_image({path})`。
