"""Export WebP-primary background variants with PNG fallback retained."""
from __future__ import annotations

import subprocess
from pathlib import Path

from generate_runtime_graphics import BACKGROUND, group
from generate_runtime_state_variants import frame_path, frame_count_for, states_for

PACK = Path(__file__).resolve().parents[1]
ROOT = PACK / "图形" / "运行时PNG"


def webp_path(asset_id: str, state: str, index: int, count: int) -> Path:
    png = frame_path(asset_id, state, index, count)
    return png.with_suffix(".webp")


def main() -> None:
    for asset_id in BACKGROUND:
        for state in states_for(asset_id):
            count = frame_count_for(asset_id, state)
            for index in range(count):
                source = frame_path(asset_id, state, index, count)
                target = webp_path(asset_id, state, index, count)
                target.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(["cwebp", "-quiet", "-q", "82", str(source), "-o", str(target)], check=True)


if __name__ == "__main__":
    main()
