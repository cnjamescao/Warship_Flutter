"""Release gate for the standalone Warship v2.0 asset package."""
from __future__ import annotations

import hashlib
import json
import sys
import wave
from pathlib import Path

from generate_runtime_state_variants import frame_count_for, states_for

PACK = Path(__file__).resolve().parents[1]
GRAPHIC_REQUIRED = {
    "assetId", "category", "sourceFile", "runtimeFiles", "sha256", "license",
    "authorOrVendor", "createdAt", "contentVersion", "states", "triggerEvents",
    "fallbackAssetId", "memoryEstimateBytes", "anchor", "loadGroup", "renderStates", "eventBindings",
}
AUDIO_REQUIRED = {
    "assetId", "category", "sourceFile", "runtimeFiles", "sha256", "license",
    "authorOrVendor", "createdAt", "contentVersion", "cueId", "states",
    "triggerEvents", "fallbackAssetId", "memoryEstimateBytes", "bus", "priority",
    "maxVoices", "minRetriggerMs", "loop", "loopStartSample", "loopEndSample", "loadGroup",
    "loudnessTargetLufs", "truePeakCeilingDbtp", "eventBindings",
}

# These resources advertise several gameplay-facing states.  A release is only
# usable by a client team when every advertised state has one explicit route.
ROUTING_COMPLETE_ASSETS = {
    "GFX-PLAYER-ENGINE-CRITICAL", "GFX-PLAYER-DASH-TRAIL",
    "GFX-EN-SCOUT", "GFX-EN-WING", "GFX-EN-SNIPER", "GFX-EN-BOMBER", "GFX-EN-SHIELD",
    "UI-HUD-HP-FRAME", "UI-HUD-HP-FILL", "UI-HUD-SHIELD-FRAME", "UI-HUD-SHIELD-FILL",
    "UI-HUD-DASH-BUTTON", "UI-HUD-DASH-RING", "UI-HUD-DAMAGE-DIRECTION",
    "UI-RISK-PANEL", "UI-RISK-SAFE", "UI-RISK-BOUNTY", "UI-RISK-OVERLOAD",
    "UI-RESULT-PANEL", "UI-RESULT-MEDAL",
}

def validate_binding_precision(asset_id: str, bindings: list[dict[str, object]], states: list[str], errors: list[str]) -> None:
    mapped = {binding.get("renderState") for binding in bindings}
    if asset_id in ROUTING_COMPLETE_ASSETS and mapped != set(states):
        errors.append(f"incomplete semantic state routing: {asset_id}: mapped={sorted(mapped)} expected={sorted(states)}")
    for binding in bindings:
        event = binding.get("event")
        when = binding.get("when", {})
        if event in {"EnemyAttackTelegraphed", "EnemyAttackFired"} and not {"enemyId", "attackId"}.issubset(when):
            errors.append(f"imprecise enemy attack binding: {asset_id}: {event}")
        if event in {"BossAttackTelegraphed", "BossAttackFired", "BossAttackEnded"} and "attackId" not in when:
            errors.append(f"imprecise boss attack binding: {asset_id}: {event}")

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main() -> int:
    data = json.loads((PACK / "manifest.json").read_text(encoding="utf-8"))
    errors: list[str] = []
    ids: set[str] = set()
    graphic_count = physical_audio_count = 0
    for asset in data["assets"]:
        asset_id = asset["assetId"]
        if asset_id in ids:
            errors.append(f"duplicate Asset ID: {asset_id}")
        ids.add(asset_id)
        category = asset.get("category")
        if category in {"graphic", "ui"}:
            graphic_count += 1
            missing = GRAPHIC_REQUIRED - asset.keys()
            if missing:
                errors.append(f"incomplete graphic metadata: {asset_id}: {sorted(missing)}")
            if asset.get("loadGroup") not in {"firstRun", "boss", "lazy"}:
                errors.append(f"invalid loadGroup: {asset_id}")
            state_names = asset.get("states", [])
            state_map = asset.get("renderStates", {})
            if set(state_names) != set(state_map):
                errors.append(f"state mapping mismatch: {asset_id}")
            if state_names != states_for(asset_id):
                errors.append(f"semantic state coverage mismatch: {asset_id}")
            if set(asset.get("triggerEvents", [])) != {binding.get("event") for binding in asset.get("eventBindings", [])}:
                errors.append(f"graphic trigger/binding mismatch: {asset_id}")
            for binding in asset.get("eventBindings", []):
                if binding.get("renderState") not in state_names:
                    errors.append(f"unknown graphic binding state: {asset_id}/{binding.get('renderState')}")
            validate_binding_precision(asset_id, asset.get("eventBindings", []), state_names, errors)
            for state, state_data in state_map.items():
                mapped = state_data.get("runtimeFiles", [])
                if not mapped or not set(mapped).issubset(set(asset.get("runtimeFiles", []))):
                    errors.append(f"invalid render state file mapping: {asset_id}/{state}")
                fallback_mapped = state_data.get("fallbackRuntimeFiles", [])
                if fallback_mapped and not set(fallback_mapped).issubset(set(asset.get("runtimeFiles", []))):
                    errors.append(f"invalid fallback state file mapping: {asset_id}/{state}")
                if asset_id.startswith("GFX-BG-") and (not fallback_mapped or not all(path.endswith(".webp") for path in mapped) or not all(path.endswith(".png") for path in fallback_mapped)):
                    errors.append(f"invalid WebP/PNG background contract: {asset_id}/{state}")
                frame_count = frame_count_for(asset_id, state)
                if state_data.get("frameCount") != frame_count or state_data.get("frameInterval") != [0, frame_count - 1] or len(mapped) != frame_count:
                    errors.append(f"invalid frame contract: {asset_id}/{state}")
        if category in {"sfx", "bgm"}:
            if asset_id != "SFX-FALLBACK-SILENT":
                physical_audio_count += 1
            missing = AUDIO_REQUIRED - asset.keys()
            if missing:
                errors.append(f"incomplete audio metadata: {asset_id}: {sorted(missing)}")
            if asset_id != "SFX-FALLBACK-SILENT" and not asset.get("cueId"):
                errors.append(f"missing cueId: {asset_id}")
            if asset.get("bus") not in {"UI", "SFX", "Warning", "Music"}:
                errors.append(f"invalid audio bus: {asset_id}")
            if asset.get("loadGroup") not in {"firstRun", "boss", "lazy"}:
                errors.append(f"invalid audio loadGroup: {asset_id}")
            if asset_id != "SFX-FALLBACK-SILENT" and not asset.get("triggerEvents"):
                errors.append(f"missing audio trigger event: {asset_id}")
            if set(asset.get("triggerEvents", [])) != {binding.get("event") for binding in asset.get("eventBindings", [])}:
                errors.append(f"audio trigger/binding mismatch: {asset_id}")
            validate_binding_precision(asset_id, asset.get("eventBindings", []), asset.get("states", []), errors)
        if category != "font" and not asset.get("createdAt"):
            errors.append(f"missing createdAt: {asset_id}")
        if category != "font" and asset.get("status") != "release_ready":
            errors.append(f"asset not release_ready: {asset_id}")
        source = asset.get("sourceFile")
        if source is not None and not (PACK / source).is_file():
            errors.append(f"missing source file: {asset_id}: {source}")
        for master in asset.get("sourceMasterFiles", []):
            if not (PACK / master).is_file():
                errors.append(f"missing source master file: {asset_id}: {master}")
        if asset_id in {"GFX-PLAYER-BASE", "GFX-BOSS-AEGIS-BODY"}:
            if not str(source).endswith(".svg") or not asset.get("sourceMasterFiles"):
                errors.append(f"missing editable composite source contract: {asset_id}")
        for index, relative in enumerate(asset.get("runtimeFiles", [])):
            path = PACK / relative
            if not path.is_file():
                errors.append(f"missing runtime file: {asset_id}: {relative}")
                continue
            expected = asset.get("runtimeSha256")
            expected_hash = expected[index] if isinstance(expected, list) else expected
            if expected_hash and digest(path) != expected_hash:
                errors.append(f"runtime hash mismatch: {asset_id}: {relative}")
        if category in {"sfx", "bgm"} and asset_id != "SFX-FALLBACK-SILENT":
            master = PACK / asset["sourceFile"]
            if not master.is_file():
                errors.append(f"missing WAV master: {asset_id}")
            else:
                with wave.open(str(master), "rb") as handle:
                    if (handle.getframerate(), handle.getsampwidth() * 8, handle.getnchannels()) != (48000, 24, 2):
                        errors.append(f"invalid WAV master format: {asset_id}")
    if graphic_count != 127 or physical_audio_count != 67:
        errors.append(f"unexpected asset counts: graphics={graphic_count}, physical_audio={physical_audio_count}")
    fallback_ids = {"GFX-FALLBACK-SILHOUETTE", "UI-FALLBACK-ICON", "SFX-FALLBACK-SILENT"}
    if not fallback_ids.issubset(ids):
        errors.append(f"missing mandatory fallback records: {sorted(fallback_ids - ids)}")
    if errors:
        print("FAIL")
        print("\n".join(errors))
        return 1
    print(f"PASS: {len(ids)} records, {graphic_count} graphics/UI, {physical_audio_count} physical audio + logical silent fallback; metadata, state mappings, sources, files and hashes valid.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
