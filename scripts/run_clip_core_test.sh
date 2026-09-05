#!/bin/bash
cd /home/aigc/ChatGPT/docker-w11 || exit 1
LOG=/tmp/clipcore.log
rm -f "$LOG"
setsid nohup node scripts/vnc_clip_novnc_core.cjs /home/aigc/.npm/_npx/db89d7302a373f10/node_modules/playwright "${1:-8011}" "${2:-VM2HOST}" "${3:-browser-paste-probe}" > "$LOG" 2>&1 < /dev/null &
echo "STARTED pid=$!"
