// ================================================================
// lib/game/content/asset_id.dart —— 资源标识
//
// **架构位置**：Content（内容与代码的分界线） —— 产品数值、文案、素材绑定全部来自配置；本层负责读入、校验、提供类型安全访问。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：失败必须响亮（加载期抛错，禁止默认值兜底）· 文本只存在于 `strings_zh_CN.json`。
// ================================================================
// 依据：Spec/03_素材/Warship_v2.0素材清单与制作规范.md §1.1
//   「素材名称中的 Asset ID 是代码和配置唯一允许引用的稳定标识；
//     文件路径可版本化，但 Asset ID 不可改名或复用。」
// 以及 02_运行时与数据协议.md §7：
//   「资源用 AssetId 查表，不允许散落的字符串路径。」
//
// 因此：运行时代码与内容配置**只能**持有 AssetId，不得持有文件路径。
// 路径只存在于 manifest 内部，由 AssetLoader 负责解析。
// ================================================================

/// 一个稳定的资源标识（例如 `GFX-EN-SCOUT`、`SFX-PLAYER-PULSE`）。
///
/// 值对象：相等性按标识字符串判定，可直接作为 Map 键。
final class AssetId {
  /// 构造一个已校验的标识。
  ///
  /// 规则（素材规范 §1：ID 为大写字母、数字、`-`/`_`）：
  /// 非空、仅含 `A-Z0-9-_`。非法值会抛出 [FormatException]，
  /// 因为非法 ID 说明配置或代码写错了，属于必须尽早暴露的错误。
  AssetId(String value) : value = _validate(value);

  static final RegExp _pattern = RegExp(r'^[A-Z0-9][A-Z0-9_-]*$');

  /// 标识字符串。
  final String value;

  static String _validate(String value) {
    if (value.isEmpty) {
      throw const FormatException('AssetId 不能为空');
    }
    if (!_pattern.hasMatch(value)) {
      throw FormatException(
        'AssetId 只允许大写字母、数字、"-" 与 "_"，且以字母或数字开头：$value',
      );
    }
    return value;
  }

  /// 无异常解析：用于校验器逐条收集错误而不是中断。
  static AssetId? tryParse(String? value) {
    if (value == null) {
      return null;
    }
    try {
      return AssetId(value);
    } on FormatException {
      return null;
    }
  }

  /// 该 ID 是否属于某个「斜杠组」前缀（素材规范 §1.1 的展开约定）。
  ///
  /// 例：`GFX-WPN-LASER-HEAD` 以 `GFX-WPN-LASER-` 为前缀。
  bool hasPrefix(String prefix) => value.startsWith(prefix);

  @override
  bool operator ==(Object other) => other is AssetId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
