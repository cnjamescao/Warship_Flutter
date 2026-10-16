#!/usr/bin/env bash
# ================================================================
# tool/release_perf_sample.sh —— AC-07 真机性能**准备件**
# ================================================================
# 负责人批复（2026-10-16）：「研发可**同时准备**环境验收脚本、记录模板
# 和 Boss 招式视觉 Golden，**但不把它们标记为最终通过**。」
#
# ⚠️ **本脚本无法产出帧时间数据** —— 这是必须说清楚的边界：
#   * Release 构建没有 observatory，脚本取不到逐帧时间；
#   * AC-07 要求的 `p50/p95/p99 帧时间、最低瞬时帧率` 必须由
#     **真实设备 + 人工采样**获得（例如 Instruments 的
#     Core Animation / Time Profiler）。
#
# 因此本脚本只做两件**可自动化**的事：
#   1. 产出 Release 构建并记录**环境与构建元数据**（模板要求的字段）；
#   2. 校验构建产物确实是 release（避免误用 debug 数据充数）。
# 帧时间等字段留空，由操作员填写。
#
# 用法：
#   bash tool/release_perf_sample.sh [采样秒数，默认 180]
# 产出：
#   build/perf_sample_record.md
# ================================================================
set -uo pipefail

SECONDS_TO_SAMPLE="${1:-180}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REC="build/perf_sample_record.md"
mkdir -p build

echo "[1/3] 构建 macOS release …"
BUILD_OK=1
flutter build macos --release > build/.perf_build.log 2>&1 || BUILD_OK=0

APP="build/macos/Build/Products/Release/warship_flutter.app"
BIN="$APP/Contents/MacOS/warship_flutter"

{
  echo "# AC-07 真机性能记录（脚本填写元数据；**帧时间须人工采样**）"
  echo
  echo "| 字段 | 取值 |"
  echo "| --- | --- |"
  echo "| 采样日期 | $(date -Iseconds) |"
  echo "| 设备 / 型号 | **待人工填写** |"
  echo "| OS 版本 | $(sw_vers -productVersion 2>/dev/null || echo '未知') ($(sw_vers -buildVersion 2>/dev/null || echo '')) |"
  echo "| CPU | $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '未知') |"
  echo "| 内存 | $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB |"
  echo "| 构建 revision | $(git rev-parse HEAD 2>/dev/null || echo '未知') |"
  echo "| 构建类型 | release |"
  echo "| 构建是否成功 | $([ "$BUILD_OK" = 1 ] && echo '是' || echo '**否**（见 build/.perf_build.log）') |"
  echo "| 产物是否为 release | $([ -f "$BIN" ] && echo "是（$APP）" || echo '**未找到 Release 产物**') |"
  echo "| 采样时长 | ${SECONDS_TO_SAMPLE} 秒（脚本等待；帧时间由人工采集） |"
  echo "| 帧时间 p50 / p95 / p99 | **待人工填写**（Instruments） |"
  echo "| 最低瞬时帧率 | **待人工填写** |"
  echo "| 峰值内存 | **待人工填写** |"
  echo "| 峰值实体数 | **待人工填写** |"
  echo "| 录屏路径 | **待人工填写** |"
  echo "| 操作员 | **待人工填写** |"
  echo
  echo "## 结论"
  echo "**未判定** —— 本文件不含任何通过/不通过结论；"
  echo "判定请写入 docs/环境验收准备件.md 的 AC-07 表格。"
} > "$REC"

echo "[2/3] 启动 Release 构建并等待 ${SECONDS_TO_SAMPLE} 秒（供人工采样）…"
if [ "$BUILD_OK" = 1 ] && [ -x "$BIN" ]; then
  pkill -f "warship_flutter.app" 2>/dev/null || true
  sleep 1
  open "$APP"
  echo "已启动：操作员可在此期间用 Instruments 采样。"
  sleep "$SECONDS_TO_SAMPLE"
else
  echo "构建失败或产物缺失，未启动。"
fi

echo "[3/3] 记录完毕 → $REC"
