#!/usr/bin/env bash
# ================================================================
# tool/release_dual.sh —— 双端候选发布（W0 合同 + CI 骨架）
# ================================================================
# 存在理由：双端发布的核心不是"两端都能构建"，而是**两端由同一份输入构建**
# 且**任一端失败就整体退回候选态**（双端发布需求 §3.2 的原子性）。
# 手敲两条 flutter build 无法保证这一点 —— 所以固化成脚本。
#
# 用法：
#   bash tool/release_dual.sh            # 完整：构建两端 + 生成 manifest + 校验
#   bash tool/release_dual.sh --verify    # 只校验已有产物（CI 复用）
#   WEB_BASE_HREF=/game/ bash tool/release_dual.sh   # 子路径托管
#
# 退出码：0 = 双端就绪；非 0 = **整个 RC 不得发布**。
# ================================================================
set -euo pipefail

OUT=build/release
BASE_HREF="${WEB_BASE_HREF:-/}"
MODE="${1:-full}"

echo "== 双端候选发布 =="
echo "   commit     : $(git rev-parse --short HEAD)"
echo "   baseHref   : $BASE_HREF"
echo

if [ "$MODE" != "--verify" ]; then
  # ── 1. macOS Release ──────────────────────────────────────────
  echo "[1/4] 构建 macOS Release ..."
  flutter build macos --release
  MACOS_APP="build/macos/Build/Products/Release/warship_flutter.app"
  [ -d "$MACOS_APP" ] || { echo "✗ macOS 产物缺失" >&2; exit 1; }

  # ── 2. Web Release（WASM）────────────────────────────────────
  echo "[2/4] 构建 Web Release（WASM）..."
  flutter build web --release --wasm --base-href "$BASE_HREF"

  WEB_DIR="build/web"
  [ -d "$WEB_DIR" ] || { echo "✗ Web 产物缺失" >&2; exit 1; }

  # WEB-T-01：WASM 产物必须真实存在（不能靠 JS 兜底充数）
  for f in main.dart.mjs main.dart.wasm flutter_service_worker.js; do
    if [ ! -f "$WEB_DIR/$f" ]; then
      echo "✗ Web 产物缺少 $f（WEB-T-01 要求 WASM 构建）" >&2
      exit 1
    fi
  done

  # ── 3. 打包 + 生成 manifest ──────────────────────────────────
  echo "[3/4] 打包 Web 归档 + 生成 manifest ..."
  mkdir -p "$OUT/macos" "$OUT/web"
  # macOS：`.app` 目录打成 zip（shasum 需要一个文件）
  (cd "$(dirname "$MACOS_APP")" && zip -qr \
      "$OLDPWD/$OUT/macos/warship_flutter.app.zip" "$(basename "$MACOS_APP")")
  # Web：整个 build/web 打成 zip（不可拆分的静态目录）
  (cd "$WEB_DIR" && zip -qr "$OLDPWD/$OUT/web/web.zip" .)

  # **两端 SHA 都要算**：第 5/6 个参数分别是 macos / web 产物路径。
  dart run tool/build_release_manifest.dart macos \
      "$OUT/macos/warship_flutter.app.zip" "$OUT/macos" "$BASE_HREF" \
      "$OUT/macos/warship_flutter.app.zip" "$OUT/web/web.zip"
  dart run tool/build_release_manifest.dart web \
      "$OUT/web/web.zip" "$OUT/web" "$BASE_HREF" \
      "$OUT/macos/warship_flutter.app.zip" "$OUT/web/web.zip"
else
  echo "[跳过构建] 只做校验"
fi

# ── 4. 双端身份校验（DUAL-T-01/03）─────────────────────────────
echo "[4/4] 校验双端身份（DUAL-T-01/03）..."
dart run tool/verify_dual_release.dart \
    "$OUT/macos/release-manifest.json" \
    "$OUT/web/release-manifest.json"

# ── 5. 静态托管探测（WEB-T-06）────────────────────────────────
echo "[5/5] 静态托管探测（WEB-T-06）..."
dart run tool/probe_web_hosting.dart build/web "$BASE_HREF"

echo
echo "✅ 双端候选就绪：$OUT/{macos,web}"
echo "   下一步（W3）：静态托管探测 + 双端人工证据归档后才能标记发布。"
