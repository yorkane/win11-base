# win11-base

A boot-ready Windows 11 image built on [dockurr/windows](https://github.com/dockur/windows):
the installed disk is baked into the image, so a new container boots straight to the
desktop instead of running setup. Account name, password and KMS host are injected at
run time from your local `.env` and are not part of the image.

## What is inside

- Tiny11 Core 25H2 English (Windows 11 Pro), KMS-activated, renews every 7 days online
- One local administrator account, SSH shell is PowerShell
- OpenSSH Server (Microsoft portable build) on port 22, `sshd` = Running/Automatic
- Solid black desktop: no wallpaper files, no lock-screen image
- `C:\activate.bat` for re-activation; no third-party software
- Page file, swap file and hibernation off; disk cleaned and free space zero-filled

## Quick start

    cp .env.example .env      # fill in real values
    chmod 600 .env
    docker compose -f docker-compose.base.yml up -d

Then wait for the guest to come up (about a minute on a fresh volume) and connect:

    ssh <WIN11_USER>@127.0.0.1 -p <WIN11_PORT_SSH>     # lands in PowerShell

Prefer `docker run`? Pass the same variables with `-e`, or keep them in a file and use
`--env-file` (one `KEY=VALUE` per line, no shell syntax):

    docker run -d --name win11 --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN \
      -p 127.0.0.1:8006:8006 -p 127.0.0.1:3389:3389 -p 127.0.0.1:2222:22 \
      --env-file .env --stop-grace-period 120s \
      ghcr.io/yorkane/win11-base:latest

## Secrets: `.env` only

No credential lives in the image, the Dockerfile or the compose file. `docker compose`
reads `.env` from the project directory automatically. Commit `.env.example` (placeholders
only); `.gitignore` keeps the real `.env` out of git. Give it mode 600.

| Variable | Meaning |
| --- | --- |
| `WIN11_USER` | local account name (renames the account on the disk) |
| `WIN11_PASSWORD` | local account password (**required**) |
| `WIN11_KMS` | KMS `host[:port]` to activate against; empty disables activation |
| `WIN11_KMS_KEY` | optional KMS client key (GVLK) for that host |
| `WIN11_INIT_USER` / `WIN11_INIT_PASSWORD` | credential currently on the disk, default `aigc`/`aigc` |
| `WIN11_GUEST_IP` | skip guest discovery and use this address |
| `WIN11_INJECT_TIMEOUT` | seconds to wait for the guest, default 900 |
| `WIN11_RAM_SIZE` / `WIN11_CPU_CORES` / `WIN11_DISK_SIZE` | VM sizing |
| `WIN11_PORT_VNC` / `WIN11_PORT_RDP` / `WIN11_PORT_SSH` | published host ports |
| `WIN11_CONTAINER_NAME` | container name and hostname |

The compose file marks `WIN11_USER` and `WIN11_PASSWORD` as required, so a missing `.env`
fails immediately instead of booting a machine on the public initial password.

Rotate later: edit `.env`, then
`docker compose -f docker-compose.base.yml up -d --force-recreate`.

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

## Size

About 5.6 GB compressed: 569 MB of dockur base plus a 4.99 GB compressed qcow2 holding
9.4 GB of used NTFS.

## Repository layout

    .env.example              credentials template (the real .env stays local, mode 600)
    docker-compose.base.yml   run this; wires every variable into the container
    image/Dockerfile          dockurr/windows + injector + seeded disk
    image/win11-inject.sh     the startup injector (rename, password, KMS, auto-logon)
    image/start.sh            replaces /run/start.sh, the hook dockur invites you to override
    image/.dockerignore       keeps the disk out of the build context

`image/win11-inject.sh` and `image/start.sh` in this repository are byte-identical to the files
inside the published image (`md5sum /usr/local/bin/win11-inject /run/start.sh`). Read them before
you point this image at a network you do not control.

## Building

Only the disk is missing from git: `image/seed/` (a ~5 GB compressed qcow2) ships through the
image, not the repository. A clone gives you the injector and the Dockerfile, not a bootable
image. Two options:

- Use the published image. That is the supported path; nothing to build.
- Build your own: install Windows once with upstream `dockurr/windows` (your own ISO and
  account), let it finish, shut it down gracefully, then point `image/Dockerfile` at that
  `/storage` directory as the seed. Keep the `windows.*` state files, especially
  `windows.boot` -- without it the container decides Windows was never installed and reinstalls.
  Put `COPY seed/` first in the Dockerfile and the thin injector layers last, so editing the
  injector does not re-transfer 5 GB on push.

    docker build -t win11-base image

## Caveats

- Activation is tied to the sealed disk and the MAC address baked into it. Cloning the
  volume is fine; cloning and rewriting the MAC is not.
- KMS renewal needs outbound network; if the license ever lapses, run `C:\activate.bat`.
- Force-killing the container can corrupt NTFS. Allow the 2 minute grace period.
- `/storage` is a volume: the baked disk is copied into a fresh volume on first use. Mount
  a host directory there only if you want state to survive the container.
- First boot on a fresh volume needs about a minute before SSH answers; the injector waits
  for it, so a slow start is normal.

## Credits

Built on `dockurr/windows` (MIT). Windows and Tiny11 are Microsoft and NTDEV work
respectively; this repository distributes no Microsoft binaries.
