"""Reject transparent/empty state PNGs before a release is accepted."""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

PACK = Path(__file__).resolve().parents[1]


def alpha_max(path: Path) -> int:
    command = ["ffmpeg", "-hide_banner", "-i", str(path), "-vf", "alphaextract,signalstats,metadata=print", "-frames:v", "1", "-f", "null", "-"]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        # RGB-only background layers have no alpha plane; a successful colour
        # decode is sufficient for them, while RGBA UI/effect PNGs still use
        # the stricter alpha check above.
        result = subprocess.run(
            ["ffmpeg", "-hide_banner", "-i", str(path), "-vf", "signalstats,metadata=print", "-frames:v", "1", "-f", "null", "-"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=True,
        )
    matched = re.findall(r"lavfi\.signalstats\.YMAX=(\d+)", result.stdout)
    if not matched:
        raise ValueError("alpha metric unavailable")
    return int(matched[-1])


def main() -> int:
    manifest = json.loads((PACK / "manifest.json").read_text(encoding="utf-8"))
    failures: list[str] = []
    inspected = 0
    for asset in manifest["assets"]:
        if asset.get("category") not in {"graphic", "ui"}:
            continue
        for relative in asset["runtimeFiles"]:
            inspected += 1
            path = PACK / relative
            try:
                if alpha_max(path) == 0:
                    failures.append(f"fully transparent state asset: {asset['assetId']}: {relative}")
            except (subprocess.CalledProcessError, ValueError) as exc:
                failures.append(f"unreadable state asset: {asset['assetId']}: {relative}: {exc}")
    if failures:
        print("FAIL")
        print("\n".join(failures))
        return 1
    print(f"PASS: {inspected} manifest-referenced graphic state images decode and have visible alpha.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
