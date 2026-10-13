"""Objective audio release gate for the Warship standalone asset package."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

PACK = Path(__file__).resolve().parents[1]
WAV = PACK / "音频" / "母带WAV"


def output_for(args: list[str]) -> str:
    completed = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True)
    return completed.stdout


def last_float(pattern: str, text: str) -> float:
    values = re.findall(pattern, text, re.S)
    if not values:
        raise ValueError(f"metric not found: {pattern}")
    return float(values[-1])


def main() -> int:
    errors: list[str] = []
    report: list[str] = []
    for path in sorted(WAV.glob("BGM-*.wav")):
        raw = output_for(["ffmpeg", "-hide_banner", "-i", str(path), "-filter_complex", "ebur128=peak=true", "-f", "null", "-"])
        lufs = last_float(r"Integrated loudness:.*?I:\s*([-0-9.]+) LUFS", raw)
        peak = last_float(r"True peak:.*?Peak:\s*([-0-9.]+) dBFS", raw)
        report.append(f"{path.stem}: {lufs:.1f} LUFS / {peak:.1f} dBFS")
        if not -17.5 <= lufs <= -14.5:
            errors.append(f"BGM loudness outside release window: {path.stem}={lufs:.1f} LUFS")
        if peak > -1.0:
            errors.append(f"BGM true peak exceeds ceiling: {path.stem}={peak:.1f} dBFS")
    for path in sorted(WAV.glob("SFX-*.wav")):
        raw = output_for(["ffmpeg", "-hide_banner", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"])
        peak = last_float(r"max_volume:\s*([-0-9.]+) dB", raw)
        if peak > -1.0:
            errors.append(f"SFX peak exceeds ceiling: {path.stem}={peak:.1f} dB")
    if errors:
        print("FAIL")
        print("\n".join(errors))
        return 1
    print("PASS: BGM mix verified; all SFX master peaks are <= -1 dB.")
    print("\n".join(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
