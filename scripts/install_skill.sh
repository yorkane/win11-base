#!/usr/bin/env bash
# 把仓库内的项目技能安装进 Codex（技能发现只看 ~/.codex/skills/，仓库目录本身不算）。
# 幂等：已是指向本仓库的 symlink 就跳过；是旧副本就先备份到 .trash 再换链接。
# 用法：bash scripts/install_skill.sh [技能名 ...]（默认装 win11-daily）
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${CODEX_HOME:-$HOME/.codex}/skills"
names=("${@:-win11-daily}")
mkdir -p "$DEST"
rc=0
for n in ${names[*]}; do
  src="$DIR/skills/$n"
  [ -f "$src/SKILL.md" ] || { echo "FAIL: $src/SKILL.md 不存在"; rc=1; continue; }
  dst="$DEST/$n"
  if [ -L "$dst" ]; then
    cur=$(readlink "$dst")
    [ "$cur" = "$src" ] && { echo "OK: $n 已链接 -> $cur"; continue; }
    rm "$dst"
  elif [ -d "$dst" ]; then
    ts=$(date +%s)
    mkdir -p "$DIR/.trash"
    mv "$dst" "$DIR/.trash/${n}.pre-skillinstall-$ts"
    echo "BACKUP: 旧副本移到 $DIR/.trash/${n}.pre-skillinstall-$ts"
  fi
  ln -s "$src" "$dst" && echo "INSTALLED: $n -> $src"
done
# 验收：目标目录能读到 frontmatter 的 name 行
for n in ${names[*]}; do
  if head -5 "$DEST/$n/SKILL.md" 2>/dev/null | grep -q "^name: $n"; then
    echo "VERIFIED: $n"
  else
    echo "FAIL: $n 装完读不到 SKILL.md frontmatter"; rc=1
  fi
done
exit $rc
