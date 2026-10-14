"""Generate named, visibly distinct PNG state variants for the release pack.

The state file is always referenced explicitly by manifest.json.  Runtime code
never needs to infer a colour treatment from an Asset ID or use a shader as an
undocumented substitute for a missing state asset.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from generate_runtime_graphics import (
    BACKGROUND, BOSS, ELITE, HAZARDS, PLAYER, SHIPS, UI, UPGRADES, WEAPONS,
    dimensions, group,
)

PACK = Path(__file__).resolve().parents[1]
ROOT = PACK / "图形" / "运行时PNG"


# The spec's semantic states are the runtime contract.  Generic UI interaction
# states are only used where a control is genuinely interactive.
STATE_SPECS: dict[str, dict[str, int]] = {
    "GFX-PLAYER-DASH-TRAIL": {"active": 3, "end": 1},
    "GFX-EN-SNIPER": {"idle": 1, "charge": 1, "hit": 1, "critical": 1, "destroy": 1},
    "GFX-EN-BOMBER": {"idle": 1, "drop": 1, "hit": 1, "critical": 1, "destroy": 1},
    "GFX-EN-SHIELD": {"body": 1, "frontShield": 1, "hit": 1, "critical": 1, "destroy": 1},
    "UI-HUD-HP-FRAME": {"normal": 1, "hit": 1, "low": 1, "critical": 1},
    "UI-HUD-HP-FILL": {"normal": 1, "hit": 1, "low": 1, "critical": 1},
    "UI-HUD-SHIELD-FRAME": {"normal": 1, "hit": 1, "low": 1, "critical": 1},
    "UI-HUD-SHIELD-FILL": {"normal": 1, "hit": 1, "low": 1, "critical": 1},
    "UI-HUD-XP-FRAME": {"normal": 1, "hit": 1, "low": 1, "critical": 1},
    "UI-HUD-XP-FILL": {"normal": 1, "hit": 1, "low": 1, "critical": 1},
    "UI-HUD-DASH-BUTTON": {"ready": 1, "cooldown": 1, "disabled": 1, "pressed": 1, "focus": 1},
    "UI-HUD-DASH-RING": {"ready": 1, "cooldown": 1, "disabled": 1, "pressed": 1, "focus": 1},
    "UI-HUD-DAMAGE-DIRECTION": {"north": 1, "northEast": 1, "east": 1, "southEast": 1, "south": 1, "southWest": 1, "west": 1, "northWest": 1},
    "UI-HUD-WARNING-VIGNETTE": {"normal": 1, "low": 1, "critical": 1},
    "UI-RISK-PANEL": {"safe": 1, "risk": 1, "locked": 1, "selected": 1},
    "UI-RISK-SAFE": {"safe": 1, "risk": 1, "locked": 1, "selected": 1},
    "UI-RISK-BOUNTY": {"safe": 1, "risk": 1, "locked": 1, "selected": 1},
    "UI-RISK-OVERLOAD": {"safe": 1, "risk": 1, "locked": 1, "selected": 1},
    "UI-RESULT-PANEL": {"victory": 1, "defeat": 1},
    "UI-RESULT-MEDAL": {"bronze": 1, "silver": 1, "gold": 1, "none": 1},
    "UI-TOGGLE": {"on": 1, "off": 1, "focus": 1, "disabled": 1},
    "UI-ELITE-NAMEPLATE": {"normal": 1},
    "UI-ELITE-AFFIX-ACCEL": {"normal": 1},
    "UI-ELITE-AFFIX-SHIELD": {"normal": 1},
    "UI-ELITE-AFFIX-BARRAGE": {"normal": 1},
}


def states_for(asset_id: str) -> list[str]:
    if asset_id in STATE_SPECS:
        return list(STATE_SPECS[asset_id])
    if asset_id in SHIPS:
        return ["idle", "hit", "critical", "destroy"]
    if asset_id == "GFX-BOSS-AEGIS-BODY":
        return ["p1", "p2", "p3"]
    if asset_id == "GFX-BOSS-AEGIS-WEAKPOINT":
        return ["hidden", "shown", "hit"]
    if asset_id.startswith("UI-"):
        return ["normal", "pressed", "disabled", "focus"]
    if asset_id in PLAYER:
        return ["active", "end"]
    return ["default"]


def frame_count_for(asset_id: str, state: str) -> int:
    return STATE_SPECS.get(asset_id, {}).get(state, 1)


def frame_path(asset_id: str, state: str, index: int, count: int) -> Path:
    suffix = f"__{state}.png" if count == 1 else f"__{state}_f{index + 1:02d}.png"
    return ROOT / group(asset_id) / f"{asset_id}{suffix}"


def filter_for(state: str) -> str | None:
    """A baked state treatment, intentionally independent of runtime shaders."""
    if state in {"pressed", "hit", "drop"}:
        return "eq=brightness=0.08:saturation=1.20"
    if state in {"critical", "p3", "risk"}:
        return "colorchannelmixer=rr=1.20:gg=0.32:bb=0.68"
    if state in {"destroy", "end", "disabled", "hidden", "locked", "defeat", "none", "cooldown", "off"}:
        return "hue=s=0,eq=brightness=-0.20"
    if state in {"focus", "shown", "p2", "safe", "selected", "victory", "gold", "frontShield", "charge"}:
        return "eq=brightness=0.12:saturation=1.35"
    if state in {"active", "low", "ready", "on", "silver", "northEast", "east", "southEast", "south", "southWest", "west", "northWest"}:
        return "eq=saturation=1.15"
    return None


def main() -> None:
    all_graphics = [
        "GFX-PLAYER-BASE", *SHIPS, *PLAYER, *ELITE, "GFX-BOSS-AEGIS-BODY",
        *BOSS, *WEAPONS, *HAZARDS, *UPGRADES, *UI, *BACKGROUND,
    ]
    for asset_id in all_graphics:
        width, height = dimensions(asset_id)
        if asset_id == "GFX-PLAYER-BASE":
            width = height = 512
        elif asset_id == "GFX-BOSS-AEGIS-BODY":
            width = height = 1024
        master = ROOT / group(asset_id) / f"{asset_id}.png"
        if asset_id == "GFX-PLAYER-BASE":
            master = PACK / "图形" / "角色与敌机" / "GFX-PLAYER-BASE.png"
        elif asset_id == "GFX-BOSS-AEGIS-BODY":
            master = PACK / "图形" / "角色与敌机" / "GFX-BOSS-AEGIS-BODY.png"
        for state in states_for(asset_id):
            count = frame_count_for(asset_id, state)
            for index in range(count):
                output = frame_path(asset_id, state, index, count)
                output.parent.mkdir(parents=True, exist_ok=True)
                filter_text = filter_for(state)
                if state == "active" and count > 1:
                    # A three-frame trail contracts without needing a runtime shader.
                    filter_text = (filter_text or "eq=saturation=1.15") + f",eq=brightness={0.12 - index * 0.08:.2f}"
                if filter_text is None and master.suffix == ".png" and asset_id not in {"GFX-PLAYER-BASE", "GFX-BOSS-AEGIS-BODY"}:
                    shutil.copy2(master, output)
                    continue
                filters = [f"scale={width}:{height}:force_original_aspect_ratio=decrease", f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black@0"]
                if filter_text:
                    filters.append(filter_text)
                subprocess.run(
                    ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(master), "-vf", ",".join(filters), "-frames:v", "1", str(output)],
                    check=True,
                )


if __name__ == "__main__":
    main()
