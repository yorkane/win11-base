# Boot-ready Windows 11 seed on top of dockurr/windows.
#
# The installed disk is baked in as a /storage volume seed, so a fresh container boots
# straight to the desktop. Credentials and the KMS host are NOT part of the image: they
# arrive through the container environment and a startup hook pushes them into the guest
# over SSH the first time it is up. The sealed disk carries a well-known initial
# credential, the same way dockur ships admin/admin, purely so that hook can rotate it.
FROM dockurr/windows:latest

COPY seed/ /storage/
# midscene-pc payload (~80 MB): node.exe + win32 node_modules + dist, packed FROM A LIVE
# VM (win32 binaries cannot be reinstalled from this Linux image). Right after the seed
# so edits to the scripts below never re-transfer it.
COPY mspc/mspc-payload.tar.gz /usr/local/share/win11/mspc-payload.tar.gz
# vdagent payload (~370 KB): vioserial driver + vdservice/vdagent, extracted from the
# official spice-guest-tools on a Windows box. Same rule as node: win32 binaries cannot
# be produced here. QEMU speaks the other end of this channel (see start.sh).
COPY vda/vda-payload.tar.gz /usr/local/share/win11/vda-payload.tar.gz
COPY win11-inject.sh /usr/local/bin/win11-inject
# Guest-side assets the injector pushes into C:\ProgramData\w11 at every start:
# the desktop-look pass and the measured taskbar ladder (see win11_init.md).
# w11_mspc.ps1 + its JSON template configure the midscene-pc API server in the guest.
# vda_install.ps1 wires up the browser <-> Windows clipboard bridge (with vda payload).
COPY w11_desktop.ps1 tb_ensure_hidden.ps1 w11_mspc.ps1 mspc-args.json.template vda_install.ps1 /usr/local/share/win11/
# dockur sources /run/start.sh as its very first action inside /run/entry.sh and invites
# exactly this override. The hook detaches the injector, so Windows boots in parallel with
# the wait loop instead of being delayed by it.
COPY start.sh /run/start.sh
# noVNC clipboard bridge: dockur's fork lost the Ctrl+V binding (see novnc/patch-novnc.sh).
# The RUN rewrites vnc.html once; a later COPY of a file is layer-cheap when unchanged.
COPY novnc/w11-clip-bridge.js /usr/share/novnc/w11-clip-bridge.js
COPY novnc/patch-novnc.sh /usr/local/bin/novnc-patch

RUN chmod 755 /usr/local/bin/win11-inject /run/start.sh /usr/local/bin/novnc-patch \
 && /usr/local/bin/novnc-patch \
 && apt-get update \
 && apt-get install -y --no-install-recommends openssh-client sshpass \
 && rm -rf /var/lib/apt/lists/*

ENV RAM_SIZE="4G" CPU_CORES="4"
