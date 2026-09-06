#!/bin/sh
# Inject the clipboard bridge into dockur's bundled noVNC UI, once and idempotently.
# dockur's noVNC 1.7.0 fork dropped the Ctrl+V paste binding and turned the panel
# "Send clipboard" button into ASCII keystroke typing; the bridge restores both through
# the extended-clipboard protocol that QEMU+vdagent already speak. See the .js file.
HTML=/usr/share/novnc/vnc.html
BRIDGE=/usr/share/novnc/w11-clip-bridge.js
test -f "$HTML" || { echo "novnc-patch: $HTML missing, skip"; exit 0; }
test -f "$BRIDGE" || { echo "novnc-patch: bridge file missing"; exit 1; }
if grep -q "w11-clip-bridge.js" "$HTML"; then exit 0; fi
# Content-hash query: without it browsers keep serving a stale bridge forever
# (observed 2026-09-05: a removed function was still executed from a cached copy).
VER=$(sha256sum "$BRIDGE" | cut -c1-8)
sed -i "s#</body>#<script src=\"w11-clip-bridge.js?v=$VER\"></script>\n</body>#" "$HTML"
grep -q "w11-clip-bridge.js" "$HTML" || { echo "novnc-patch: injection failed"; exit 1; }
exit 0
