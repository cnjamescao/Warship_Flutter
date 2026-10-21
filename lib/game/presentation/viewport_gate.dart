// ================================================================
// lib/game/presentation/viewport_gate.dart —— 最小视口门槛
// ================================================================
// **架构位置**：Presentation 层（纯函数 + 常量）。
//
// **为什么存在（WEB-T-02）**：
//   「1023×640、1024×639 **不进入 Playing** 且**不推进逻辑**；
//     1024×640、4:3、16:9、21:9 保持 `1920×1080` 逻辑世界、
//     HUD 与安全区完整。」
//
// **为什么门槛放在"能不能进对局"而不是"能不能绘制"**：
//   宽度不足时强行开打，玩家会**看不到 HUD 安全区**（右侧被裁），
//   血量/连击等关键信息消失 ✗ —— 那不是"小屏体验差"，是**信息缺失**。
//   因此宁可**明确拒绝**并提示调整窗口 ✓。
//
// **为什么宽度与高度分别判断**：
//   1023×640 只差 1 px 宽也不允许 ✓ —— 门槛是**硬边界**，
//   不做"差不多就行"的容差（容差会让边界测试失去意义 ✗）。
// ================================================================

import 'dart:ui' show Size;

/// 逻辑世界尺寸（产品基线 §2）。任何视口都映射到这个坐标系 ✓。
const double kLogicalViewportWidth = 1920;
const double kLogicalViewportHeight = 1080;

/// **最小可用视口**（WEB-T-02 的硬边界）。
const double kMinViewportWidth = 1024;
const double kMinViewportHeight = 640;

/// 该视口是否**允许进入对局**。
///
/// 严格小于门槛即拒绝：`1023×640` 与 `1024×639` 都必须为 `false` ✓。
bool isViewportSupported(Size size) =>
    size.width >= kMinViewportWidth && size.height >= kMinViewportHeight;

/// 该视口是否合法到可以**推进逻辑**（与上者同义，单独命名以便调用点自陈意图）。
bool canAdvanceLogic(Size size) => isViewportSupported(size);
