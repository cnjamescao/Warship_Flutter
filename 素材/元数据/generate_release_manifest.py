"""Produce the release-facing manifest used by the runtime content loader."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
PACK = HERE.parent

spec = importlib.util.spec_from_file_location("graphics", HERE / "generate_runtime_graphics.py")
graphics = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(graphics)

states_spec = importlib.util.spec_from_file_location("states", HERE / "generate_runtime_state_variants.py")
states = importlib.util.module_from_spec(states_spec)
assert states_spec and states_spec.loader
states_spec.loader.exec_module(states)

web_spec = importlib.util.spec_from_file_location("web_backgrounds", HERE / "generate_web_background_variants.py")
web_backgrounds = importlib.util.module_from_spec(web_spec)
assert web_spec and web_spec.loader
web_spec.loader.exec_module(web_backgrounds)

RELEASE_DATE = "2026-10-14T00:00:00+08:00"
RELEASE_VERSION = "2.0.5-release"

ALL_GRAPHICS = [
    "GFX-PLAYER-BASE", *graphics.SHIPS, *graphics.PLAYER, *graphics.ELITE,
    "GFX-BOSS-AEGIS-BODY", *graphics.BOSS, *graphics.WEAPONS, *graphics.HAZARDS,
    *graphics.UPGRADES, *graphics.UI, *graphics.BACKGROUND,
]

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def graphic_path(asset_id: str) -> Path:
    return PACK / "图形" / "运行时PNG" / graphics.group(asset_id) / f"{asset_id}.png"


def bindings_for(asset_id: str) -> list[dict[str, object]]:
    """Exact runtime routing; an empty list means snapshot/UI-owned artwork."""
    if asset_id in {"GFX-WPN-PULSE", "GFX-WPN-PULSE-MUZZLE"}:
        return [{"event": "WeaponFired", "when": {"weaponId": "pulse"}, "renderState": "default"}]
    if asset_id == "GFX-FX-PULSE-HIT":
        return [{"event": "WeaponHit", "when": {"weaponId": "pulse", "critical": False}, "renderState": "default"}]
    if asset_id == "GFX-FX-PULSE-CRIT":
        return [{"event": "WeaponHit", "when": {"weaponId": "pulse", "critical": True}, "renderState": "default"}]
    if asset_id.startswith("GFX-WPN-MISSILE"):
        return [{"event": "WeaponFired", "when": {"weaponId": "missile"}, "renderState": "default"}]
    if asset_id == "GFX-FX-MISSILE-BLAST":
        return [{"event": "WeaponHit", "when": {"weaponId": "missile"}, "renderState": "default"}]
    if asset_id.startswith("GFX-WPN-LASER"):
        return [{"event": "WeaponFired", "when": {"weaponId": "laser"}, "renderState": "default"}]
    if asset_id.startswith("GFX-WPN-DRONE"):
        return [{"event": "WeaponFired", "when": {"weaponId": "drone"}, "renderState": "default"}]
    if asset_id == "GFX-WPN-ARC":
        return [{"event": "WeaponHit", "when": {"weaponId": "pulse", "critical": True}, "renderState": "default"}]
    if asset_id == "GFX-EN-SNIPER":
        return [
            {"event": "EnemySpawned", "when": {"enemyId": "EN-SNIPER"}, "renderState": "idle"},
            {"event": "EnemyAttackTelegraphed", "when": {"enemyId": "EN-SNIPER", "attackId": "sniper_line"}, "renderState": "charge"},
            {"event": "EnemyDamaged", "when": {"enemyId": "EN-SNIPER"}, "renderState": "hit", "transientMs": 120, "restoreFromSnapshot": True},
            {"event": "EnemyVitalStateChanged", "when": {"enemyId": "EN-SNIPER", "hpRatioLte": 0.25}, "renderState": "critical"},
            {"event": "EnemyDestroyed", "when": {"enemyId": "EN-SNIPER"}, "renderState": "destroy"},
        ]
    if asset_id == "GFX-EN-BOMBER":
        return [
            {"event": "EnemySpawned", "when": {"enemyId": "EN-BOMBER"}, "renderState": "idle"},
            {"event": "EnemyAttackFired", "when": {"enemyId": "EN-BOMBER", "attackId": "bomber_drop"}, "renderState": "drop", "transientMs": 180, "restoreFromSnapshot": True},
            {"event": "EnemyDamaged", "when": {"enemyId": "EN-BOMBER"}, "renderState": "hit", "transientMs": 120, "restoreFromSnapshot": True},
            {"event": "EnemyVitalStateChanged", "when": {"enemyId": "EN-BOMBER", "hpRatioLte": 0.25}, "renderState": "critical"},
            {"event": "EnemyDestroyed", "when": {"enemyId": "EN-BOMBER"}, "renderState": "destroy"},
        ]
    if asset_id == "GFX-EN-SHIELD":
        return [
            {"event": "EnemySpawned", "when": {"enemyId": "EN-SHIELD"}, "renderState": "body"},
            {"event": "EnemyDefenseStateChanged", "when": {"enemyId": "EN-SHIELD", "frontShieldActive": True}, "renderState": "frontShield"},
            {"event": "EnemyDefenseStateChanged", "when": {"enemyId": "EN-SHIELD", "frontShieldActive": False}, "renderState": "body"},
            {"event": "EnemyDamaged", "when": {"enemyId": "EN-SHIELD"}, "renderState": "hit", "transientMs": 120, "restoreFromSnapshot": True},
            {"event": "EnemyVitalStateChanged", "when": {"enemyId": "EN-SHIELD", "hpRatioLte": 0.25}, "renderState": "critical"},
            {"event": "EnemyDestroyed", "when": {"enemyId": "EN-SHIELD"}, "renderState": "destroy"},
        ]
    if asset_id in graphics.SHIPS:
        return [
            {"event": "EnemySpawned", "when": {"enemyId": asset_id.removeprefix("GFX-")}, "renderState": "idle" if asset_id != "GFX-EN-SHIELD" else "body"},
            {"event": "EnemyDamaged", "when": {"enemyId": asset_id.removeprefix("GFX-")}, "renderState": "hit", "transientMs": 120, "restoreFromSnapshot": True},
            {"event": "EnemyVitalStateChanged", "when": {"enemyId": asset_id.removeprefix("GFX-"), "hpRatioLte": 0.25}, "renderState": "critical"},
            {"event": "EnemyDestroyed", "when": {"enemyId": asset_id.removeprefix("GFX-")}, "renderState": "destroy"},
        ]
    if asset_id == "GFX-PLAYER-SHIELD-HIT":
        return [{"event": "PlayerDamaged", "when": {"shieldDamageGt": 0}, "renderState": "active"}]
    if asset_id == "GFX-PLAYER-HIT-FLASH":
        return [{"event": "PlayerDamaged", "when": {"hpDamageGt": 0}, "renderState": "active"}]
    if asset_id == "GFX-PLAYER-ENGINE-CRITICAL":
        return [{"event": "PlayerVitalStateChanged", "when": {"hpRatioLte": 0.30}, "renderState": "active"}, {"event": "PlayerVitalStateChanged", "when": {"hpRatioGt": 0.35}, "renderState": "end"}]
    if asset_id == "GFX-PLAYER-DASH-TRAIL":
        return [{"event": "DashStarted", "when": {}, "renderState": "active"}, {"event": "DashEnded", "when": {}, "renderState": "end"}]
    if asset_id.startswith("GFX-ELITE-AURA-"):
        affix_id = "AFFIX-" + asset_id.removeprefix("GFX-ELITE-AURA-")
        return [{"event": "EnemySpawned", "when": {"isElite": True, "affixId": affix_id}, "renderState": "default"}]
    if asset_id == "UI-ELITE-NAMEPLATE":
        return [{"event": "EnemySpawned", "when": {"isElite": True}, "renderState": "normal"}]
    if asset_id.startswith("UI-ELITE-AFFIX-"):
        affix_id = "AFFIX-" + asset_id.removeprefix("UI-ELITE-AFFIX-")
        return [{"event": "EnemySpawned", "when": {"isElite": True, "affixId": affix_id}, "renderState": "normal"}]
    if asset_id == "GFX-BOSS-AEGIS-BODY":
        return [{"event": "BossPhaseChanged", "when": {"phase": "p1"}, "renderState": "p1"}]
    if asset_id == "GFX-BOSS-AEGIS-WEAKPOINT":
        return [{"event": "BossPhaseChanged", "when": {"phase": "p3"}, "renderState": "shown"}]
    if asset_id == "GFX-BOSS-AEGIS-CRITICAL":
        return [{"event": "BossCriticalReached", "when": {"hpRatioLte": 0.10}, "renderState": "default"}]
    if asset_id.startswith("GFX-BOSS") and asset_id not in {"GFX-BOSS-FAN-BULLET", "GFX-BOSS-RING-BULLET", "GFX-BOSS-LASER"}:
        return [{"event": "BossPhaseChanged", "when": {}, "renderState": "default"}]
    if asset_id.startswith("UI-BOSS"):
        return [{"event": "BossPhaseChanged", "when": {}, "renderState": "normal"}]
    if asset_id.startswith("GFX-PICKUP"):
        event = "PickupHeal" if asset_id.endswith("HEAL") else ("PickupShield" if asset_id.endswith("SHIELD") else "DashReady")
        return [{"event": event, "when": {}, "renderState": "default"}]
    if asset_id == "GFX-ENEMY-BREACH-WARN":
        return [{"event": "EnemyBreached", "when": {}, "renderState": "default"}]
    if asset_id == "GFX-ENEMY-BULLET-WING":
        return [{"event": "EnemyAttackFired", "when": {"enemyId": "EN-WING", "attackId": "wing_shot"}, "renderState": "default"}]
    if asset_id == "GFX-ENEMY-BULLET-SNIPER":
        return [{"event": "EnemyAttackFired", "when": {"enemyId": "EN-SNIPER", "attackId": "sniper_line"}, "renderState": "default"}]
    if asset_id == "GFX-ENEMY-BULLET-SHIELD":
        return [{"event": "EnemyAttackFired", "when": {"enemyId": "EN-SHIELD", "attackId": "shield_shot"}, "renderState": "default"}]
    if asset_id == "GFX-HAZARD-BOMBER-WARN":
        return [{"event": "EnemyAttackTelegraphed", "when": {"enemyId": "EN-BOMBER", "attackId": "bomber_drop"}, "renderState": "default"}]
    if asset_id == "GFX-HAZARD-BOMBER-ACTIVE":
        return [{"event": "EnemyAttackFired", "when": {"enemyId": "EN-BOMBER", "attackId": "bomber_drop"}, "renderState": "default"}]
    if asset_id == "GFX-WARN-LINE":
        return [{"event": "EnemyAttackTelegraphed", "when": {"enemyId": "EN-SNIPER", "attackId": "sniper_line"}, "renderState": "default"}]
    if asset_id == "GFX-WARN-CONE":
        return [{"event": "BossAttackTelegraphed", "when": {"attackId": "boss_fan"}, "renderState": "default"}]
    if asset_id == "GFX-WARN-CIRCLE":
        return [{"event": "BossAttackTelegraphed", "when": {"attackId": "boss_ring"}, "renderState": "default"}]
    if asset_id == "GFX-BOSS-FAN-BULLET":
        return [{"event": "BossAttackFired", "when": {"attackId": "boss_fan"}, "renderState": "default"}]
    if asset_id == "GFX-BOSS-RING-BULLET":
        return [{"event": "BossAttackFired", "when": {"attackId": "boss_ring"}, "renderState": "default"}]
    if asset_id == "GFX-BOSS-LASER":
        return [{"event": "BossAttackFired", "when": {"attackId": "boss_laser"}, "renderState": "default"}]
    if asset_id.startswith("UI-HUD-HP"):
        return [{"event": "PlayerVitalStateChanged", "when": {"hpRatioGt": 0.30}, "renderState": "normal"}, {"event": "PlayerVitalStateChanged", "when": {"hpRatioGt": 0.10, "hpRatioLte": 0.30}, "renderState": "low"}, {"event": "PlayerVitalStateChanged", "when": {"hpRatioLte": 0.10}, "renderState": "critical"}, {"event": "PlayerDamaged", "when": {"hpDamageGt": 0}, "renderState": "hit", "transientMs": 120, "restoreFromSnapshot": True}]
    if asset_id.startswith("UI-HUD-SHIELD"):
        return [{"event": "PlayerVitalStateChanged", "when": {"shieldRatioGt": 0.25}, "renderState": "normal"}, {"event": "PlayerVitalStateChanged", "when": {"shieldRatioGt": 0.10, "shieldRatioLte": 0.25}, "renderState": "low"}, {"event": "PlayerVitalStateChanged", "when": {"shieldRatioLte": 0.10}, "renderState": "critical"}, {"event": "PlayerDamaged", "when": {"shieldDamageGt": 0}, "renderState": "hit", "transientMs": 120, "restoreFromSnapshot": True}]
    if asset_id.startswith("UI-HUD-WARNING"):
        return [{"event": "PlayerDamaged", "when": {"hpRatioLte": 0.30}, "renderState": "critical"}]
    if asset_id.startswith("UI-HUD-DASH"):
        return [{"event": "DashStateChanged", "when": {"availability": "ready"}, "renderState": "ready"}, {"event": "DashStateChanged", "when": {"availability": "cooldown"}, "renderState": "cooldown"}, {"event": "DashStateChanged", "when": {"availability": "disabled"}, "renderState": "disabled"}, {"event": "UiControlStateChanged", "when": {"controlId": "hud_dash", "state": "pressed"}, "renderState": "pressed"}, {"event": "UiControlStateChanged", "when": {"controlId": "hud_dash", "state": "focus"}, "renderState": "focus"}]
    if asset_id == "UI-HUD-DAMAGE-DIRECTION":
        return [{"event": "PlayerDamaged", "when": {"direction": direction}, "renderState": state, "transientMs": 300} for direction, state in (("north", "north"), ("northEast", "northEast"), ("east", "east"), ("southEast", "southEast"), ("south", "south"), ("southWest", "southWest"), ("west", "west"), ("northWest", "northWest"))]
    if asset_id.startswith("UI-DRAFT") or asset_id.startswith("UI-UP-"):
        return [{"event": "UpgradeDraftOpened", "when": {}, "renderState": "normal"}]
    if asset_id.startswith("UI-RISK"):
        return [{"event": "RiskGateOpened", "when": {"optionId": "RG-SUPPLY"}, "renderState": "safe"}, {"event": "RiskOptionStateChanged", "when": {"optionId": "RG-BOUNTY", "state": "risk"}, "renderState": "risk"}, {"event": "RiskOptionStateChanged", "when": {"optionId": "RG-OVERLOAD", "state": "locked"}, "renderState": "locked"}, {"event": "RiskSelected", "when": {}, "renderState": "selected"}]
    if asset_id.startswith("UI-RESULT"):
        if asset_id == "UI-RESULT-PANEL":
            return [{"event": "RunEnded", "when": {"result": "victory"}, "renderState": "victory"}, {"event": "RunEnded", "when": {"result": "defeat"}, "renderState": "defeat"}]
        return [{"event": "RunEnded", "when": {"resultTier": tier}, "renderState": tier} for tier in ("bronze", "silver", "gold", "none")]
    return []


def load_group(asset_id: str) -> str:
    if asset_id.startswith("GFX-BOSS") or asset_id.startswith("UI-BOSS"):
        return "boss"
    if asset_id.startswith("UI-HUD") or asset_id in {"GFX-PLAYER-BASE", "GFX-BG-DEEP-SPACE", "GFX-BG-STARS", "GFX-BG-GRID"}:
        return "firstRun"
    return "lazy"


def ui_layout(asset_id: str) -> dict[str, object] | None:
    if asset_id in graphics.BAR_ASSETS:
        return {"nineSliceInsetsPx": [24, 24, 24, 24], "fillRectNormalized": [0.03, 0.20, 0.94, 0.60], "minimumSizePx": [160, 32]}
    if asset_id in {"UI-BUTTON-PRIMARY", "UI-BUTTON-SECONDARY", "UI-DRAFT-CARD", "UI-DRAFT-PANEL", "UI-RISK-PANEL", "UI-RESULT-PANEL", "UI-PAUSE-PANEL", "UI-SETTINGS-PANEL", "UI-BRIEFING-PANEL", "UI-TOOLTIP"}:
        return {"nineSliceInsetsPx": [32, 32, 32, 32], "minimumSizePx": [128, 64]}
    return None

def graphic_entry(asset_id: str) -> dict[str, object]:
    state_names = states.states_for(asset_id)
    fallback_paths_by_name = {
        state: [states.frame_path(asset_id, state, index, states.frame_count_for(asset_id, state)) for index in range(states.frame_count_for(asset_id, state))]
        for state in state_names
    }
    state_paths_by_name = {
        state: ([web_backgrounds.webp_path(asset_id, state, index, len(paths)) for index in range(len(paths))] if asset_id in graphics.BACKGROUND else paths)
        for state, paths in fallback_paths_by_name.items()
    }
    state_paths = [path for paths in state_paths_by_name.values() for path in paths]
    fallback_paths = [path for paths in fallback_paths_by_name.values() for path in paths] if asset_id in graphics.BACKGROUND else []
    for path in [*state_paths, *fallback_paths]:
        if not path.exists():
            raise FileNotFoundError(path)
    bindings = bindings_for(asset_id)
    triggers = sorted({binding["event"] for binding in bindings})
    anchor = [0.5, 0.5]
    record: dict[str, object] = {
        "assetId": asset_id,
        "category": "ui" if asset_id.startswith("UI-") else "graphic",
        "sourceFile": f"图形/源SVG/{graphics.group(asset_id)}/{asset_id}.svg" if asset_id not in {"GFX-PLAYER-BASE", "GFX-BOSS-AEGIS-BODY"} else f"图形/源设计/{asset_id}.svg",
        "runtimeFiles": [str(path.relative_to(PACK)) for path in [*state_paths, *fallback_paths]],
        "sha256": sha(state_paths[0]),
        "runtimeSha256": [sha(path) for path in [*state_paths, *fallback_paths]],
        "license": "Original workspace asset; no third-party source used.",
        "authorOrVendor": "Warship asset pipeline",
        "createdAt": RELEASE_DATE,
        "contentVersion": RELEASE_VERSION,
        "states": state_names,
        "triggerEvents": triggers,
        "fallbackAssetId": asset_id if asset_id in {"GFX-FALLBACK-SILHOUETTE", "UI-FALLBACK-ICON"} else ("UI-FALLBACK-ICON" if asset_id.startswith("UI-") else "GFX-FALLBACK-SILHOUETTE"),
        "memoryEstimateBytes": sum(path.stat().st_size for path in [*state_paths, *fallback_paths]),
        "anchor": anchor,
        "loadGroup": load_group(asset_id),
        "eventBindings": bindings,
        "renderStates": {
            state: {
                "runtimeFiles": [str(path.relative_to(PACK)) for path in paths],
                **({"fallbackRuntimeFiles": [str(path.relative_to(PACK)) for path in fallback_paths_by_name[state]]} if asset_id in graphics.BACKGROUND else {}),
                "frameInterval": [0, len(paths) - 1],
                "frameCount": len(paths),
                "fps": 14 if len(paths) > 1 else 0,
                "blendMode": "normal",
                "anchor": anchor,
            }
            for state, paths in state_paths_by_name.items()
        },
        "format": "webp" if asset_id in graphics.BACKGROUND else "png",
        "status": "release_ready",
    }
    if asset_id in {"GFX-PLAYER-BASE", "GFX-BOSS-AEGIS-BODY"}:
        record["sourceMasterFiles"] = [f"图形/角色与敌机/{asset_id}.png"]
    layout = ui_layout(asset_id)
    if layout:
        record["layout"] = layout
    return record

def main() -> None:
    entries = [graphic_entry(asset_id) for asset_id in ALL_GRAPHICS]
    entries.extend(json.loads((HERE / "audio_manifest.json").read_text(encoding="utf-8"))["assets"])
    entries.append({
        "assetId": "SFX-FALLBACK-SILENT", "category": "sfx", "cueId": "cue.sfx.fallback.silent", "sourceFile": None, "runtimeFiles": [], "sha256": None,
        "license": "Logical no-op fallback; no audio file is shipped.", "authorOrVendor": "Warship asset pipeline", "createdAt": RELEASE_DATE, "contentVersion": RELEASE_VERSION,
        "states": ["ready"], "triggerEvents": ["AssetLoadFailed"], "eventBindings": [{"event": "AssetLoadFailed", "when": {}}], "fallbackAssetId": "SFX-FALLBACK-SILENT", "memoryEstimateBytes": 0,
        "bus": "SFX", "priority": 0, "maxVoices": 0, "minRetriggerMs": 0, "loop": False, "loopStartSample": None, "loopEndSample": None, "loadGroup": "lazy",
        "loudnessTargetLufs": None, "truePeakCeilingDbtp": None, "status": "release_ready",
    })
    entries += [
        {"assetId": "FONT-UI-REGULAR", "category": "font", "systemFallbacks": ["PingFang SC", "Noto Sans CJK SC", "sans-serif"], "license": "Use only installed system font licenses.", "createdAt": RELEASE_DATE, "contentVersion": RELEASE_VERSION, "status": "release_ready"},
        {"assetId": "FONT-UI-BOLD", "category": "font", "systemFallbacks": ["PingFang SC Semibold", "Noto Sans CJK SC Bold", "sans-serif"], "license": "Use only installed system font licenses.", "createdAt": RELEASE_DATE, "contentVersion": RELEASE_VERSION, "status": "release_ready"},
    ]
    payload = {"schemaVersion": "1.1.0", "contentVersion": RELEASE_VERSION, "assets": entries}
    (PACK / "manifest.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()
