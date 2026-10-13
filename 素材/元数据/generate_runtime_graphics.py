"""Build deterministic, individually named runtime PNG assets for v2.0.

The generated SVG source is deliberately retained beside the PNG export so TA can
adjust colours and geometry without touching gameplay code.  It fills the direct
load contract for every UI, warning and effect Asset ID; the authored AI character
art remains the preferred source for ship bodies in the manifest.
"""
from __future__ import annotations

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1] / "图形" / "运行时PNG"
SOURCE = Path(__file__).resolve().parents[1] / "图形" / "源SVG"

PLAYER = ["GFX-PLAYER-ENGINE-CRITICAL", "GFX-PLAYER-SHIELD-HIT", "GFX-PLAYER-HIT-FLASH", "GFX-PLAYER-DASH-TRAIL"]
SHIPS = ["GFX-EN-SCOUT", "GFX-EN-WING", "GFX-EN-SNIPER", "GFX-EN-BOMBER", "GFX-EN-SHIELD"]
ELITE = ["GFX-ELITE-AURA-ACCEL", "GFX-ELITE-AURA-SHIELD", "GFX-ELITE-AURA-BARRAGE"]
BOSS = ["GFX-BOSS-AEGIS-WEAKPOINT", "GFX-BOSS-AEGIS-CRITICAL", "GFX-BOSS-ENTRY", "GFX-BOSS-PHASE", "GFX-BOSS-DEFEAT"]
WEAPONS = ["GFX-WPN-PULSE", "GFX-WPN-PULSE-MUZZLE", "GFX-FX-PULSE-HIT", "GFX-FX-PULSE-CRIT", "GFX-WPN-ARC", "GFX-WPN-MISSILE", "GFX-WPN-MISSILE-TRAIL", "GFX-FX-MISSILE-BLAST", "GFX-WPN-LASER-HEAD", "GFX-WPN-LASER-BEAM", "GFX-WPN-LASER-IMPACT", "GFX-WPN-DRONE", "GFX-WPN-DRONE-BOLT"]
HAZARDS = ["GFX-ENEMY-BULLET-WING", "GFX-ENEMY-BULLET-SNIPER", "GFX-ENEMY-BULLET-SHIELD", "GFX-HAZARD-BOMBER-WARN", "GFX-HAZARD-BOMBER-ACTIVE", "GFX-WARN-LINE", "GFX-WARN-CONE", "GFX-WARN-CIRCLE", "GFX-BOSS-FAN-BULLET", "GFX-BOSS-RING-BULLET", "GFX-BOSS-LASER", "GFX-PICKUP-ELITE-CORE", "GFX-PICKUP-SUPPLY-HEAL", "GFX-PICKUP-SUPPLY-SHIELD", "GFX-PICKUP-SUPPLY-DASH", "GFX-ENEMY-BREACH-WARN"]
UPGRADES = ["UI-UP-PULSE-RATE", "UI-UP-PULSE-DAMAGE", "UI-UP-PULSE-SPREAD", "UI-UP-CRIT-ARC", "UI-UP-MISSILE-UNLOCK", "UI-UP-MISSILE-SALVO", "UI-UP-MISSILE-RADIUS", "UI-UP-LASER-UNLOCK", "UI-UP-LASER-PRISM", "UI-UP-DRONE-UNLOCK", "UI-UP-DRONE-COUNT", "UI-UP-SHIELD-MAX", "UI-UP-DASH-CHARGE", "UI-UP-DASH-REPAIR", "UI-UP-ENERGY-GAIN", "UI-UP-COMBO-GUARD"]
UI = ["UI-HUD-HP-FRAME", "UI-HUD-HP-FILL", "UI-HUD-SHIELD-FRAME", "UI-HUD-SHIELD-FILL", "UI-HUD-XP-FRAME", "UI-HUD-XP-FILL", "UI-HUD-LV-BADGE", "UI-HUD-COMBO", "UI-HUD-TIMER", "UI-HUD-BOSS-FRAME", "UI-HUD-BOSS-FILL", "UI-HUD-BOSS-WEAKPOINT", "UI-HUD-DASH-BUTTON", "UI-HUD-DASH-RING", "UI-HUD-PAUSE", "UI-HUD-DAMAGE-DIRECTION", "UI-HUD-WARNING-VIGNETTE", "UI-HUD-OBJECTIVE", "UI-BOSS-NAMEPLATE", "UI-BOSS-PHASE", "UI-BOSS-ATTACK-WARN", "UI-HOME-LOGO", "UI-LOAD-PROGRESS", "UI-BUTTON-PRIMARY", "UI-BUTTON-SECONDARY", "UI-ICON-SETTINGS", "UI-ICON-MUTE", "UI-ICON-BACK", "UI-ICON-RETRY", "UI-BRIEFING-PANEL", "UI-BRIEFING-TIP", "UI-SETTINGS-PANEL", "UI-SLIDER-TRACK", "UI-SLIDER-FILL", "UI-SLIDER-THUMB", "UI-DRAFT-PANEL", "UI-DRAFT-CARD", "UI-RARITY-COMMON", "UI-RARITY-RARE", "UI-RARITY-EPIC", "UI-RISK-PANEL", "UI-RISK-SAFE", "UI-RISK-BOUNTY", "UI-RISK-OVERLOAD", "UI-TOOLTIP", "UI-PAUSE-PANEL", "UI-TOGGLE", "UI-RESULT-PANEL", "UI-RESULT-MEDAL", "UI-FOCUS-RING", "UI-COLORBLIND-PATTERN-DANGER", "UI-COLORBLIND-PATTERN-REWARD", "UI-COLORBLIND-PATTERN-RARITY", "GFX-FALLBACK-SILHOUETTE", "UI-FALLBACK-ICON"]
BACKGROUND = ["GFX-BG-DEEP-SPACE", "GFX-BG-NEBULA", "GFX-BG-STARS", "GFX-BG-GRID"]

# HUD bars are real horizontal, stretch-safe exports instead of square icon
# placeholders.  Values are physical PNG dimensions at 1x runtime scale.
BAR_ASSETS = {
    "UI-HUD-HP-FRAME", "UI-HUD-HP-FILL", "UI-HUD-SHIELD-FRAME",
    "UI-HUD-SHIELD-FILL", "UI-HUD-XP-FRAME", "UI-HUD-XP-FILL",
    "UI-HUD-BOSS-FRAME", "UI-HUD-BOSS-FILL", "UI-LOAD-PROGRESS",
}

def colour(asset: str) -> tuple[str, str]:
    if "PICKUP" in asset or "HEAL" in asset or "ENERGY" in asset or "BOUNTY" in asset:
        return "#FFB703", "#FFF2B2"
    if "ENEMY" in asset or "BOSS" in asset or "DANGER" in asset or "WARN" in asset or "CRIT" in asset:
        return "#FF3CAC", "#9C27FF"
    return "#11D9FF", "#DDFBFF"

def svg(asset: str) -> str:
    primary, light = colour(asset)
    if asset in BACKGROUND:
        if asset.endswith("DEEP-SPACE"):
            body = '<rect width="1920" height="1080" fill="#050716"/><radialGradient id="g"><stop stop-color="#17235A"/><stop offset="1" stop-color="#050716"/></radialGradient><rect width="1920" height="1080" fill="url(#g)" opacity=".75"/>'
        elif asset.endswith("NEBULA"):
            body = '<rect width="1920" height="1080" fill="#070A1A"/><path d="M-80 800 C400 240 820 1110 2000 170" stroke="#392B7B" stroke-width="270" opacity=".35" fill="none"/>'
        elif asset.endswith("STARS"):
            body = ''.join(f'<circle cx="{(i*137)%1920}" cy="{(i*251)%1080}" r="{1+i%3}" fill="#B7F6FF" opacity=".{3+i%6}"/>' for i in range(72))
        else:
            body = '<rect width="1920" height="1080" fill="#050716"/><path d="M0 1080 L960 420 L1920 1080 M0 920 H1920 M0 760 H1920" stroke="#0EA6C6" stroke-width="3" opacity=".35" fill="none"/>'
        return f'<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">{body}</svg>'
    # Shared readable neon language: outline + independent silhouette, no baked text.
    special = ""
    if "FRAME" in asset or "PANEL" in asset or "CARD" in asset or "BUTTON" in asset or "TOOLTIP" in asset or "NAMEPLATE" in asset:
        special = f'<rect x="32" y="112" width="448" height="288" rx="34" fill="#08162B" stroke="{primary}" stroke-width="14"/><path d="M72 155 H440" stroke="{light}" stroke-width="5" opacity=".55"/>'
    elif "FILL" in asset or "BEAM" in asset or "LINE" in asset or "TRAIL" in asset:
        special = f'<path d="M42 256 H470" stroke="{primary}" stroke-width="72" stroke-linecap="round"/><path d="M42 256 H470" stroke="{light}" stroke-width="16" stroke-linecap="round"/>'
    elif "RING" in asset or "AURA" in asset or "CIRCLE" in asset or "SHIELD" in asset:
        special = f'<circle cx="256" cy="256" r="172" fill="none" stroke="{primary}" stroke-width="42"/><circle cx="256" cy="256" r="120" fill="none" stroke="{light}" stroke-width="8" opacity=".8"/>'
    elif "WARN" in asset or "DAMAGE-DIRECTION" in asset or "BREACH" in asset or "CONE" in asset:
        special = f'<path d="M256 42 L466 448 H46 Z" fill="{primary}" opacity=".35" stroke="{light}" stroke-width="16"/><path d="M256 135 V330" stroke="{light}" stroke-width="26" stroke-linecap="round"/>'
    elif "MISSILE" in asset or "PULSE" in asset or "BULLET" in asset or "BOLT" in asset:
        special = f'<path d="M256 54 C356 170 356 342 256 458 C156 342 156 170 256 54 Z" fill="{primary}" stroke="{light}" stroke-width="12"/><circle cx="256" cy="225" r="42" fill="{light}"/>'
    elif "PICKUP" in asset or "MEDAL" in asset or "CORE" in asset:
        special = f'<path d="M256 48 L452 256 L256 464 L60 256 Z" fill="{primary}" stroke="{light}" stroke-width="14"/><path d="M180 256 H332 M256 180 V332" stroke="#FFFFFF" stroke-width="26" stroke-linecap="round"/>'
    elif "ICON" in asset or "PAUSE" in asset or "TOGGLE" in asset or "DASH" in asset:
        special = f'<circle cx="256" cy="256" r="174" fill="#08162B" stroke="{primary}" stroke-width="18"/><path d="M202 160 V352 M310 160 V352" stroke="{light}" stroke-width="36" stroke-linecap="round"/>'
    else:
        special = f'<path d="M256 44 L430 156 L386 438 L126 438 L82 156 Z" fill="#0A2745" stroke="{primary}" stroke-width="16"/><circle cx="256" cy="256" r="72" fill="{light}"/><path d="M256 92 V420 M112 256 H400" stroke="{primary}" stroke-width="10" opacity=".7"/>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><defs><filter id="glow"><feGaussianBlur stdDeviation="6"/></filter></defs><g filter="url(#glow)" opacity=".5">{special}</g>{special}</svg>'

def group(asset: str) -> str:
    if asset.startswith("UI-"):
        return "UI界面"
    if asset.startswith("GFX-BG"):
        return "场景背景"
    if asset.startswith("GFX-PLAYER") or asset.startswith("GFX-ELITE") or asset.startswith("GFX-BOSS") or asset in SHIPS:
        return "战斗特效"
    return "投射物与预警"


def dimensions(asset: str) -> tuple[int, int]:
    if asset in BACKGROUND:
        return (1920, 1080)
    if asset in BAR_ASSETS:
        return (960, 96)
    return (512, 512)

def main() -> None:
    for asset in [*SHIPS, *PLAYER, *ELITE, *BOSS, *WEAPONS, *HAZARDS, *UPGRADES, *UI, *BACKGROUND]:
        target = SOURCE / group(asset)
        target.mkdir(parents=True, exist_ok=True)
        source = target / f"{asset}.svg"
        source.write_text(svg(asset), encoding="utf-8")
        output = ROOT / group(asset) / f"{asset}.png"
        output.parent.mkdir(parents=True, exist_ok=True)
        width, height = dimensions(asset)
        subprocess.run(
            ["rsvg-convert", "-w", str(width), "-h", str(height), "-o", str(output), str(source)],
            check=True,
        )

if __name__ == "__main__":
    main()
