# win11-base

A boot-ready Windows 11 image built on [dockurr/windows](https://github.com/dockur/windows):
the installed disk is baked into the image, so a new container boots straight to the
desktop instead of running setup. Account name, password and KMS host are injected at
`docker run` time and are not part of the image.

## What is inside

- Tiny11 Core 25H2 English (Windows 11 Pro), KMS-activated, renews every 7 days online
- One local administrator account, SSH shell is PowerShell
- OpenSSH Server (Microsoft portable build) on port 22, `sshd` = Running/Automatic
- Solid black desktop: no wallpaper files, no lock-screen image
- `C:\activate.bat` for re-activation; no third-party software
- Page file, swap file and hibernation off; disk cleaned and free space zero-filled

## Usage

```bash
docker run -d --name win11 --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN \
  -p 127.0.0.1:8006:8006 -p 127.0.0.1:3389:3389 -p 127.0.0.1:2222:22 \
  -e WIN11_USER=operator -e WIN11_PASSWORD='ChangeMe-2026' \
  -e WIN11_KMS=kms.example.com:1688 -e WIN11_KMS_KEY=xxxxx \
  --stop-grace-period 120s \
  ghcr.io/yorkane/win11-base:latest
```

| Variable | Meaning |
| --- | --- |
| `WIN11_USER` | local account name (renames the account on the disk) |
| `WIN11_PASSWORD` | local account password |
| `WIN11_KMS` | KMS `host[:port]` to activate against |
| `WIN11_KMS_KEY` | optional KMS client key (GVLK) for that host |
| `WIN11_INIT_USER` / `WIN11_INIT_PASSWORD` | credential currently on the disk, defaults `aigc`/`aigc` |
| `WIN11_GUEST_IP` | skip guest discovery and use this address |
| `WIN11_INJECT_TIMEOUT` | seconds to wait for the guest, default 900 |

Ports: 8006 noVNC, 3389 RDP, 22 SSH. Publish them to free host ports; host 22 is usually
taken. `/storage` is a volume, so the baked disk is copied into a fresh volume on first
use; mount a host directory there only if you want state to survive the container.

## How injection works

The sealed disk carries the well-known initial credential `aigc`/`aigc`, in the same way
dockur ships `admin`/`admin`. On startup a hook waits for the guest to offer SSH, logs in
with that credential (or the `WIN11_INIT_*` pair you supply), renames the account, sets the
new password, keeps the auto-logon registry in step, activates against your KMS host,
rewrites `C:\activate.bat`, and reboots the guest once so the console logs in
unattended. It runs on every start and is idempotent: when the volume already matches the
requested state, nothing changes and the guest is not rebooted.

**Always set `WIN11_USER` and `WIN11_PASSWORD`.** Without them the machine stays on the
public initial credential, and anyone who can reach port 22 or RDP has the password.

```bash
ssh operator@127.0.0.1 -p 2222        # lands in PowerShell
```

## Size

About 5.6 GB compressed: 569 MB of dockur base plus a 4.99 GB compressed qcow2 holding
9.4 GB of used NTFS.

## Caveats

- Activation is tied to the sealed disk and the MAC address baked into it. Cloning the
  volume is fine; cloning and rewriting the MAC is not.
- KMS renewal needs outbound network; if the license ever lapses, run `C:\activate.bat`.
- Force-killing the container can corrupt NTFS. Allow the 2 minute grace period.
- First boot on a fresh volume needs about a minute for the guest to come up before SSH
  answers; the injector waits for it, so a slow start is normal.

## Credits

Built on `dockurr/windows` (MIT). Windows and Tiny11 are Microsoft and NTDEV work
respectively; this repository distributes no Microsoft binaries.
