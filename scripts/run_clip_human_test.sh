#!/bin/bash
cd /home/aigc/ChatGPT/docker-w11 || exit 1
LOG=/tmp/cliphuman.log
rm -f "$LOG"
setsid nohup node scripts/vnc_clip_human_test.cjs /home/aigc/.npm/_npx/db89d7302a373f10/node_modules/playwright "${1:-8011}" "${2:-VM2HOST}" "${3:-ctrlv_from_browser}" "${4:-focus_pull_test}" "${5:-2500}" > "$LOG" 2>&1 < /dev/null &
echo "STARTED pid=$!"
