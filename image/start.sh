#!/usr/bin/env bash
# Replaces the empty /run/start.sh hook that dockur/windows sources first thing in
# /run/entry.sh. It deliberately does not block: Windows boots while the injector waits
# for the guest to offer SSH.
#
# Clipboard bridge (WIN11_CLIP=off to disable): dockur reads $ARGUMENTS in init.sh,
# which is sourced AFTER this hook, and init.sh only defaults it when unset -- so we can
# pre-set it here. The virtio-serial device CANNOT be hotplugged (q35 root bus refuses
# it), so the chardev must ride along with the qemu command line at container start.
# QEMU then relays: noVNC extended clipboard <-> vdagent channel <-> guest clipboard.
if [ "${WIN11_CLIP:-on}" != "off" ]; then
  case "${ARGUMENTS:-}" in
    *qemu-vdagent*) : ;;  # operator already plugged it themselves
    *) ARGUMENTS="${ARGUMENTS:-} -chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on -device virtio-serial-pci,id=virtio-serial0,disable-modern=on,disable-legacy=off -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=vdagent,name=com.redhat.spice.0,id=channel0" ;;
  esac
  export ARGUMENTS
fi

if [ -x /usr/local/bin/win11-inject ]; then
  /usr/local/bin/win11-inject &
fi

return 0
