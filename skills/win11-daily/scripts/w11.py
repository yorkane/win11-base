#!/usr/bin/env python3
"""w11.py -- docker-w11 日常 agent 操作驱动（run/install/uninstall/apps/open/save/pull/disk/status）

只依赖 sshpass + .env 里的凭据，不依赖本仓库其它文件。guest 侧动作一律走
SSH + powershell -EncodedCommand（utf-16le + base64），文件传输一律 scp。

为什么不用 SMB：host.lan\\Data 只有把 ./shared 挂进容器的老装机实例（路径 B）才有，
基础镜像实例（docker-compose.base.yml，命名卷）没有这个挂载 —— 2026-09-09 实测：
走 SMB 的脚本 STAGED=False SIZE=0（拷不到文件，msiexec 于是回 1619）。scp 两边通用。

为什么 GUI 不能直接 Start-Process：sshd 子进程与 SYSTEM 任务都在 session 0，
起的窗口永远看不见。要出现在桌面上的东西都注册一个 LogonType Interactive 的一次性
计划任务，principal = 控制台自动登录用户（WIN11_CONSOLE_USER，默认同 WIN11_USER）。

定位实例（先 set -a; . .env; set +a；PORT = 宿主发布的 SSH 口，固定族 = 10022）：
  WIN11_SSH_HOST / WIN11_SSH_PORT / WIN11_SSH_USER / WIN11_SSH_PASS
  （未设时回退 WIN11_USER / WIN11_PASSWORD）

子命令：
  run script.ps1 [秒]                     同步跑一段 PowerShell，透传判据行
  install <本地文件|C:\\...> [--args "..."] [--system] [--wait 秒] [--skip-if guest路径marker]
                                          传包 + 静默装；.msi 自动补 /i ... /qn /norestart，
                                          setup*.exe 自动补 /S；机器级安装走 --system（SYSTEM 令牌）
  uninstall <显示名子串>                   卸载表找 UninstallString，MSI 走 /x guid /qn，其余试 /SILENT
  apps                                    列卸载表：NAME|VERSION|UninstallString
  open <exe绝对路径> [参数...]              把 GUI 起进控制台会话，回读 SESS1=<进程数>
  save <本地> <guest绝对路径>              scp 上传 + SHA256 回读校验（SAVE_OK）
  pull <guest绝对路径> <本地>              scp 取回 + 两边哈希对照
  disk [--apply]                          虚拟盘/分区/剩余体检；--apply 把 C 吃满（免重启）
  chrome [URL ...]                       确保 CDP 端点存活（宿主口 WIN11_CDP_PORT，默认 19222）；带 URL 开标签页；--tabs 列表
  status                                  会话、sshd、开机时间、剩余空间、桌面进程

装完不等于装好：验收 = apps 里出现该条目，或 marker 文件存在。装没装上图标/起没起窗口，
只有 vnc_shot.py 截图知道（看图只能在 exec isolate 内 await tools.view_image）。
"""
import base64, hashlib, os, subprocess, sys, time

HOST = os.environ.get("WIN11_SSH_HOST", "127.0.0.1")
PORT = os.environ.get("WIN11_SSH_PORT", "10022")
USER = os.environ.get("WIN11_SSH_USER", os.environ.get("WIN11_USER", "aigc"))
PASSWORD = os.environ.get("WIN11_SSH_PASS", os.environ.get("WIN11_PASSWORD", ""))
WUSER = os.environ.get("WIN11_CONSOLE_USER", USER)


def ssh_cmd(tail, timeout=180, check=True):
    cmd = ["sshpass", "-p", PASSWORD, "ssh", "-p", PORT,
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "ConnectTimeout=15", "-o", "LogLevel=ERROR",
           "%s@%s" % (USER, HOST)] + list(tail)
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    out = p.stdout or ""
    if p.stderr and p.stderr.strip() and "CLIXML" not in p.stderr:
        out += "[stderr] " + p.stderr.strip()
    if check and p.returncode != 0:
        sys.stderr.write(out + " [exit=%d]" % p.returncode + chr(10))
        sys.exit(1)
    return out


def ps(text, timeout=180, check=True):
    data = text.replace(chr(13) + chr(10), chr(10)).replace(chr(10), chr(13) + chr(10)).encode("utf-8")
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    b64 = base64.b64encode(data.decode("utf-8").encode("utf-16-le")).decode()
    return ssh_cmd(["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", b64], timeout, check)


def psq(s):
    return s.replace("'", "''")


# scp 必须直接喂给 sshpass 起 scp 进程：ssh_cmd 会把 tail 拼成 ssh user@host `tail`，
# 那等于在 guest 里执行 scp（本地路径 guest 不存在），行为=静默挂到超时。
def win_path(p):
    # scp 走 SFTP 模式：guest 路径必须正斜杠（反斜杠会被当转义符，Win32-OpenSSH 实测）
    return p.replace(chr(92), "/")


def scp_run(tail, timeout=900):
    # 不带 -O（legacy SCP 协议对 Win32-OpenSSH 会报 protocol error: filename does not match request）
    cmd = ["sshpass", "-p", PASSWORD, "scp", "-P", PORT,
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "LogLevel=ERROR"] + list(tail)
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        sys.stderr.write((p.stderr or "") + " [scp exit=%d]" % p.returncode + chr(10))
        sys.exit(1)


def scp_put(local, guest_path, timeout=900):
    scp_run([local, "%s@%s:%s" % (USER, HOST, win_path(guest_path))], timeout)


def scp_get(guest_path, local, timeout=900):
    d = os.path.dirname(os.path.abspath(local))
    if d:
        os.makedirs(d, exist_ok=True)
    scp_run(["%s@%s:%s" % (USER, HOST, win_path(guest_path)), local], timeout)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


RUN_ONCE = r'''
$ErrorActionPreference='Continue'
$log = 'C:\Temp\__TAG__.log'
if (Test-Path $log) { Remove-Item $log -Force }
$argline = '__ARGS__'
$act = if ($argline -eq '') { New-ScheduledTaskAction -Execute '__EXE__' } else { New-ScheduledTaskAction -Execute '__EXE__' -Argument $argline }
$pri = New-ScheduledTaskPrincipal -UserId '__WUSER__' -LogonType Interactive -RunLevel __LEVEL__
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes __TMIN__)
$null = Register-ScheduledTask -TaskName __TAG__ -Action $act -Principal $pri -Settings $set -Force
if (-not (Get-ScheduledTask -TaskName __TAG__ -ErrorAction SilentlyContinue)) { Write-Output 'TASKREG=failed'; exit 1 }
Start-ScheduledTask -TaskName __TAG__
Write-Output 'TASK=started'
__WAITBLOCK__
if (Test-Path $log) { Get-Content $log | Select-Object -Last 20 }
'''

WAIT_BLOCK = r'''
$i = Get-ScheduledTask -TaskName __TAG__ | Get-ScheduledTaskInfo
while ($i.State -eq 'Running' -or $i.State -eq 'Queued') { Start-Sleep -Seconds 3; $i = Get-ScheduledTask -TaskName __TAG__ | Get-ScheduledTaskInfo }
Write-Output ('RESULT=' + $i.LastTaskResult)
'''

NO_WAIT = "Write-Output 'FIRED=1'"


def run_once(exe, argline, tag, level="Limited", tmin=10, check=True, wait=True):
    s = (RUN_ONCE.replace("__EXE__", psq(exe)).replace("__ARGS__", psq(argline))
         .replace("__TAG__", tag).replace("__WUSER__", psq(WUSER))
         .replace("__LEVEL__", level).replace("__TMIN__", str(tmin))
         .replace("__WAITBLOCK__", WAIT_BLOCK if wait else NO_WAIT))
    return ps(s, timeout=min(tmin * 60 + 60, 2400), check=check)


def cleanup_task(tag):
    ps("$null = Unregister-ScheduledTask -TaskName " + tag + " -Confirm:$false -ErrorAction SilentlyContinue", check=False)


def cmd_run(a):
    if not a:
        sys.exit("usage: w11.py run script.ps1 [sec]")
    sys.stdout.write(ps(open(a[0], encoding="utf-8").read(), int(a[1]) if len(a) > 1 else 180))


def cmd_install(a):
    src, margs, system, wait, marker = None, "", False, 600, ""
    i = 0
    while i < len(a):
        k = a[i]
        if k == "--args": margs, i = a[i + 1], i + 2
        elif k == "--system": system, i = True, i + 1
        elif k == "--wait": wait, i = int(a[i + 1]), i + 2
        elif k == "--skip-if": marker, i = a[i + 1], i + 2
        else: src, i = a[i], i + 1
    if not src:
        sys.exit("usage: w11.py install <local file|C:\\path> [--args ...] [--system] [--wait sec] [--skip-if marker]")
    if marker and "SKIP=yes" in ps('if (Test-Path "' + marker + '") { Write-Output "SKIP=yes" } else { Write-Output "SKIP=no" }'):
        print("SKIP_INSTALL (marker present): " + marker)
        return
    if len(src) > 2 and src[1] == ":":
        gpath = src
        print("GUEST_SRC=" + gpath)
    else:
        gpath = "C:\\Temp\\" + os.path.basename(src)
        scp_put(src, gpath, timeout=max(900, wait))
        print("SCP_OK -> " + gpath)
    low = gpath.lower()
    if not margs:
        if system or low.endswith(".msi"):
            margs = '/i "' + gpath + '" /qn /norestart'
        elif any(k in low for k in ("setup", "install", "wechat")):
            margs = "/S"
    tag = "w11dailyi%d" % os.getpid()  # 唯一 tag：并发跑时 cleanup 不会注销别人的任务（2026-09-09 实测互相抢）
    cleanup_task(tag)
    tmin = max(10, wait // 60 + 5)
    if system or low.endswith(".msi"):
        # machine-wide msi: always hand to msiexec (a .msi path fired directly = GUI dialog)
        exe = "msiexec.exe" if low.endswith(".msi") else "cmd.exe"
        args = margs if low.endswith(".msi") else '/c "' + gpath + '" ' + margs
        sys.stdout.write(run_once(exe, args, tag, level="Highest", tmin=tmin))
    else:
        sys.stdout.write(run_once(gpath, margs, tag, level="Highest", tmin=tmin))
    if marker:
        sys.stdout.write(ps('for ($i=0; $i -lt ' + str(wait // 3) + '; $i++) { if (Test-Path "' + marker + '") { Write-Output "MARKER=hit"; exit }; Start-Sleep -Seconds 3 }; Write-Output "MARKER=missing"', wait + 30))
    cleanup_task(tag)


UNINSTALL_QUERY = ("$k='HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',"
                   "'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*';")


def cmd_apps(_a):
    sys.stdout.write(ps(UNINSTALL_QUERY +
        "Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object DisplayName | ForEach-Object "
        "{ Write-Output ($_.DisplayName + '|' + $_.DisplayVersion + '|' + $_.UninstallString) }"))


def cmd_uninstall(a):
    if not a:
        sys.exit("usage: w11.py uninstall <DisplayName substring>")
    out = ps("$n='" + psq(a[0]) + "';" + UNINSTALL_QUERY +
             "$p=Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like ('*' + $n + '*') } | Select-Object -First 1;"
             "if (-not $p) { Write-Output 'NOTFOUND'; exit };"
             "Write-Output ('FOUND=' + $p.DisplayName + '|' + $p.UninstallString)")
    print(out.strip())
    if "NOTFOUND" in out:
        return
    ustr = [l for l in out.splitlines() if l.startswith("FOUND=")][0].split("|", 1)[1]
    tag, out2 = "w11dailyu%d" % os.getpid(), ""
    cleanup_task(tag)
    if "msiexec" in ustr.lower():
        low = ustr.lower()
        for sw in ("/x", "/i", "/u", "msiexec.exe"):
            low = low.replace(sw, " ")
        toks = [t for t in low.split() if t.strip("{}").strip()]
        out2 = run_once("msiexec.exe", "/x " + toks[-1] + " /qn /norestart", tag, level="Highest", tmin=15)
    else:
        exe = ustr.strip('"').split(" ")[0]
        out2 = run_once(exe, "/SILENT /VERYSILENT /SUPPRESSMSGBOXES /NORESTART", tag, level="Highest", tmin=15)
    sys.stdout.write(out2)
    cleanup_task(tag)


def cmd_open(a):
    if not a:
        sys.exit("usage: w11.py open <exe absolute path> [args...]")
    exe, extra = a[0], " ".join(a[1:])
    tag = "w11dailyo%d" % os.getpid()
    cleanup_task(tag)
    # GUI apps keep their one-shot task Running until the window exits: fire, do NOT wait.
    sys.stdout.write(run_once(exe, extra, tag, level="Limited", tmin=240, check=False, wait=False))
    name = os.path.basename(exe).rsplit(".", 1)[0]
    # 冷启动的首个 GUI 进程可能要 30s+（7zFM 实测），预算给 60s
    sys.stdout.write(ps("for ($i=0; $i -lt 30; $i++) { $n = @(Get-Process -Name '" + name + "' -ErrorAction SilentlyContinue | Where-Object SessionId -EQ 1).Count;"
                        "if ($n -gt 0) { Write-Output ('SESS1=' + $n); exit }; Start-Sleep -Seconds 2 };"
                        "Write-Output 'SESS1=0'"))
    cleanup_task(tag)


def guest_hash(gpath):
    return ps('$f="' + gpath + '"; if (-not (Test-Path $f)) { Write-Output "GUESTHASH=missing"; exit };' +
              'Write-Output ("GUESTHASH=" + (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower() + " SIZE=" + (Get-Item $f).Length)')


def cmd_save(a):
    if len(a) < 2:
        sys.exit("usage: w11.py save <local file> <guest absolute path>")
    local, gpath = a[0], a[1]
    h = sha256(local)
    scp_put(local, gpath)
    out = guest_hash(gpath)
    print("LOCALSHA=" + h)
    print(out.strip())
    if h not in out:
        sys.exit("SAVE_MISMATCH")
    print("SAVE_OK")


def cmd_pull(a):
    if len(a) < 2:
        sys.exit("usage: w11.py pull <guest absolute path> <local file>")
    out = guest_hash(a[0])
    print(out.strip())
    if "missing" in out:
        sys.exit("PULL_NOTFOUND")
    scp_get(a[0], a[1])
    print("LOCALSHA=" + sha256(a[1]))


def cmd_clip(a):
    # 把文本送进【控制台会话】的剪贴板：sshd 子进程在 session 0，那里的剪贴板是另一个站点，
    # Set-Clipboard 直接跑 = 用户 Ctrl+V 粘贴不到东西。
    # 文本经 scp 进 C:\\Temp\\w11clip.txt（免引号/换行转义），再由 Interactive 一次性任务执行资产脚本。
    if len(a) < 1:
        sys.exit("usage: w11.py clip <local text file | - >")
    txt = a[0]
    if txt == "-":
        body = sys.stdin.read()
    else:
        body = open(txt, encoding="utf-8").read()
    import tempfile
    tmp = os.path.join(tempfile.gettempdir(), "w11clip.txt")
    io = __import__("io")
    with open(tmp, "wb") as f:
        f.write(body.encode("utf-16"))  # BOM 必须带：ReadAllText 靠 BOM 识别 utf-16
    scp_put(tmp, "C:\\Temp\\w11clip.txt", 120)
    asset = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "set_clip.ps1")
    scp_put(asset, "C:\\Temp\\set_clip.ps1", 120)
    tag = "w11dailyclip%d" % os.getpid()
    cleanup_task(tag)
    # no redirect here: set_clip.ps1 writes its own log; a cmd > handle on the
    # same path makes that write land as 0 bytes (measured 2026-09-09)
    ps1 = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\\\Temp\\\\set_clip.ps1"
    sys.stdout.write(run_once("cmd.exe", '/c ' + ps1, tag, level="Limited", tmin=2))
    out = ps('for ($i=0; $i -lt 20; $i++) { if (Test-Path C:\\Temp\\w11clip.log) {'
             'Select-String -Path C:\\Temp\\w11clip.log -Pattern CLIP_ | Out-Null;'
             '(Get-Content C:\\Temp\\w11clip.log) | ForEach-Object { Write-Output ("C " + $_) }; exit };'
             ' Start-Sleep -Seconds 2 }; Write-Output "C LOG=missing"')
    sys.stdout.write(out)
    cleanup_task(tag)


DISK_PS = r'''
$d = Get-Disk | Where-Object { $_.IsOffline -eq $False } | Sort-Object Number | Select-Object -First 1
Write-Output ('DISK=' + $d.Number + ' SIZE=' + [math]::Round($d.Size/1GB,1))
$parts = Get-Partition -DiskNumber $d.Number | Sort-Object Offset | ForEach-Object { '' + $_.PartitionNumber + ':' + [math]::Round($_.Size/1GB,1) }
Write-Output ('PARTS=' + ($parts -join ','))
$c = Get-Partition -DriveLetter C; $sup = Get-PartitionSupportedSize -DriveLetter C
Write-Output ('C=' + [math]::Round($c.Size/1GB,1) + ' C_MAX=' + [math]::Round($sup.SizeMax/1GB,1) + ' FREE=' + [math]::Round((Get-PSDrive C).Free/1GB,1))
if ($sup.SizeMax -gt ($c.Size + 100MB)) { Write-Output 'GAP=yes' } else { Write-Output 'GAP=no' }
'''

EXTEND_PS = r'''
$c = Get-Partition -DriveLetter C; $sup = Get-PartitionSupportedSize -DriveLetter C
if ($sup.SizeMax -le $c.Size) { Write-Output 'NOTHING_TO_DO'; exit }
Resize-Partition -DriveLetter C -Size $sup.SizeMax -ErrorAction Stop
Write-Output ('RESIZED -> ' + [math]::Round((Get-Partition -DriveLetter C).Size/1GB,1))
Write-Output ('FREE=' + [math]::Round((Get-PSDrive C).Free/1GB,1))
'''


INIT_DATA_PS = r'''
# Tiny11 has NO Init-Disk/New-Partition cmdlets (Storage module trimmed): diskpart
# is the only route, and diskpart needs a real admin token -> run the staged bat
# as a SYSTEM one-shot task (UAC-filtered SSH tokens are refused). RAW disks only:
# an initialized disk is never touched, so repeat runs are no-ops.
$ErrorActionPreference='Continue'
$raw = @(Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.IsBoot -eq $False })
if ($raw.Count -eq 0) { Write-Output 'DISKS=all-init'; exit }
$d = $raw[0]
$sel = 'select disk ' + [int]$d.Number
$dp = @($sel, 'create partition primary', 'format quick fs=ntfs label=Data', 'assign')
Set-Content -Path C:\Temp\dpx.txt -Value $dp -Encoding ASCII
$bat = @('@echo off',
         ('diskpart /s C:\Temp\dpx.txt >> C:\Temp\w11disk.log 2>&1'),
         'echo DP_EXIT=%ERRORLEVEL% >> C:\Temp\w11disk.log')
Set-Content -Path C:\Temp\w11disk.bat -Value $bat -Encoding ASCII
Get-Content C:\Temp\w11disk.bat | ForEach-Object { Write-Output ('BAT[' + $_ + ']') }
Write-Output 'DISKTASK=staged'
if ($raw.Count -gt 1) { Write-Output 'NOTE=multiple-raw-disks (re-run to init the next one)' }
'''
 
DISKLOG_PS = r'''
Get-Content C:\Temp\w11disk.log -ErrorAction SilentlyContinue | Select-Object -Last 8 | ForEach-Object { Write-Output ('DP ' + $_) }
foreach ($drv in Get-PSDrive -PSProvider FileSystem) { Write-Output ('DRV=' + $drv.Name + ' FREE=' + [math]::Round($drv.Free/1GB,1)) }
'''
 
 
def disk_init():
    stage = ps(INIT_DATA_PS)
    if 'DISKTASK=staged' not in stage:
        return stage
    tag = 'w11dailyd%d' % os.getpid()
    cleanup_task(tag)
    out = run_once('cmd.exe', '/c C:\\Temp\\w11disk.bat', tag, level='Highest', tmin=5)
    time.sleep(8)
    log = ps(DISKLOG_PS)
    cleanup_task(tag)
    return stage + out + log
 
 
NOTE2 = (
'第二块数据盘：compose 叠加 docker-compose.disk2.yml（DISK2_SIZE + win11-storage2 卷，'
'卷可换宿主 bind -v /data/xxx:/storage2 把盘放到大分区）。guest 里新盘是 RAW，'
'disk --apply 会用 diskpart 初始化成 D:（Tiny11 无 Init-Disk，必须 SYSTEM 任务）。'
)
def cmd_disk(a):
    sys.stdout.write(ps(DISK_PS))
    if "--apply" in a:
        sys.stdout.write(ps(EXTEND_PS))
        sys.stdout.write(disk_init())
        sys.stdout.write("NOTE: 这一步只把 guest 分区吃满 dockur 已经扩大的虚拟盘（免重启，实测 35.7->63.7G）。"
                         "虚拟盘本身变大在宿主机做：改 .env 的 WIN11_DISK_SIZE 再 up -d --force-recreate；"
                         "dockur 只扩不缩（缩小直接报 Shrinking disks is not supported）。" + chr(10))
        sys.stdout.write(NOTE2 + chr(10))


def cmd_status(_a):
    sys.stdout.write(ps("Write-Output ('QUSER=' + ((quser) -join ' ;; '))", check=False))
    sys.stdout.write(ps("Write-Output ('SSHD=' + (Get-Service sshd).Status);"
                        "Write-Output ('BOOT=' + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime);"
                        "Write-Output ('C_FREE=' + [math]::Round((Get-PSDrive C).Free/1GB,1));"
                        "Write-Output ('SESS1_APPS=' + ((Get-Process | Where-Object SessionId -EQ 1 | Select-Object -First 12).Name -join ','))"))


def cmd_chrome(a):
    # Chrome CDP endpoint (default deploy): guest chrome binds 127.0.0.1:9223, an elevated
    # netsh portproxy holds 0.0.0.0:9222, compose publishes 127.0.0.1:WIN11_CDP_PORT (default 19222).
    # This subcommand: probe host /json/version -> if down, Start-ScheduledTask w11CdpChrome and
    # wait; then open each URL as a new tab (PUT /json/new). The authoritative check is host-side.
    import json, urllib.parse, urllib.request
    port = os.environ.get("WIN11_CDP_PORT", "19222")
    base = "http://127.0.0.1:" + port

    def rq(path, method=None, timeout=6):
        req = urllib.request.Request(base + path, method=method)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8", "replace"))

    def version():
        try:
            return rq("/json/version")
        except Exception:
            return None

    v = version()
    if v is None:
        sys.stdout.write("CDP_DOWN -> run task w11CdpChrome" + chr(10))
        ps("Start-ScheduledTask -TaskName w11CdpChrome -ErrorAction SilentlyContinue;"
           "Write-Output ('TASKSTATE=' + (Get-ScheduledTask -TaskName w11CdpChrome -ErrorAction SilentlyContinue | Where-Object TaskName).State)",
           check=False)
        for _ in range(20):
            time.sleep(3)
            v = version()
            if v is not None:
                break
    if v is None:
        sys.exit("CDP_STILL_DOWN: check docker logs (grep -i cdp) and guest C:/ProgramData/w11/cdp.log; WIN11_CDP=off disables the endpoint")
    sys.stdout.write("CDP=UP Browser=" + str(v.get("Browser", "?")) + " Endpoint=" + base + chr(10))
    urls = [x for x in a if not x.startswith("--")]
    if "--tabs" in a:
        for t in rq("/json/list"):
            if t.get("type") == "page":
                sys.stdout.write("TAB|" + t.get("id", "")[:8] + "|" + (t.get("title") or "")[:40] + "|" + (t.get("url") or "")[:90] + chr(10))
        return
    if not urls:
        sys.stdout.write("no URL given: endpoint ready only. drive it: playwright-cli attach --cdp=" + base + " -s=w11" + chr(10))
        return
    for u in urls:
        t = rq("/json/new?" + urllib.parse.quote(u, safe=":/?&="), method="PUT")
        sys.stdout.write("TAB=" + t.get("id", "") + " URL=" + str(t.get("url", u)) + chr(10))


HANDLERS = {"run": cmd_run, "install": cmd_install, "uninstall": cmd_uninstall, "apps": cmd_apps, "clip": cmd_clip,
            "open": cmd_open, "save": cmd_save, "pull": cmd_pull, "disk": cmd_disk, "status": cmd_status,
            "chrome": cmd_chrome}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in HANDLERS:
        print(__doc__)
        return 2
    HANDLERS[sys.argv[1]](sys.argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
