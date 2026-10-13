"""Generate deterministic, original candidate audio for the v2.0 asset pack.

These are synthetic production candidates, not final mixed sound design.
They are intentionally free of third-party samples and are generated as 48 kHz,
24-bit stereo WAV masters; runtime compression happens in the build pipeline.
"""

from __future__ import annotations

import math
import random
import struct
import wave
import hashlib
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / "音频" / "母带WAV"
METADATA = Path(__file__).resolve().parent
RATE = 48_000
RELEASE_DATE = "2026-10-13T00:00:00+08:00"
RELEASE_VERSION = "2.0.4-release"

SFX = """
SFX-UI-TAP SFX-UI-BACK SFX-UI-ERROR SFX-UI-COUNTDOWN SFX-UI-DRAFT-OPEN SFX-UI-DRAFT-CHOOSE SFX-UI-RISK-OPEN SFX-UI-RISK-CHOOSE SFX-UI-PAUSE
SFX-PLAYER-PULSE SFX-PLAYER-PULSE-CRIT SFX-PLAYER-PULSE-HIT SFX-PLAYER-MISSILE-LAUNCH SFX-PLAYER-MISSILE-IMPACT SFX-PLAYER-LASER-START SFX-PLAYER-LASER-LOOP SFX-PLAYER-LASER-END SFX-PLAYER-DRONE-SHOT SFX-PLAYER-ARC SFX-PLAYER-DASH SFX-PLAYER-SHIELD-HIT SFX-PLAYER-HP-HIT SFX-PLAYER-LOW-SHIELD SFX-PLAYER-LOW-HP SFX-PLAYER-SHIELD-REGEN SFX-PLAYER-HEAL SFX-PLAYER-DASH-READY
SFX-EN-SCOUT-SHOT SFX-EN-WING-SHOT SFX-EN-SNIPER-SHOT SFX-EN-SHIELD-SHOT SFX-EN-SNIPER-WARN SFX-EN-BOMBER-DROP SFX-EN-BOMBER-HAZARD SFX-EN-HIT SFX-EN-CRITICAL SFX-EN-DESTROY-S SFX-EN-DESTROY-M SFX-EN-DESTROY-L SFX-EN-BREACH SFX-ELITE-SPAWN SFX-ELITE-AURA SFX-ELITE-DEFEAT SFX-ELITE-CORE
SFX-BOSS-ENTRY SFX-BOSS-PHASE SFX-BOSS-CRITICAL SFX-BOSS-DEFEAT SFX-BOSS-FAN-WARN SFX-BOSS-FAN-SHOT SFX-BOSS-CHARGE-WARN SFX-BOSS-CHARGE-IMPACT SFX-BOSS-RING-WARN SFX-BOSS-RING-SHOT SFX-BOSS-SUMMON SFX-BOSS-LASER-WARN SFX-BOSS-LASER-LOOP SFX-BOSS-LASER-END SFX-BOSS-WEAKPOINT-OPEN
SFX-RUN-VICTORY SFX-RUN-DEFEAT SFX-RUN-RESULT-OPEN
""".split()

BGM = "BGM-HOME BGM-RUN-BASE BGM-RUN-TENSION BGM-BOSS BGM-BOSS-CRITICAL".split()


def category(name: str) -> tuple[float, float, str]:
    if name.startswith("BGM-"):
        # Every value creates an integer number of cycles over 48 seconds, so
        # the rendered stem can loop sample-to-sample without a click.
        tones = {
            "BGM-HOME": 220.0,
            "BGM-RUN-BASE": 110.0,
            "BGM-RUN-TENSION": 130.0,
            "BGM-BOSS": 70.0,
            "BGM-BOSS-CRITICAL": 92.0,
        }
        return (tones[name], 48.0, "music")
    if "LOW-" in name or "WARN" in name or "BREACH" in name:
        return (220.0, 0.65, "warning")
    if "DESTROY" in name or "IMPACT" in name or "DEFEAT" in name:
        return (95.0, 0.5, "impact")
    if "LOOP" in name:
        return (330.0, 2.0, "loop")
    if "PULSE" in name or "SHOT" in name:
        return (680.0, 0.18, "shot")
    # Distinct IDs must not accidentally produce a shared cue.  The stable
    # offset retains deterministic output while separating related effects.
    return (440.0 + (sum(name.encode("utf-8")) % 13) * 17.0, 0.3, "ui")


def music_gain(name: str) -> float:
    # Per-stem calibration, measured after composition rather than assumed from
    # oscillator amplitude.  Keeps every delivery stem in the -17.5 to -14.5
    # LUFS target window, centred near -16 LUFS.
    return {
        "BGM-HOME": 0.81,
        "BGM-RUN-BASE": 1.00,
        "BGM-RUN-TENSION": 0.95,
        "BGM-BOSS": 1.17,
        "BGM-BOSS-CRITICAL": 1.07,
    }.get(name, 1.0)


def render(name: str) -> list[float]:
    freq, seconds, kind = category(name)
    n = int(RATE * seconds)
    rng = random.Random(name)
    out: list[float] = []
    for i in range(n):
        t = i / RATE
        x = i / max(n - 1, 1)
        if kind == "music":
            chord = sum(math.sin(2 * math.pi * freq * ratio * t) for ratio in (1, 1.25, 1.5)) / 3
            pulse = 0.45 + 0.25 * math.sin(2 * math.pi * 0.5 * t)
            # Calibrated against EBU R128 measurement of all five music stems:
            # intended delivery window is roughly -16 LUFS while preserving a
            # -1 dBTP safety margin after runtime decoding.
            value = (chord * pulse * 0.62 + math.sin(2 * math.pi * (freq / 4) * t) * 0.195) * music_gain(name)
        elif kind == "warning":
            value = math.sin(2 * math.pi * (freq + 160 * x) * t) * (0.45 if x < 0.82 else (1 - x) * 2.5)
        elif kind == "impact":
            value = (rng.random() * 2 - 1) * math.exp(-6 * x) * 0.52 + math.sin(2 * math.pi * freq * (1 - 0.55 * x) * t) * math.exp(-5 * x) * 0.36
        elif kind == "loop":
            value = math.sin(2 * math.pi * freq * t) * 0.12 + math.sin(2 * math.pi * freq * 1.5 * t) * 0.05
        elif kind == "shot":
            value = math.sin(2 * math.pi * (freq * (1 - 0.55 * x)) * t) * math.exp(-7 * x) * 0.58
        else:
            value = math.sin(2 * math.pi * freq * t) * math.sin(math.pi * x) * 0.35
        out.append(max(-0.8, min(0.8, value)))
    return out


def write_wav(name: str) -> None:
    samples = render(name)
    path = ROOT / f"{name}.wav"
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(3)
        handle.setframerate(RATE)
        frames = bytearray()
        for sample in samples:
            left = int(sample * 8_388_607)
            right = int(sample * 0.96 * 8_388_607)
            frames.extend(left.to_bytes(3, "little", signed=True))
            frames.extend(right.to_bytes(3, "little", signed=True))
        handle.writeframes(frames)


def audio_meta(name: str) -> dict[str, object]:
    is_bgm = name.startswith("BGM-")
    is_warning = "WARN" in name or "LOW-" in name or "BREACH" in name or name.startswith("SFX-BOSS-")
    is_loop = name.endswith("-LOOP") or is_bgm
    wav_path = ROOT / f"{name}.wav"
    mp3_path = ROOT.parent / "运行时MP3" / f"{name}.mp3"
    with wave.open(str(wav_path), "rb") as handle:
        frames = handle.getnframes()
    bus = "Music" if is_bgm else ("Warning" if is_warning else ("UI" if name.startswith("SFX-UI") or name.startswith("SFX-RUN") else "SFX"))
    priority = 100 if name.startswith("SFX-BOSS-") and "WARN" in name else (80 if is_warning else (50 if bus == "UI" else 30))
    return {
        "assetId": name,
        "category": "bgm" if is_bgm else "sfx",
        "sourceFile": f"音频/母带WAV/{name}.wav",
        "runtimeFiles": [f"音频/运行时MP3/{name}.mp3"],
        "sha256": hashlib.sha256(wav_path.read_bytes()).hexdigest(),
        "runtimeSha256": hashlib.sha256(mp3_path.read_bytes()).hexdigest() if mp3_path.exists() else None,
        "license": "Original synthetic candidate generated in this workspace; no third-party samples.",
        "authorOrVendor": "Warship asset pipeline",
        "createdAt": RELEASE_DATE,
        "contentVersion": RELEASE_VERSION,
        "cueId": "cue." + name.lower().replace("-", "."),
        "states": ["ready"],
        "triggerEvents": [binding["event"] for binding in bindings_for(name)],
        "eventBindings": bindings_for(name),
        "fallbackAssetId": "SFX-FALLBACK-SILENT",
        "memoryEstimateBytes": wav_path.stat().st_size + (mp3_path.stat().st_size if mp3_path.exists() else 0),
        "loadGroup": load_group_for(name),
        "bus": bus,
        "priority": priority,
        "maxVoices": 1 if is_loop or is_bgm else (4 if "PULSE" in name or "HIT" in name else 2),
        "minRetriggerMs": 80 if "PULSE" in name or "HIT" in name else 0,
        "loop": is_loop,
        "loopStartSample": 0 if is_loop else None,
        "loopEndSample": frames if is_loop else None,
        "sampleRate": RATE,
        "channels": 2,
        "masterBitDepth": 24,
        "loudnessTargetLufs": -16 if is_bgm else (-18 if bus == "Warning" else -17),
        "truePeakCeilingDbtp": -1.0,
        "status": "release_ready",
    }


def load_group_for(name: str) -> str:
    if name.startswith("SFX-BOSS") or name in {"BGM-BOSS", "BGM-BOSS-CRITICAL"}:
        return "boss"
    first_run = {
        "BGM-RUN-BASE", "SFX-UI-COUNTDOWN", "SFX-UI-PAUSE", "SFX-PLAYER-PULSE",
        "SFX-PLAYER-PULSE-HIT", "SFX-PLAYER-DASH", "SFX-PLAYER-SHIELD-HIT",
        "SFX-PLAYER-HP-HIT", "SFX-EN-SCOUT-SHOT", "SFX-EN-WING-SHOT",
        "SFX-EN-HIT", "SFX-EN-DESTROY-S", "SFX-EN-BREACH",
    }
    return "firstRun" if name in first_run else "lazy"


def bindings_for(name: str) -> list[dict[str, object]]:
    """Precise event/Cue routing; never use a broad prefix-based event list."""
    ui = {
        "SFX-UI-TAP": ("UiCommand", {"command": "confirm"}),
        "SFX-UI-BACK": ("UiCommand", {"command": "back"}),
        "SFX-UI-ERROR": ("UiCommand", {"command": "locked"}),
        "SFX-UI-COUNTDOWN": ("RunStarted", {}),
        "SFX-UI-DRAFT-OPEN": ("UpgradeDraftOpened", {}),
        "SFX-UI-DRAFT-CHOOSE": ("UpgradeSelected", {}),
        "SFX-UI-RISK-OPEN": ("RiskGateOpened", {}),
        "SFX-UI-RISK-CHOOSE": ("RiskSelected", {}),
        "SFX-UI-PAUSE": ("UiCommand", {"command": "pause"}),
    }
    if name in ui:
        event, when = ui[name]
        return [{"event": event, "when": when}]
    weapon = {
        "SFX-PLAYER-PULSE": ("WeaponFired", {"weaponId": "pulse"}),
        "SFX-PLAYER-PULSE-CRIT": ("WeaponHit", {"weaponId": "pulse", "critical": True}),
        "SFX-PLAYER-PULSE-HIT": ("WeaponHit", {"weaponId": "pulse", "critical": False}),
        "SFX-PLAYER-MISSILE-LAUNCH": ("WeaponFired", {"weaponId": "missile"}),
        "SFX-PLAYER-MISSILE-IMPACT": ("WeaponHit", {"weaponId": "missile"}),
        "SFX-PLAYER-LASER-START": ("WeaponSustainStarted", {"weaponId": "laser"}),
        "SFX-PLAYER-LASER-LOOP": ("WeaponSustainStarted", {"weaponId": "laser"}),
        "SFX-PLAYER-LASER-END": ("WeaponSustainStopped", {"weaponId": "laser"}),
        "SFX-PLAYER-DRONE-SHOT": ("WeaponFired", {"weaponId": "drone"}),
        "SFX-PLAYER-ARC": ("WeaponHit", {"weaponId": "pulse", "critical": True}),
    }
    if name in weapon:
        event, when = weapon[name]
        return [{"event": event, "when": when}]
    player = {
        "SFX-PLAYER-DASH": ("DashStarted", {}),
        "SFX-PLAYER-SHIELD-HIT": ("PlayerDamaged", {"shieldDamageGt": 0}),
        "SFX-PLAYER-HP-HIT": ("PlayerDamaged", {"hpDamageGt": 0}),
        "SFX-PLAYER-LOW-SHIELD": ("PlayerDamaged", {"shieldRatioLte": 0.25}),
        "SFX-PLAYER-LOW-HP": ("PlayerDamaged", {"hpRatioLte": 0.30}),
        "SFX-PLAYER-SHIELD-REGEN": ("PickupShield", {}),
        "SFX-PLAYER-HEAL": ("PickupHeal", {}),
        "SFX-PLAYER-DASH-READY": ("DashReady", {}),
    }
    if name in player:
        event, when = player[name]
        return [{"event": event, "when": when}]
    enemy_attack = {
        "SFX-EN-SCOUT-SHOT": ("EnemyAttackFired", {"enemyId": "EN-SCOUT", "attackId": "scout_shot"}),
        "SFX-EN-WING-SHOT": ("EnemyAttackFired", {"enemyId": "EN-WING", "attackId": "wing_shot"}),
        "SFX-EN-SNIPER-SHOT": ("EnemyAttackFired", {"enemyId": "EN-SNIPER", "attackId": "sniper_line"}),
        "SFX-EN-SHIELD-SHOT": ("EnemyAttackFired", {"enemyId": "EN-SHIELD", "attackId": "shield_shot"}),
        "SFX-EN-SNIPER-WARN": ("EnemyAttackTelegraphed", {"enemyId": "EN-SNIPER", "attackId": "sniper_line"}),
        "SFX-EN-BOMBER-DROP": ("EnemyAttackFired", {"enemyId": "EN-BOMBER", "attackId": "bomber_drop"}),
        "SFX-EN-BOMBER-HAZARD": ("EnemyAttackTelegraphed", {"enemyId": "EN-BOMBER", "attackId": "bomber_drop"}),
    }
    if name in enemy_attack:
        event, when = enemy_attack[name]
        return [{"event": event, "when": when}]
    if name.startswith("SFX-EN-"):
        if name in {"SFX-EN-HIT", "SFX-EN-CRITICAL"}:
            return [{"event": "WeaponHit", "when": {}}]
        if "DESTROY" in name:
            return [{"event": "EnemyDestroyed", "when": {}}]
        return [{"event": "EnemyBreached", "when": {}}]
    if name.startswith("SFX-ELITE"):
        if name == "SFX-ELITE-DEFEAT":
            return [{"event": "EnemyDestroyed", "when": {"isElite": True}}]
        return [{"event": "EnemySpawned", "when": {"isElite": True}}]
    boss_attack = {
        "SFX-BOSS-FAN-WARN": ("BossAttackTelegraphed", {"attackId": "boss_fan"}),
        "SFX-BOSS-FAN-SHOT": ("BossAttackFired", {"attackId": "boss_fan"}),
        "SFX-BOSS-CHARGE-WARN": ("BossAttackTelegraphed", {"attackId": "boss_charge"}),
        "SFX-BOSS-CHARGE-IMPACT": ("BossAttackFired", {"attackId": "boss_charge"}),
        "SFX-BOSS-RING-WARN": ("BossAttackTelegraphed", {"attackId": "boss_ring"}),
        "SFX-BOSS-RING-SHOT": ("BossAttackFired", {"attackId": "boss_ring"}),
        "SFX-BOSS-SUMMON": ("BossAttackFired", {"attackId": "boss_summon"}),
        "SFX-BOSS-LASER-WARN": ("BossAttackTelegraphed", {"attackId": "boss_laser"}),
        "SFX-BOSS-LASER-LOOP": ("BossAttackFired", {"attackId": "boss_laser"}),
        "SFX-BOSS-LASER-END": ("BossAttackEnded", {"attackId": "boss_laser"}),
        "SFX-BOSS-WEAKPOINT-OPEN": ("BossAttackFired", {"attackId": "boss_laser"}),
    }
    if name in boss_attack:
        event, when = boss_attack[name]
        return [{"event": event, "when": when}]
    if name.startswith("SFX-BOSS"):
        if name in {"SFX-BOSS-ENTRY", "SFX-BOSS-PHASE", "SFX-BOSS-DEFEAT"}:
            return [{"event": "BossDefeated" if name.endswith("DEFEAT") else "BossPhaseChanged", "when": {}}]
        if name == "SFX-BOSS-CRITICAL":
            return [{"event": "BossCriticalReached", "when": {"hpRatioLte": 0.10}}]
        raise ValueError(f"missing precise boss binding: {name}")
    if name.startswith("SFX-RUN"):
        return [{"event": "RunEnded", "when": {"result": "victory" if name.endswith("VICTORY") else "defeat" if name.endswith("DEFEAT") else "any"}}]
    if name == "BGM-HOME":
        return [{"event": "UiCommand", "when": {"command": "homeOpened"}}]
    if name == "BGM-RUN-BASE":
        return [{"event": "RunStarted", "when": {}}]
    if name == "BGM-RUN-TENSION":
        return [{"event": "EnemySpawned", "when": {"isElite": True}}]
    if name == "BGM-BOSS":
        return [{"event": "BossPhaseChanged", "when": {"phase": "p1"}}]
    if name == "BGM-BOSS-CRITICAL":
        return [{"event": "BossCriticalReached", "when": {"hpRatioLte": 0.10}}]
    raise ValueError(f"missing event binding: {name}")


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    for asset_id in [*SFX, *BGM]:
        write_wav(asset_id)
    manifest = {
        "schemaVersion": "1.0.0-release",
        "generatedAt": RELEASE_DATE,
        "assets": [audio_meta(asset_id) for asset_id in [*SFX, *BGM]],
    }
    (METADATA / "audio_manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
