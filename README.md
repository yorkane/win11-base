# win11-base

Boot-ready Windows 11 base image built on `dockurr/windows`: the installed disk is baked
into the image, so a new container boots straight to the desktop instead of running setup.

## Contents

- Tiny11 Core 25H2 English Pro (Windows 11 Pro), KMS-activated (renews every 7 days online)
- Local account `aigc` / `aigc`; login shell for SSH is PowerShell
- OpenSSH Server (Microsoft portable package) on port 22, `sshd` = Running/Automatic
- Solid black desktop, no wallpaper files, lock-screen image disabled
- `C:\\activate.bat` for re-activation; no third-party software installed
- Page file, swap file and hibernation disabled; disk cleaned and free space zero-filled

## Usage

    docker run -d --name win11 --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN \\
      -p 127.0.0.1:8006:8006 -p 127.0.0.1:3389:3389 -p 127.0.0.1:2222:22 \\
      win11-base:latest

- 8006 = noVNC, 3389 = RDP, 22 = SSH. Publish to free host ports (host 22 is usually taken).
- `stop_grace_period` of 2 minutes is strongly recommended; force-killing can corrupt NTFS.
- `/storage` is a VOLUME: the baked image is copied into a fresh volume on first use, so
  mount a host directory only if you want persistence across containers.

    sshpass -p aigc ssh -p 2222 aigc@127.0.0.1

## Size

~5.6 GB: 569 MB base + 4.99 GB compressed qcow2 (9.4 GB of used NTFS, 89% compressed clusters).

## Caveats

- Contains the literal password `aigc` in image ENV; keep the package private or change
  `USERNAME`/`PASSWORD` for your own builds.
- KMS activation needs outbound network to renew; if it lapses, run `C:\\activate.bat`.
- Activation state is tied to the sealed disk and its MAC address baked into the seed.

