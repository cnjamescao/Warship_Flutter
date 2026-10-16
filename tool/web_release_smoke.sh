#!/usr/bin/env bash
# ================================================================
# tool/web_release_smoke.sh —— AC-08 环境验收**准备件**
# ================================================================
# 负责人批复（2026-10-16）：「研发可**同时准备**环境验收脚本、记录模板
# 和 Boss 招式视觉 Golden，**但不把它们标记为最终通过**。」
#
# 本脚本**只记录可测事实**，不打印"通过/不通过"的结论 ——
# 因为 AC-08 的判定包含**真实浏览器的人工操作**（音效手势解锁、断网重试、
# 缓存更新），脚本无法替代。判定请写入 docs/环境验收准备件.md 的模板。
#
# 用法：
#   bash tool/web_release_smoke.sh [端口，默认 8123]
# 产出：
#   build/web_smoke_record.txt
# ================================================================
set -uo pipefail

PORT="${1:-8123}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REC="build/web_smoke_record.txt"
mkdir -p build

{
  echo "# AC-08 Web Release 冒烟记录（脚本产出，**未经人工复核**）"
  echo "时间: $(date -Iseconds)"
  echo "构建 revision: $(git rev-parse HEAD 2>/dev/null || echo '未知')"
  echo "构建工作区是否干净: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') 个改动"
  echo
} > "$REC"

echo "[1/4] 构建 Web release …"
if flutter build web --release >>"$REC" 2>&1; then
  echo "构建: 成功" >> "$REC"
else
  echo "构建: **失败**（见上）" >> "$REC"
fi

echo "[2/4] 记录产物规模 …"
{
  echo
  echo "## 产物规模"
  if [ -d build/web ]; then
    echo "build/web 总大小: $(du -sh build/web | cut -f1)"
    echo
    echo "首屏关键文件（字节）:"
    for f in index.html flutter_bootstrap.js main.dart.js flutter_service_worker.js; do
      if [ -f "build/web/$f" ]; then
        printf '  %-28s %s\n' "$f" "$(wc -c < "build/web/$f" | tr -d ' ')"
      else
        printf '  %-28s %s\n' "$f" "（不存在）"
      fi
    done
    echo
    echo "main.dart.js 是否已 gzip 压缩包: $(ls build/web/main.dart.js* 2>/dev/null | tr '\n' ' ')"
  else
    echo "build/web 不存在 —— 构建未成功。"
  fi
} >> "$REC"

echo "[3/4] 本地起服并探测关键路径 …"
( python3 -m http.server "$PORT" --directory build/web >/dev/null 2>&1 & echo $! > build/.web_smoke_pid )
sleep 3
{
  echo
  echo "## 本地可达性（端口 ${PORT}）"
  for p in / /flutter_bootstrap.js /main.dart.js; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}$p" || echo 'ERR')
    printf '  %-24s HTTP %s\n' "$p" "$code"
  done
} >> "$REC"

echo "[4/4] 关闭本地服务 …"
if [ -f build/.web_smoke_pid ]; then
  kill "$(cat build/.web_smoke_pid)" 2>/dev/null || true
  rm -f build/.web_smoke_pid
fi

{
  echo
  echo "## 未由本脚本覆盖（必须人工/真实浏览器）"
  echo "- Chrome / Safari / Edge 各最近两个大版本的实际加载"
  echo "- 音频手势解锁"
  echo "- 断网：首次加载失败须显示进度与重试；已进入对局后断网不得中断本局"
  echo "- 缓存更新不阻断进行中的对局"
  echo
  echo "判定请写入 docs/环境验收准备件.md 的 AC-08 表格。"
} >> "$REC"

echo "完成 → $REC"
