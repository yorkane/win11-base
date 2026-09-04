#!/usr/bin/env bash
# Replaces the empty /run/start.sh hook that dockur/windows sources first thing in
# /run/entry.sh. It deliberately does not block: Windows boots while the injector waits
# for the guest to offer SSH.

if [ -x /usr/local/bin/win11-inject ]; then
  /usr/local/bin/win11-inject &
fi

return 0
