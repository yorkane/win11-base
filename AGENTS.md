# AGENTS.md — docker-w11 项目作业守则

> 只写这个仓库里踩实过的坑，目的是让下一次不再重复犯错。
> **可复用代码已抽成技能 `$win11-docker`（`/home/aigc/.codex/skills/win11-docker/`）**：远程 PowerShell 三合一入口 `scripts/psx.py`、后台任务、zero-fill、OEM 首登脚本、转基础镜像脚本都在那里。本文件与技能内 `references/pitfalls.md` 保持同步，规则以技能为准。
> 环境事实与部署步骤在 `deploy.md`（唯一部署文档：两条部署路径、装机、通道、排障、瘦身转基础镜像、部署时注入、.env、桌面形态验收）与 `win11_init.md`（桌面形态的完整实测与被证伪路线）；本文件不重复它们，只规定**怎么调用工具、怎么转义、从哪里进系统、怎么装东西**。
> 全局规则（中文回答、Docker 多核构建、NAS 共享等）见 `/home/aigc/.codex/AGENTS.md`，本文件是它的项目级补充。

## 1. 工具调用：先分清宿主还是访客机

| 目标 | 唯一正确入口 | 不要用 |
|---|---|---|
| 宿主机 shell（docker、qemu-img、文件、compose） | `exec_command` | 不要在 JS 里假设能直接摸 VM 文件系统 |
| 本地任何文件的新建与修改 | `apply_patch`（宿主执行，不落 shell） | `cat`/heredoc/JS 模板字符串拼文件 |
| **Win11 虚拟机内**执行命令 | `python3 ~/.codex/skills/win11-docker/scripts/psx.py <ps1> [秒]`（SSH + EncodedCommand；`--bg --tag` 转 SYSTEM 后台任务，`--status TAG` 查进度）。仓库内 `scripts/pssh.py` 是其同步模式前身 | 直接 `ssh ... 'powershell -Command ...'` |
| Win11 里传文件 / 回收日志 | SMB：宿主 `shared/` = VM `\\host.lan\Data` | VM 内的 `Z:` 盘符（脚本上下文里不可靠） |
| 必须点 GUI 才有结果的操作 | `scripts/agent-run.sh z.bat`（midscene RDP + 视觉模型） | 键盘盲打长文件名 |
| 目视验证桌面 | `scripts/vnc_shot.py` 生成 PNG，再在 exec 内 `await tools.view_image({path})`（约 1s 出全帧） | 顶层调用 view_image；把 base64 塞进命令输出；**用 RDP 截图看桌面**（见 §1.3） |

### 1.1 看图（本轮真实教训）

- `view_image` 只能作为 exec isolate 内的嵌套 helper：`await tools.view_image({ path: "/tmp/x.png", detail: "high" })`，或把已在手的数据 URL 交给 `image(...)`。
- 顶层直接发 `mcp__codex_app__view_image` 会得到 routed provider emitted undeclared client tool —— 因为该名字不在当轮工具清单里；不要重复尝试。
- **绝不**用 `exec_command` 输出 base64 再拼图片：会被 max_output_tokens 截断，表现为 image content omitted。要缩小就先 `PIL.thumbnail` + 存 jpg。
- `detail` 只接受 `high/original/auto`，`low` 会被拒。

### 1.2 exec 单元本身

- exec 里裸 `await tools.xxx(...)` 的返回值会被丢弃，必须 `text(...)` 或 `notify(...)` 主动吐出来；看到空输出先怀疑自己漏了 `text(...)`，而不是命令失败。
- 不要在同一单元里混用 `exec_command` 与 `apply_patch` 去写同一个文件：`apply_patch` 是宿主执行的，语义上应先写后用。
- 独立读操作要并行发，别串成三次往返；写操作必须串行。
- 长任务不要用阻塞 sleep 超过 60s，改成多次短轮询或 `wait`。

### 1.3 截图通道：VNC 用于观察，RDP 截图只属于操控链路（实测结论）

| 通道 | 实测结论 |
|---|---|
| **VNC**（`scripts/vnc_shot.py`） | 单次约 **1s** 出 1280x800 全帧 PNG。一条 websocket 做 RFB 握手 + FramebufferUpdate，只依赖 `websocket` + `PIL`，不需要 X / xvfb / 凭据；**零副作用**，不建会话、不动输入 |
| **RDP 截图** | 宿主机 **走不通**：Ubuntu 22.04 只有 FreeRDP **2.6.1**，而 rdp-helper 要 libfreerdp3/libwinpr3，实测 rc=23 退出。要跑得进 FreeRDP3 容器（Ubuntu 24.04，即 midscene 镜像存在的原因），再叠 xvfb + 凭据 + 证书绕过：一张图套四层基础设施。**别照旧文档找 `/screencapture:`**：该参数与 `/auth-level:` 在 FreeRDP 任何版本都不存在（2.6.1、3.31.0、Debian trixie manpage、上游 master 参数表四处实测 0 命中），rc=23 只是参数不识别；截图由 rdp-helper 自己实现，升级 FreeRDP3 拿不到这条能力（细节见 deploy.md §7.2） |
| **midscene RDP 链路** | 它本来就需要活动 RDP 会话来注入鼠标键盘，截图是顺带产物；截图与操控一体，不值得为纯观察复制这套 |

选择规则：

1. **只是看一眼**（验证壁纸、装完机确认）-> VNC。
2. **必须点 GUI 才能完成任务** -> midscene RDP 链路。
3. **无 GUI 的状态判断** -> 两者都不用，`psx.py` 回读注册表 / 服务判据。

**观测污染警告**：RDP 一连上就抢占控制台，控制台会话转为锁屏（`quser` 显示 `Disc`），此后 VNC 看到的必然是锁屏图。所以**绝不要用 RDP 截图去验证桌面外观**，那是先污染再观测：也正是之前把蓝色锁屏误判成壁纸没生效的根因。

### 1.4 midscene 操控：慢的不是截图，是模型调用（数字与复现脚本见 midscene-test/README.md）

截图侧实测只有 4-7ms（task-runner 的 reuse cached uiContext），时间全在模型调用上。三条杠杆按收益排序：

| 杠杆 | 做法 | 依据 |
|---|---|---|
| 别把动作交给模型规划 | 滚动用 aiScroll(locate, {direction, scrollType, distance})、点命名目标用 aiTap(prompt, {deepLocate:true})，不要用 aiAct | 模型规划出来的结果就是同一次 aiScroll（midscene_run/cache 的 plan 里能看到原文），却要多付一次带截图的规划调用；且 aiAct 的 plan/replan 循环在 MIDSCENE_REPLANNING_CYCLE_LIMIT=3 下会跑出 rc=1 |
| 用对思考开关 | MIDSCENE_MODEL_EXTRA_BODY_JSON 传 chat_template_kwargs.enable_thinking=false | llama.cpp 忽略顶层 enable_thinking，而 midscene 的 qwen3 路线发的正是顶层字段：顶层传 false 仍 10.1s 照旧思考，放进 chat_template 才 3.3s |
| 少发截图 | 重复任务开 MIDSCENE_CACHE=true；一次 aiQuery 读整屏而不是逐行问 | 该网关按图片张数计 token（纯文本 13 / 一张 255 / 三张 739），不随分辨率变（274/262/274），所以省的是张数；缓存的是 plan，界面变了要先挪走 midscene_run/cache 再计时 |

思考档位不是越开越准，方向取决于让它干什么：读像素时关思考会错行和编造（对照 midscene-test/groundtruth/ 的同几何真帧：「小天 @滨江物业」读成半个「小天」、「链家 阿康…」读成「阿童…」、凭空造出一行「测试 1235」——那是别的会话的预览）；点界面时关思考会点空（drill 连三页 bubbles=0、title 为空，deepLocate 补不回来）。所以只读的 run-wx-recent.sh 默认 off、必须点击的 run-wx-drill.sh 默认 reads（aiQuery 与 aiTap 同走 insight 槽）。

默认不选最准那一档的原因：网关共享，思考类调用会排到约 22s 上限并被 APISIX 边缘 504——开思考的运行至少吃一次 504、其中两次重试用尽直接死掉，关思考的运行 504 次数为 0。跑不完的速度不是速度。要精度显式 THINKING=reads|all。

DESKTOP_SIZE 固定 1280x800 是正确性措施（操控 / VNC 观测 / 模型输入共用同一几何），不是省 token。验证只能在设备侧做：RDPDevice.size() 加上抓 PNG 读 IHDR；报告 HTML 内嵌 1920x1080 与 1788x500 的模板素材，照它判断会得出「固定没生效」的错误结论。

## 2. 转义：四层链，任何一层都可能吃掉字符

链路：`JS 字符串 → apply_patch/exec_command → bash → cmd/bat → PowerShell 5.1`。规则：

1. **apply_patch 语法**：*** Add File: 路径 之后**每一行正文都必须以 + 开头**（漏了就是 invalid hunk header）；*** Begin Patch / *** End Patch 这两行本身不带 +。Update File 用 @@ 定位块，正文行前缀是空格、删除行前缀是 -。
2. **JS 侧**：模板字符串里出现内容自带的反引号会提前结束字符串（报 Unexpected token : / Unexpected identifier）；Buffer 在 isolate 里不存在（ReferenceError: Buffer is not defined）；String.raw 遇到内容里的反引号、${ 、以及行尾反斜杠都会炸。
3. **稳妥写法**：内容先进 JS 数组（每行一个普通字符串，反斜杠写两份），反引号用占位符 @BT@ 写、join 之后 split(占位符).join(反引号) 还原；或直接用 String.raw 且内容不含反引号/行尾反斜杠。本次 deploy_init.md、clean1.ps1、clean2.ps1、AGENTS.md 都是这么落盘的。
4. **bash 层**：单引号里的 `$VAR` 仍可能被外层 shell 展开，`$( )` 与反引号会执行。需要保真一律走 `apply_patch` 写文件、只让命令去执行文件（这也是全局规则的要求）。
5. **PowerShell 层**：单引号是字面量，UNC 路径这种要拼的东西用 `双引号` 或 `[char]92` 显式拼（见 `scripts/clean2.ps1`）；`'\\host.lan\Data'` 在脚本里写成字面双反斜杠即可，别在四层里再叠。
6. **PowerShell 数组元素里禁止裸 `+` 续行**（真实事故）：`@('a',` 换行后 `+ 'b')` 被解析成两个独立元素，拼出来的 bat 变成一行一个片段，`cmd /c` 于是把安装器**无参数**执行 —— 症状是微信安装器弹出 GUI 协议窗、`/S` 形同不存在、cmd 窗口显示 `'\"\"' is not recognized ...`。拼接段一律加括号（`psx.py` 的 BOOTSTRAP 就是这么写的），生成 bat 后回读校验：`Get-Content $bat | % { Write-Output ('BATHASHTAG[' + $_ + ']') }`。

## 3. 进 VM 跑 PowerShell：只有一个正确姿势

```
cd /home/aigc/ChatGPT/docker-w11 && python3 scripts/pssh.py scripts/xxx.ps1 270
```

`scripts/pssh.py` 已经把坑都封住了：去 UTF-8 BOM、LF 转 CRLF、utf16le + base64 走 `powershell -NoProfile -NonInteractive -EncodedCommand`。原因：

- `ssh ... 'powershell -Command "...$x..."'` 会被 bash 先展开成空串；
- EncodedCommand 对 BOM 和 LF 敏感，报输入不能为空/格式不正确；
- CLIXML 进度噪声出现在 stderr，用 `grep -E` 挑自己 `Write-Output` 的键值行，别把 stderr 当失败依据；
- Windows 侧是 **PowerShell 5.1**：`&&` 不存在，用换行或分号；`&&` 报错时先怀疑自己写了 bash 语法；
- `&&` 之外，`winhttp.exe` 不在 PATH（要用完整路径或 `netsh winhttp show proxy`）；`Measure-Object Length` 对空集合会抛属性找不到，`Purge` 里已用 try 容忍。

### 3.1 超过几十秒的脚本必须后台化

- 症状：SSH 同步执行到点超时、输出为空（实测：递归统计 `C:\Windows\WinSxS` 直接卡死，`/tmp/probe2.out` 为 0 字节）。
- 做法：`Register-ScheduledTask` 以 `SYSTEM` + `RunLevel Highest` 起任务，日志写 `C:\Windows\Temp` 再 `copy` 到 `\\host.lan\Data`，宿主侧 `scripts/checkclean.ps1` 轮询。参考 `scripts/clean2.ps1`（DISM ResetBase 就是这么跑完的）。
- 好处：顺带拿到提升令牌，绕开 SSH 令牌被 UAC 过滤导致的 Access is denied。

## 4. 装东西：先认清死路，再选包源

| 需求 | 结论 |
|---|---|
| OpenSSH Server（FOD capability） | `Add-WindowsCapability` / `DISM /Add-Capability` 在本实例不可用：provision 期 `0x80072ee6`（容器内透明代理干扰 FOD 源），SSH 管理员会话重试 `Access is denied`（令牌被 UAC 过滤）。**改用微软官方便携包 Win32-OpenSSH**，`sshd.exe /install-sshd` 注册服务，效果等价，别再重试 capability 路径 |
| 校验 ssh 是否真可用 | `Get-WindowsCapability` 显示 `NotPresent` 是**正常**的（服务不是 FOD 装的）；判据是 `Get-Service sshd` = Running/Automatic + 真跑一次远程 PS 脚本 |
| 第三方软件 | v11 起镜像自带 **Chrome Enterprise**（离线 MSI + HKLM 策略，`WIN11_CHROME=off` 关）；除此之外零第三方软件。卸载表允许：WebView2 Runtime（系统组件，别删）、Google Chrome（含 Google Update 服务）。多装别的先问 |
| 装带 GUI 的第三方软件（微信等） | 分两步：SYSTEM 后台任务从 SMB 取包，再注册 `LogonType Interactive` 的计划任务以登录用户身份跑 `/S`。SYSTEM 装会把 `.lnk` 与 HKCU 注册项落进 SYSTEM 配置；SSH 子进程在 session 0，启动的 GUI 永远看不见。见 `../docker-w11-wx/scripts/wx_install.ps1` |
| 宿主机缺 qemu-img | 借镜像：`docker run --rm -v $PWD/data:/store --entrypoint sh dockurr/windows:latest -c 'qemu-img convert -c -O qcow2 ...'`（版本 11.1.0）。别为了转格式在宿主装 qemu-utils |
| 下载模型/视频素材 | 走全局约定的技能与代理：模型用 hf-download（ModelScope 优先，限流要退避），视频用 ytb；本机 HTTP 代理 `127.0.0.1:7890`。单文件 aria2c 至少 5 并发并核对文件名 |
| 联网续期 | KMS 每 7 天续期；容器出网断了就手动跑 `C:\activate.bat`，别重装系统 |

## 5. 入口与状态文件（改错就重装/进不去）

- `oem/` = VM `C:\OEM`，首登自动执行 `install.bat`，是安装期**唯一**自动化入口；改 `provision.ps1` 后必须重跑或手工 copy 进 VM 才生效。bat 必须 CRLF。
- `data/` = VM `/storage`：`custom.iso`（安装源，改名会被探测逻辑忽略）、`data.img`（数据盘）、`windows.base/mac/rom/ver/vars`（安装态身份）。**删 windows.* 等于宣告未安装，会触发重装。**
- `data.qcow2` 与 `data.img` 二选一：存在 `data.qcow2` 时 dockur 自动切 `DISK_FMT=qcow2`（已读 `/run/disk.sh` 证实），不需要额外环境变量。
- `windows.boot`（0 字节空文件）才是“已装完”的真正判据：`needsInstall() = hasData && hasBootMarker`。它只在**优雅停机**时由 `markWindowsBooted()` 创建，自定义 ISO 下启动时不会创建。**转基础镜像必须显式带上它**，否则新容器可能重装。
- 端口：宿主 22 被宿主 sshd 占，VM SSH 只能发布 `2222`；转基础镜像做多实例时端口必须参数化。dockur 的 NAT 会把非保留端口 DNAT 进 VM，别乱加映射。
- 停机：`stop_grace_period: 2m` 必须保留，`docker compose down` 优雅关机最长约 2 分钟；强杀可能损坏 NTFS。转换/打包前先 down。
- 备份纪律：换盘用 `mv` 归档进带时间戳的 `backup-win11-*/` 而不是删除；归档目录确认过期后要删，必须先对每个大文件做 `cmp` 证明与在用件/种子/原始 ISO 逐字节相同（或回退能力已由 ghcr 镜像 + `/data/iso/` 覆盖），并向用户报告后再删。2026-09-04 已按此流程清空全部 `backup-*`（释放约 44G），当前项目不保留备份盘。
- 转基础镜像：`FROM dockurr/windows:latest` + `COPY seed/ /storage/`。`/storage` 是 VOLUME，靠**卷种子**（镜像层内容在首次建卷时被复制）生效，因此必须实测新容器是否**直接引导进桌面、跳过安装**，不能只看构建成功。
  - 实测结论：seed 只要 `data.qcow2` + `windows.base/boot/mac/rom/vars/ver`，**不放 custom.iso**（可省 3 GB，`needsInstall` 会打印 custom .iso removed 并判定不重装）。9.1G 稀疏 raw 压成 4.99G qcow2，镜像 `win11/base:latest` 共 5.56G，新容器直接进桌面。
- 宿主侧长任务别用 `nohup ... &`：exec_command 会话退出会把它杀掉（实测 qemu-img convert 停在 5.0G）。改用 `docker run -d` + 容器写状态文件 + 宿主轮询。

## 6. 判据与证据：别把观感当结论

- 一条命令回读全部判据（`/tmp/verify1.ps1`）：`LICENSE=1`、`WALLPAPER=[] STYLE=10/0`、`BGCOLOR=0 0 0`、`ACTIVATE.BAT=True`、`SSHSVC=Running/Automatic`、`WALLFILES=0`。注册表判据优先于截图观感。
- **锁屏陷阱**：`quser` 显示 `Disc` 说明控制台被 RDP 抢占并已锁屏，此时截图是蓝色锁屏图，**不代表壁纸没生效**。解锁/重启后再判读；要连锁屏图一起去掉，设 `NoLockScreen=1` 与 `ContentDeliveryManager` 全 0。
  - 顺带一条硬规则：**验证桌面外观只能用 VNC 截图**，不要用 RDP（RDP 一连就制造出这个锁屏，见 §1.3）。
- 磁盘体积三件套分开看：`du -sh --apparent-size`（表观 36G）、`du -sh`（实占 9.1G）、VM 内 `Get-PSDrive C`（NTFS 已用 11.4G）。`Test-Path C:\pagefile.sys` 对系统文件返回 False，但 `Get-ChildItem C:\` 会列出它——别据此断言页面文件已关。
- `powercfg /h off` 立即让 `hiberfil.sys` 消失；关页面文件必须重启才释放。

## 7. 凭据、KMS 与镜像发布

- 镜像里不许出现明文口令或私人 KMS 地址：账户名、密码、KMS 一律走 `docker run -e WIN11_USER / WIN11_PASSWORD / WIN11_KMS[_KEY]`，由 `image/win11-inject.sh` 在启动时推进 guest。种子盘那个 aigc/aigc 只是首登钥匙（等同 dockur 自带的 admin/admin），别把它当成这台机器当前的密码写进文档或脚本。
- 改 dockur 镜像的启动行为只用它留的口子：`/run/start.sh` 钩子（`entry.sh` 第一件事就 source 它）。钩子里跑长任务必须后台 `&`，否则会把 qemu 启动一起堵住。别改 `/run/*.sh` 里的其它文件，升级底座时全会被覆盖。
- 桌面形态（v11 定稿：纯黑/无图标/任务栏**常显**+左对齐+无搜索+无商店图钉）做在**注入器层**（`image/w11_desktop.ps1` + `tb_ensure_shown.ps1` 推到 C:\ProgramData\w11，注册 `w11DeskHide` 登录任务并立即触发；`WIN11_DESKTOP=off` 关）。TaskbarAl/搜索/NoDesktop 是注册表（永久）；常显开关是运行态，每次开机重放。别烘注册表 hive 或种子盘：任务又是 HKLM+交互会话对象，只能每台 VM 由注入器注册。**SSH（UAC 过滤令牌）实测能注册并触发 Interactive/Highest 计划任务**，不必借 SYSTEM。TaskbarAl 语义 **0=左 1=中**（微软文档；写反一次的教训）。商店图钉：TaskbarDa 在 26100 上不生效（实测），有效路线 = Shell.Application → shell:AppsFolder → WindowsStore 的 Unpin verb DoIt()。任务栏判据只认像素（deploy.md §6）。
- Chrome CDP（v12）：chrome >=136 **拒绝把 DevTools 绑到非回环**（`--remote-debugging-address=0.0.0.0` 静默无效，实测），正确架构 = chrome 绑 `127.0.0.1:9223` + 提权任务下 `netsh portproxy` 拥有 `0.0.0.0:9222`；WS 必须 `--remote-allow-origins=*`；调试端口不许落在默认 profile（`--user-data-dir` 专用目录）。常驻 = w11CdpChrome（Interactive/Highest，ExecutionTimeLimit 0，脚本自带 supervisor 循环）。权威判据 = 容器侧 tcp + HTTP `/json/version`，guest 内回环探测看不见 portproxy 那层的防火墙判定。详见 deploy.md §6.7。
- 注入的每一步都要写完读回来，且只用可信数据源：`if ($?)` 会被前面任何 `-ErrorAction SilentlyContinue` 的失败打成 false（本项目据此误判过自动登录没写进去）；`cscript //b slmgr.vbs /dli` 在非控制台管道里一个字符都不吐，激活状态只能用 `Get-CimInstance SoftwareLicensingProduct` 的 `LicenseStatus`（1=已授权）判。
- 从 guest 读回来的字符串先 `tr -d '\r'` 再比较。Windows 回 CRLF，命令替换只吃换行不吃回车符，于是精确等值比较永远失败而子串 grep 一切正常；这类 bug 只会表现为明明成功了却每轮重复执行。
- 传给 guest 的值先过字符白名单，再动任何写操作；白名单用 `grep -qE '^[A-Za-z0-9._@-]+$'`（正则写死成字面量、值走 stdin）。bash `case` 的字符类不能从变量取允许集：引号包住的 `A-Z` 在字符类里只匹配字面 A、-、Z，正常用户名反而被拒绝。
- 发布前核对 digest，并确认真的去重：种子层显示 `Layer already exists` 时一次只上传几 MB。改 Dockerfile 时把 `COPY seed/` 放最前、易变层放最后，否则每次改动都要重传 5 GB。
- GHCR 包可见性改不动：REST 一律 404，仓库 public 不等于包 public。要么让用户在包 settings 页手工切 Public，要么用 `gh auth token | docker login ghcr.io -u <user> --password-stdin` 登录拉取。别反复重试 API，也别用 UI 自动化去点（webview attach 不上）。
## 8. 本地密钥：只用 .env

- 宿主侧一切密钥/主机地址只写 `.env`（模式 600），提交 `.env.example`（占位值）。`.gitignore` 必须排除 `.env`，同时排除 `data/`、`image/seed*/`、`shared/`、`backup-*/` 与 `*.iso/*.img/*.qcow2`（本项目早期没有 .gitignore，密钥直接写在 docker-compose.yml 里，别重演）。
- compose 用 `${WIN11_USER:?...}` 强制必填：缺值时 `docker compose up` 直接失败，而不是用镜像里那个公开初始密码起一台机器。端口/内存/CPU 一律 `${VAR:-默认值}`，多实例并行只改 .env，不改 compose 文件。
- 基础镜像用 `docker-compose.base.yml`（纯注入版，不挂 ./data，靠命名卷接收种子盘）；自建安装实例用 `docker-compose.yml`（安装期 USERNAME/PASSWORD 走 answer file，与运行期注入是两套凭据，变量名前缀 `WIN11_INSTALL_*` 区分开，别混）。
- 密钥改完要生效：`docker compose -f docker-compose.base.yml up -d --force-recreate`（实测改密→SSH 改密→同步自动登录→重启一次；值没变则整轮 no-op，不重启）。
- 只改 .env 不重建容器不会生效：注入只在容器启动时跑一次。要临时改密就重建，别去 guest 里手改（会和 .env 漂移）。
## 9. 禁止事项（一条即返工）

- 用 `cat`/heredoc/JS 模板写多行脚本文件；用 `rm -rf` 打宽泛目标；把 base64 图片塞进命令输出。
- 在 VM 里同步跑分钟级任务；用 capability 路径装 OpenSSH；拿 `Get-WindowsCapability` 当 sshd 可用性的判据。
- 用顶层 `view_image` 名字调工具；用 `detail: "low"`。
- 删除或改写 `windows.*` 状态文件、`C:\Program Files\OpenSSH`（sshd 本体）；或对 `backup-*` 归档跳过 cmp 证明与用户确认就直接删。
- 为省事把 `pagefile`、镜像层垃圾、`custom.iso`、`setup.img` 打进基础镜像。
- 把口令或私人 KMS 地址写进镜像 ENV / 镜像内容；把 GHCR 包当仓库看待（包可见性 REST 改不动，404 之后反复重试或试图用 UI 自动化点按钮）。
- 相信从 guest 读回来的原始字符串（不做 tr -d '\r' 就等值比较）；相信 if ($?) 与 slmgr /dli 在管道里的输出。
- 用 `ABM_GETSTATE` / `GetWindowRect` 判断任务栏是否自动隐藏（开机场景两者会同时报"已隐藏"而屏幕上任务栏照在）；桌面形态类改动的判据是 `vnc_shot.py` 帧的底部像素，不是 API 读数。详见 `win11_init.md`。
- `Register-ScheduledTask -Settings` 里 `RestartInterval` 单独出现（没有 `-RestartCount`）会让任务 XML 缺元素、注册静默失败（0x80041319）；`-Force` 与后续 `Start-ScheduledTask` 都不报错，判据必须是 `Get-ScheduledTask` 回读 TaskName。
- 在 SYSTEM 任务或 sshd 子进程里 `Start-Process explorer.exe`（起进 session 0，桌面从此没有任务栏，必须回交互会话救）；或在函数里用 `Write-Output` 打诊断还指望它的返回值当布尔。
- 用 `aiAct` 做滚动或点一个命名目标：它走 plan/replan 循环，多付一次带截图的规划调用，还会在 replanning 上限处 rc=1（见 §1.4）。同理别指望顶层 `enable_thinking` 能关掉 llama.cpp 的思考，它不认这个字段。
- 从 midscene 报告 HTML 里读截图尺寸来判断 `desktopWidth/Height` 生效没有：那里混有模板素材图，必须用 `RDPDevice.size()` 或直接抓 PNG 读 IHDR。
- 把 `midscene-test/out/*.json` 当逐字记录用：off 档会错行、漏行、编造会话行；要逐字就 THINKING=reads/all，或跟 agent 当时真正发出的那一帧逐字核对。
- 拿 `rfb.viewOnly=true` 的探针验收剪贴板（clipboardPasteFrom 静默 no-op = 假阴性）；把 noVNC 面板 Send 按钮当剪贴板通道（它是敲键盘 ASCII-only）；或把 guest 里 sshd/session 0 的 `Get-Clipboard` 空结果当「剪贴板桥断了」——那是另一个站点，回读要走 Interactive 任务。
- 用 RDP 截图验证剪贴板/桌面效果（一连 RDP 就锁屏抢占控制台，先污染再观测；见 §1.3）。

## 10. midscene-pc 长期维护副本（窗口级 AI 接口）

- 唯一维护位置：`midscene-pc/`（本仓库内、独立 git 仓库，父仓库 .gitignore 已排除）。旧位置 `/home/aigc/ChatGPT/midscene-pc` 是迁移前快照，别再改它。
- remote：`origin` = https://github.com/yorkane/midscene-pc（直接 push 目标）；`upstream` 指向同一仓库备用。改动经 VM 验证后照常 `git push origin main`。
- 一条命令部署+验收：`scripts/mspc_sync.sh`（打包→scp→VM sync_mspc→重启 mspcServer）。可选 `--build`（先 pnpm 构建 dist）、`--e2e`（同步后在 VM 交互会话跑 `demo/win-window-api.mjs`）。判据：`rc=0` + `E2E_DONE` + `ASSERT=aiquery_contains_chinese_keywords OK`。
- VM 侧布局：代码 `C:\mspc`（sync_mspc.ps1 只换 dist/assets/src，保留 node_modules 与 .env），工具与日志 `C:\mspc-in`，服务 = Interactive 计划任务 `mspcServer`（3333，容器重启自拉起）。宿主直连 `http://172.18.0.2:3333`。
- 模型网关 key 只存在于 VM 的 `C:\mspc\.env`；宿主与仓库都不存副本。
- **v4 起镜像自带 mspc payload**（latest 现为 v5 = digest ba7110b3…，含 mspc + 剪贴板桥；v4 = 1746f4c5）：每台路径 A 实例首启由注入器部署窗口 API（deploy.md §6.5）。两条路线并存不冲突：win11-en 日常热部署仍走 mspc_sync.sh；新 base 实例走 WIN11_MSPC_* 注入。payload 更新纪律：改 midscene-pc 代码 -> mspc_sync 到 win11-en 验证 -> 在 win11-en 跑 scripts/mspc_build_payload.ps1 -> tar 落 image/mspc/ -> docker build + 全新卷首启验收（deploy.md §6.5 五步链）-> push ghcr。
- 三条实测铁律（详见 deploy.md §6.5 / 技能 pitfalls §12）：node.exe 放 `C:\mspc\bin`（UAC 过滤令牌进不了 Program Files，且失败是非终止的、try/catch 抓不住，判据必须 Test-Path）；种子盘自带 node 的 Block 防火墙规则，Block 压 Allow，注入器必须删（判据用容器侧 tcp_open guest:3333，规则计数会因 hydrate 时序骗人）；token 轮换必须连 node 进程一起重启（.env 只在启动时读，只停计划任务不停子进程 = 旧 token 继续服务）。
- 改窗口生命周期看 `assets/W11Win.cs`（首用 csc 编译到 guest %TEMP%，改后需重启服务触发重编）。三条实测铁律：别用 `Add-Type -MemberDefinition`（Tiny11 静默不产出类型）；focus 只用温和序列（ALT 注入/AttachThreadInput/SwitchToThisWindow 会让 Chromium 窗口事后从 EnumWindows 消失、前台句柄变 0）；浏览器窗口一律 title 锚定 + `fixedWindow:false`（导航会重建 HWND，id 锁定必过期）。

## 11. 浏览器 <-> VM 剪贴板桥（v5 起镜像默认开，deploy.md §7.4）

- 三层缺一不可：start.sh 预置 ARGUMENTS 冷插 virtio-serial（q35 拒热插）→ 注入器 SYSTEM 任务装 vioserv 驱动 + vdservice（UAC 过滤令牌干不了 pnputil/服务注册）→ noVNC 前端桥恢复人机粘贴。vda 载荷是签名官方二进制，可用 7z 从 spice-guest-tools 安装器直接抽（scripts/vda_build_payload.sh，不需要 VM）——和 node_modules「必须来自活 VM」不同级。
- dockur 的 noVNC fork 两处暗改（不修则协议通、人用不了）：面板 Send 按钮 = `rfb.sendText()` 敲键盘且 ASCII-only（中文变垃圾，抓 WS 帧可证）；上游 Ctrl+V 的 document paste 绑定被删。桥（image/novnc/w11-clip-bridge.js，构建期注入 vnc.html）补 paste 事件、聚焦拉取、clipboard 事件回写，并有 `lastRecv` 回声守卫（否则 VM 文本会被 focus-pull 原样弹回）。**UI 不是 window 全局**（ES module），同 URL `import("./app/ui.js")` 取同一实例。
- `rfb.viewOnly=true` 时 `clipboardPasteFrom` 静默 no-op（验收探针不许开 viewOnly）。headless Chromium 只对**可编辑焦点目标**把 Ctrl+V 变成 trusted paste——取证用临时 contenteditable 聚焦触发（scripts/vnc_clip_human_test.cjs），桥处理的是同一条 document 级事件链。
- guest 剪贴板回读必须经 Interactive 计划任务（sshd/session 0 的 Get-Clipboard 读到的是另一个站点的空剪贴板）；`\\.\Global\com.redhat.spice.0` 用 FileSystem provider 看不见，判活要 File::Open 或直接看 vdagent 是否进了控制台会话。
