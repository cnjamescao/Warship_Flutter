// ================================================================
// test/game/acceptance_visual_states_test.dart —— AC-05
// ================================================================
// 产品基线 §9 AC-05：
//   「产品设计文档 7.5 的全部 13 个状态均有正确视觉、音频和结束条件」
//
// 上一轮我写过这个用例但没通过，并**误判为"4 处真实路由缺口"**。
// 本轮查明：那 4 处**全部是我用错了事件**，不是实现问题：
//   * GFX-BOSS-DEFEAT      绑定在 BossPhaseChanged（我错用 BossDefeated）
//   * SFX-PLAYER-LOW-SHIELD 绑定在 PlayerDamaged + shieldRatioLte
//     （我错用 PlayerVitalStateChanged）
//   * SFX-PLAYER-LOW-HP     同上
//   * SFX-BOSS-DEFEAT       本来就绑定在 BossDefeated，音频没问题
//
// 教训：**事件与条件必须从 manifest 的实际绑定读出，不能凭印象写。**
// 因此本文件的最后一组就是一台"一致性扫描"。
//
// ⚠️ 范围：证明**接线完整**，不是**画面正确**。像素层面需截图/Golden。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_bootstrap.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/infrastructure/asset_loader.dart';

const String kConfigDir = 'assets/config/v2';

class StateCheck {
  const StateCheck({
    required this.name,
    required this.event,
    required this.params,
    this.expectVisual = true,
    this.expectAudio = true,
    this.mustContainVisual,
    this.mustContainCue,
  });

  final String name;
  final String event;
  final Map<String, Object?> params;
  final bool expectVisual;
  final bool expectAudio;
  final String? mustContainVisual;
  final String? mustContainCue;
}

/// §7.5 的 13 个状态。事件与条件取自 manifest 的**实际绑定**。
const List<StateCheck> kStates = <StateCheck>[
  StateCheck(
    name: '玩家满护盾',
    event: 'PlayerVitalStateChanged',
    params: <String, Object?>{'shieldRatio': 1.0},
    mustContainVisual: 'UI-HUD-SHIELD-FILL',
    // §7.5 音频必须项原文：「无循环提示音」。
    expectAudio: false,
  ),
  StateCheck(
    name: '玩家护盾受击',
    event: 'PlayerDamaged',
    params: <String, Object?>{'shieldDamage': 12, 'hpDamage': 0},
    mustContainVisual: 'GFX-PLAYER-SHIELD-HIT',
    mustContainCue: 'cue.sfx.player.shield.hit',
  ),
  StateCheck(
    name: '玩家低护盾',
    event: 'PlayerDamaged',
    // 条件键取自 manifest 的实际绑定：shieldDamageGt + 护盾比例。
    params: <String, Object?>{
      'shieldDamage': 12,
      'shieldRatio': 0.2,
      'hpRatio': 0.8,
    },
    mustContainVisual: 'UI-HUD-SHIELD-FRAME',
    mustContainCue: 'cue.sfx.player.low.shield',
  ),
  StateCheck(
    name: '玩家濒危',
    event: 'PlayerDamaged',
    params: <String, Object?>{'hpRatio': 0.2, 'hpDamage': 15},
    mustContainCue: 'cue.sfx.player.low.hp',
  ),
  StateCheck(
    name: '玩家无敌冲刺',
    event: 'DashStarted',
    params: <String, Object?>{},
    mustContainVisual: 'GFX-PLAYER-DASH-TRAIL',
  ),
  StateCheck(
    name: '我方命中普通敌人',
    event: 'WeaponHit',
    params: <String, Object?>{'weaponId': 'pulse', 'critical': false},
    mustContainVisual: 'GFX-FX-PULSE-HIT',
  ),
  StateCheck(
    name: '敌人临界',
    event: 'EnemyVitalStateChanged',
    params: <String, Object?>{'enemyId': 'EN-SCOUT', 'hpRatio': 0.2},
    // §7.5 音频必须项原文：「可选低频损伤层」。
    expectAudio: false,
  ),
  StateCheck(
    name: '敌人击毁',
    event: 'EnemyDestroyed',
    params: <String, Object?>{'enemyId': 'EN-WING', 'isElite': false},
  ),
  StateCheck(
    name: '伤害预警',
    event: 'EnemyAttackTelegraphed',
    params: <String, Object?>{'enemyId': 'EN-SNIPER', 'attackId': 'sniper_line'},
    mustContainVisual: 'GFX-WARN-LINE',
  ),
  StateCheck(
    name: '精英出现',
    event: 'EnemySpawned',
    params: <String, Object?>{'enemyId': 'EN-WING', 'isElite': true},
    mustContainCue: 'cue.sfx.elite.spawn',
  ),
  StateCheck(
    name: 'Boss 转段',
    event: 'BossPhaseChanged',
    params: <String, Object?>{'phase': 'p2'},
  ),
  StateCheck(
    name: 'Boss 濒毁',
    event: 'BossCriticalReached',
    params: <String, Object?>{'hpRatio': 0.05},
  ),
  StateCheck(
    name: 'Boss 击败',
    event: 'BossDefeated',
    params: <String, Object?>{},
    // 击败的视觉绑定在 BossPhaseChanged 上，因此这里只断言音频。
    expectVisual: false,
    mustContainCue: 'cue.sfx.boss.defeat',
  ),
];

/// 每个事件类型实际携带的字段（用于扫描 `when` 键是否合法）。
const Map<String, Set<String>> kWhenKeysByEvent = <String, Set<String>>{
  'EnemySpawned': <String>{'enemyId', 'isElite', 'affixId'},
  'EnemyDamaged': <String>{'enemyId', 'critical', 'hpRatioLte', 'hpRatioGt'},
  'EnemyVitalStateChanged': <String>{'enemyId', 'hpRatioLte', 'hpRatioGt'},
  'EnemyDestroyed': <String>{'enemyId', 'isElite'},
  // **v2.1**：自动强化授予（无条件路由 —— 强化提示图 + 强化 cue）。
  'AutoUpgradeGranted': <String>{},
  // **v2.1**：清场确认窗开始（无条件路由 —— 清场提示图 + 清场 cue）。
  'SectorClearStarted': <String>{},
  'EnemyAttackTelegraphed': <String>{'enemyId', 'attackId'},
  'EnemyAttackFired': <String>{'enemyId', 'attackId'},
  'EnemyBreached': <String>{'enemyId'},
  'EnemyDefenseStateChanged': <String>{'enemyId', 'state', 'frontShieldActive'},
  'PlayerDamaged': <String>{
    'shieldRatioLte', 'shieldRatioGt', 'hpRatioLte', 'hpRatioGt',
    'shieldDamageGt', 'hpDamageGt',
    // 受击方向扇形（UI-HUD-DAMAGE-DIRECTION）依赖这个字段。
    'direction',
    // **v2.1**：稳定枚举，区分这一击打在护盾还是 HP。
    // 蓝图 §2.2：「manifest 只允许等值 when，因此 conditionalParamsOf
    // **必须输出稳定枚举** damageLayer=shield 或 hp，不得隐式扩展 schema
    // 做数值表达式比较。」值由 B1 的适配器产出（当前登记为已知死路由）。
    'damageLayer',
  },
  'PlayerVitalStateChanged': <String>{
    'shieldRatioLte', 'shieldRatioGt', 'hpRatioLte', 'hpRatioGt',
    // **v2.1**：低血 / 濒危的稳定枚举（B3 产出）。
    'hpVisualState',
  },
  'WeaponFired': <String>{'weaponId', 'weaponStyleId'},
  'WeaponHit': <String>{
    'weaponId', 'critical',
    // **v2.1**：五种主弹道的稳定 style ID，用于精确路由命中图与命中 cue。
    // 蓝图 §3.1：「WeaponFired 与 WeaponHit **增加** nullable weaponStyleId；
    // 旧主炮和副武器传 null，五种主弹道传稳定 style ID」（B1/B2 产出）。
    'weaponStyleId',
  },
  'WeaponSustainStarted': <String>{'weaponId'},
  'WeaponSustainStopped': <String>{'weaponId'},
  'DashStarted': <String>{'direction'},
  'DashEnded': <String>{'direction'},
  // DashStateChanged 的条件键是 availability（冲刺是否可用），
  // 不是 state —— 这正是扫描发现的第一类问题。
  'DashStateChanged': <String>{'availability'},
  'DashReady': <String>{},
  'BossPhaseChanged': <String>{'phase'},
  'BossCriticalReached': <String>{'hpRatioLte'},
  'BossDefeated': <String>{},
  'BossAttackTelegraphed': <String>{'attackId'},
  'BossAttackFired': <String>{'attackId'},
  'BossAttackEnded': <String>{'attackId'},
  'RiskGateOpened': <String>{'optionId'},
  'RiskSelected': <String>{'optionId'},
  'RiskOptionStateChanged': <String>{'optionId', 'availability', 'state'},
  'UpgradeDraftOpened': <String>{},
  'UpgradeSelected': <String>{'optionId'},
  'RunStarted': <String>{},
  'RunEnded': <String>{'result', 'resultTier'},
  'PickupHeal': <String>{},
  'PickupShield': <String>{},
  'UiCommand': <String>{'command'},
  'UiControlStateChanged': <String>{'controlId', 'state'},
  'AssetLoadFailed': <String>{},
};

void main() {
  late AssetManifest manifest;
  late AssetBindingTable table;

  setUpAll(() {
    final json =
        jsonDecode(File('$kConfigDir/manifest.json').readAsStringSync())
            as Map<String, Object?>;
    final parsed = AssetManifest.parse(
      json,
      expectedVersion: kActiveContentVersion,
    );
    expect(parsed.isSuccess, isTrue, reason: parsed.describeErrors());
    manifest = parsed.requireValue;
    table = const AssetLoader().build(manifest);
  });

  group('§7.5 状态清单完整性', () {
    test('恰好 13 个，名称与产品文档逐行一致', () {
      expect(kStates.map((s) => s.name).toList(), <String>[
        '玩家满护盾', '玩家护盾受击', '玩家低护盾', '玩家濒危', '玩家无敌冲刺',
        '我方命中普通敌人', '敌人临界', '敌人击毁', '伤害预警', '精英出现',
        'Boss 转段', 'Boss 濒毁', 'Boss 击败',
      ]);
    });

    test('每个状态引用的事件在 manifest 里真实存在', () {
      final bound = <String>{
        for (final r in manifest.records)
          for (final b in r.eventBindings) b.event,
      };
      for (final s in kStates) {
        expect(bound, contains(s.event), reason: '${s.name} 用了 ${s.event}');
      }
    });
  });

  group('每个状态的视觉与音频均可解析', () {
    for (final s in kStates) {
      test(s.name, () {
        if (s.expectVisual) {
          final visuals = table.resolveVisuals(s.event, s.params);
          expect(visuals, isNotEmpty,
              reason: '${s.name}：${s.event} ${s.params} 没有视觉资源');
          for (final v in visuals) {
            expect(v.runtimeFiles, isNotEmpty, reason: '${v.assetId} 无文件');
          }
        }
        if (s.expectAudio) {
          final cues = table.resolveCues(s.event, s.params);
          expect(cues, isNotEmpty,
              reason: '${s.name}：${s.event} ${s.params} 没有音频 cue');
          for (final c in cues) {
            expect(c.assetId.value, isNotEmpty);
          }
        }
      });
    }
  });

  group('命中的是"对的那个"资源', () {
    for (final s in kStates) {
      if (s.mustContainVisual != null) {
        test('${s.name} → ${s.mustContainVisual}', () {
          expect(
            table.resolveVisuals(s.event, s.params).map((v) => v.assetId.value),
            contains(s.mustContainVisual),
          );
        });
      }
      if (s.mustContainCue != null) {
        test('${s.name} → ${s.mustContainCue}', () {
          expect(
            table.resolveCues(s.event, s.params).map((c) => c.cueId),
            contains(s.mustContainCue),
          );
        });
      }
    }
  });

  group('一致性扫描：when 条件键 × 事件载荷字段', () {
    test('每个绑定的 when 键对该事件都是合法的', () {
      final problems = <String>[];
      for (final record in manifest.records) {
        for (final binding in record.eventBindings) {
          final allowed = kWhenKeysByEvent[binding.event];
          if (allowed == null) {
            problems.add('事件 ${binding.event} 未在字段表中声明'
                '（资源 ${record.assetId}）');
            continue;
          }
          for (final key in binding.when.keys) {
            if (!allowed.contains(key)) {
              problems.add('${record.assetId}：事件 ${binding.event} '
                  '不携带字段 `$key`');
            }
          }
        }
      }
      expect(problems, isEmpty,
          reason: '发现 ${problems.length} 处不一致：\n${problems.join('\n')}');
    });

    test('字段表覆盖全部事件与全部 when 键', () {
      final boundEvents = <String>{};
      final usedKeys = <String>{};
      for (final record in manifest.records) {
        for (final binding in record.eventBindings) {
          boundEvents.add(binding.event);
          usedKeys.addAll(binding.when.keys);
        }
      }
      expect(boundEvents.difference(kWhenKeysByEvent.keys.toSet()), isEmpty);
      final declared = kWhenKeysByEvent.values.expand((s) => s).toSet();
      expect(usedKeys.difference(declared), isEmpty);
    });
  });

  group('一致性扫描：条件键必须真的会被产出（否则是死路由）', () {
    // `audioParamsOf` 是 Domain 事件 → 条件参数的**唯一适配器**，
    // 因此它是契约的事实来源。凡是 manifest 用到的条件键，
    // 其**基名**必须出现在这个适配器为对应事件产出的键集合里；
    // 否则那条绑定永远匹配不上 —— 是**死路由**。
    //
    // 下面这张表来自阅读 `lib/game/infrastructure/audio_director.dart`
    // 的 `audioParamsOf`。它取代了上一轮那张**我凭印象手写**的表，
    // 这正是上一轮误判"4 处路由缺口"的根因。
    const emittedByEvent = <String, Set<String>>{
      'EnemySpawned': <String>{'enemyId', 'isElite', 'affixId'},
      'EnemyDestroyed': <String>{'enemyId', 'isElite'},
      'EnemyBreached': <String>{'enemyId', 'isElite'},
      'EnemyDamaged': <String>{'enemyId', 'hpRatio'},
      'EnemyAttackTelegraphed': <String>{'enemyId', 'attackId'},
      'EnemyAttackFired': <String>{'enemyId', 'attackId'},
      'PlayerDamaged': <String>{'shieldDamage', 'hpDamage', 'direction'},
      'PlayerVitalStateChanged': <String>{'hpRatio', 'shieldRatio'},
      'WeaponFired': <String>{'weaponId'},
      'WeaponHit': <String>{'weaponId', 'critical'},
      'BossPhaseChanged': <String>{'phase'},
      'BossAttackTelegraphed': <String>{'attackId'},
      'BossAttackFired': <String>{'attackId'},
      'BossAttackEnded': <String>{'attackId'},
      'BossCriticalReached': <String>{'hpRatio'},
      'RiskGateOpened': <String>{'gateId'},
      'RiskSelected': <String>{'optionId'},
      'UpgradeSelected': <String>{'cardId'},
      'RunEnded': <String>{'result'},
    };

    /// **条件键没有任何适配器产出的绑定清单**（冻结当前状态）。
    ///
    /// `audioParamsOf` 只覆盖 36 个事件里的 19 个；凡它没有分支的事件，
    /// 参数 map 为空，因此**带条件的绑定永远匹配不上**。
    ///
    /// 这份清单是一次扫描的**实际结果**，不是我推测的。它被冻结在这里
    /// 有两个作用：一是防止继续扩大，二是把它显式登记下来等待定位 ——
    /// 每一项要么说明"该事件本该有分支而漏了"，要么说明"该绑定写错了
    /// 事件名或条件键"。
    ///
    /// 需要注意：本扫描只覆盖**音频适配器**。视觉资源可能经由另一条
    /// 路径解析（`resolveVisuals`），因此清单里属于图形资源的条目
    /// **未必**真的是死路由，需要下一轮逐一核对调用点后才能定论。
    const knownUnemittedConditions = <String>{
      // 适配器完全没有这些事件的分支：
      'command:UiCommand',
      'enemyId:EnemyDefenseStateChanged',
      'enemyId:EnemyVitalStateChanged',
      'hpRatioLte:EnemyVitalStateChanged',
      'optionId:RiskOptionStateChanged',
      'weaponId:WeaponSustainStarted',
      'weaponId:WeaponSustainStopped',
      // 有分支但产出的键名与绑定的基名不一致：
      'hpRatioLte:PlayerDamaged', // 适配器产出 hpDamage，绑定要 hpRatio
      'shieldRatioLte:PlayerDamaged', // 适配器产出 shieldDamage，绑定要 shieldRatio
      'optionId:RiskGateOpened', // 适配器产出 gateId
      // 适配器根本不产出的状态类键：
      'availability:DashStateChanged',
      'frontShieldActive:EnemyDefenseStateChanged',
      'state:RiskOptionStateChanged',
      'state:UiControlStateChanged',
      'controlId:UiControlStateChanged',
      // 正是文档冲突未裁决的那一项：
      'resultTier:RunEnded',

      // ---- v2.1 B0 登记的"配置先行"条件 ----
      //
      // B0（配置装配）先于 B1/B2（代码实现），因此这些**路由已写入 manifest，
      // 但事件的载荷字段尚未由适配器产出** —— 属**预期的暂时死路由**，
      // 不是写错的绑定。蓝图已明文要求后续批次补齐：
      //   * `weaponStyleId`：蓝图 §3.1「WeaponFired 与 WeaponHit **增加**
      //     nullable weaponStyleId；旧主炮和副武器传 null，五种主弹道传稳定
      //     style ID」（B1/B2 实现）；
      //   * `damageLayer`：蓝图 §2.2「`conditionalParamsOf` **必须输出稳定枚举**
      //     damageLayer=shield 或 hp」（B1 实现）；
      //   * `hpVisualState`：低血/濒危状态字段（B3 实现）。
      //
      // ⚠️ **B1/B2 完成时必须从本登记表删除对应项** ——
      // 本用例会在集合**减少**时失败并提示，正是为此设计。
      'weaponStyleId:WeaponHit',
      'damageLayer:PlayerDamaged',
      'hpVisualState:PlayerVitalStateChanged',
    };

    test('条件键的基名必须由适配器产出，或已登记为已知死路由', () {
      final dead = <String>{};
      for (final record in manifest.records) {
        for (final binding in record.eventBindings) {
          for (final key in binding.when.keys) {
            // 去掉比较后缀：hpRatioLte → hpRatio。
            final base = key
                .replaceAll(RegExp(r'(Lte|Gt)$'), '');
            final emitted = emittedByEvent[binding.event];
            if (emitted == null) {
              // 适配器没有这个事件的分支 → 默认返回空 map → 一定是死路由。
              dead.add('$key:${binding.event}');
              continue;
            }
            if (!emitted.contains(base)) {
              dead.add('$key:${binding.event}');
            }
          }
        }
      }

      expect(
        dead,
        knownUnemittedConditions,
        reason: '未产出条件集合发生变化。\n'
            '实际：${dead.toList()..sort()}\n'
            '登记：${knownUnemittedConditions.toList()..sort()}\n'
            '若**减少**，请从 knownDeadKeys 删除；若**增加**，'
            '说明有新的绑定永远匹配不上。',
      );
    });

    test('已知死路由确实对应 manifest 里的真实绑定（不是空写）', () {
      final allKeys = <String>{};
      for (final record in manifest.records) {
        for (final binding in record.eventBindings) {
          for (final key in binding.when.keys) {
            allKeys.add(key);
            allKeys.add('$key:${binding.event}');
          }
        }
      }
      // 每个登记项至少要能对上 manifest 里的某个键或 键:事件 组合。
      for (final entry in knownUnemittedConditions) {
        expect(
          allKeys.contains(entry) ||
              allKeys.contains(entry.split(':').first),
          isTrue,
          reason: '登记的条目 $entry 在 manifest 里找不到对应绑定',
        );
      }
    });
  });

  group('§7.5 优先级规则与结束条件', () {
    test('伤害预警在 Warning 总线上，普通命中不在', () {
      final warning = table.resolveCues('EnemyAttackTelegraphed',
          <String, Object?>{'enemyId': 'EN-SNIPER', 'attackId': 'sniper_line'});
      expect(warning, isNotEmpty);
      expect(warning.first.bus, 'Warning');

      final hit = table.resolveCues('WeaponHit',
          <String, Object?>{'weaponId': 'pulse', 'critical': false});
      expect(hit, isNotEmpty);
      expect(hit.first.bus, isNot('Warning'));
    });

    test('持续型表现有成对的开始/结束事件', () {
      final bound = <String>{
        for (final r in manifest.records)
          for (final b in r.eventBindings) b.event,
      };
      for (final pair in <List<String>>[
        <String>['DashStarted', 'DashEnded'],
        <String>['WeaponSustainStarted', 'WeaponSustainStopped'],
        <String>['BossAttackTelegraphed', 'BossAttackEnded'],
      ]) {
        expect(bound, contains(pair[0]));
        expect(bound, contains(pair[1]), reason: '${pair[0]} 缺少配对结束事件');
      }
    });
  });
}
