# Boot-ready Windows 11 seed on top of dockurr/windows.
#
# The installed disk is baked in as a /storage volume seed, so a fresh container boots
# straight to the desktop. Credentials and the KMS host are NOT part of the image: they
# arrive through the container environment and a startup hook pushes them into the guest
# over SSH the first time it is up. The sealed disk carries a well-known initial
# credential, the same way dockur ships admin/admin, purely so that hook can rotate it.
FROM dockurr/windows:latest

COPY seed/ /storage/
COPY win11-inject.sh /usr/local/bin/win11-inject
# Guest-side assets the injector pushes into C:\ProgramData\w11 at every start:
# the desktop-look pass and the measured taskbar ladder (see win11_init.md).
COPY w11_desktop.ps1 tb_ensure_hidden.ps1 /usr/local/share/win11/
# dockur sources /run/start.sh as its very first action inside /run/entry.sh and invites
# exactly this override. The hook detaches the injector, so Windows boots in parallel with
# the wait loop instead of being delayed by it.
COPY start.sh /run/start.sh

RUN chmod 755 /usr/local/bin/win11-inject /run/start.sh \
 && apt-get update \
 && apt-get install -y --no-install-recommends openssh-client sshpass \
 && rm -rf /var/lib/apt/lists/*

ENV RAM_SIZE="4G" CPU_CORES="4"
