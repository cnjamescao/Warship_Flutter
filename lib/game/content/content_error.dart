// ================================================================
// lib/game/content/content_error.dart —— 结构化内容错误
//
// **架构位置**：Content（内容与代码的分界线） —— 产品数值、文案、素材绑定全部来自配置；本层负责读入、校验、提供类型安全访问。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：失败必须响亮（加载期抛错，禁止默认值兜底）· 文本只存在于 `strings_zh_CN.json`。
// 本文件定义"内容错误"的表达方式 —— 决定错误有多好排查：
//   * 错误必须携带足够上下文：哪个文件/ID/字段、期望什么、实际什么。只说"配置无效"等于没说
//   * 失败必须响亮且发生在加载期（架构 §7）—— 降级为"用默认值继续跑"会把配置错误变成难查的玩法异常
//   * 错误信息面向开发者可长可中文，但不得把内部 ID 直接展示给玩家
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §7
//   「内容配置校验失败 → Loading 显示"资源版本错误，请重试"；可返回首页；
//     记录具体 ID/字段；禁止开始对局。」
//
// 因此校验器不抛第一个异常就退出，而是**收集全部错误**后一次性返回，
// 让内容维护者一次看到所有问题，也让 CI 的 content_validate 有完整输出。
// ================================================================

/// 内容错误的分类，决定用户可见文案与是否阻断开局。
enum ContentErrorKind {
  /// 文件缺失或无法解析。
  fileMissing,

  /// JSON 结构不符合 Schema（字段缺失、类型错误、取值为负等）。
  schemaViolation,

  /// 内容版本不是当前唯一允许值。
  versionMismatch,

  /// 文件 hash 与 manifest 记录不一致。
  hashMismatch,

  /// 引用了不存在的 ID（资产、前置卡、敌人等）。
  unknownReference,

  /// 交叉引用语义非法（循环前置、互斥卡同时强制、波次秒重复等）。
  invalidReference,

  /// 超出产品预算（对象上限、单次生成规模等）。
  budgetExceeded,

  /// 缺少必备的安全要素（例如 Boss 攻击缺少预警）。
  missingTelegraph,
}

/// 一条内容错误。
class ContentError {
  const ContentError({
    required this.kind,
    required this.location,
    required this.message,
    this.assetId,
    this.field,
  });

  final ContentErrorKind kind;

  /// 出错位置，例如 `enemies.json#EN-SCOUT`。
  final String location;

  /// 人类可读说明。
  final String message;

  /// 相关资源 ID（若适用）。
  final String? assetId;

  /// 相关字段名（若适用）。
  final String? field;

  @override
  String toString() {
    final buffer = StringBuffer('[${kind.name}] $location');
    if (field != null) {
      buffer.write('.$field');
    }
    buffer.write('：$message');
    if (assetId != null) {
      buffer.write('（assetId=$assetId）');
    }
    return buffer.toString();
  }
}

/// 内容加载 / 校验的结果。
///
/// 使用"结果对象"而不是抛异常：加载失败是可预期的产品路径
/// （Loading 页要显示可重试错误），不是程序缺陷。
class ContentResult<T> {
  const ContentResult._(this.value, this.errors);

  /// 成功。
  factory ContentResult.success(T value) =>
      ContentResult<T>._(value, const <ContentError>[]);

  /// 失败（可能携带多条错误）。
  factory ContentResult.failure(List<ContentError> errors) {
    assert(errors.isNotEmpty, '失败结果必须至少携带一条错误');
    return ContentResult<T>._(null, List<ContentError>.unmodifiable(errors));
  }

  final T? value;
  final List<ContentError> errors;

  bool get isSuccess => value != null;
  bool get isFailure => !isSuccess;

  /// 取出成功值；失败时抛 [StateError]（调用方应先判 [isSuccess]）。
  T get requireValue {
    final v = value;
    if (v == null) {
      throw StateError('内容加载失败，不能取值：\n${errors.join('\n')}');
    }
    return v;
  }

  /// 汇总为可读文本，用于日志与测试断言。
  String describeErrors() => errors.map((e) => e.toString()).join('\n');
}
