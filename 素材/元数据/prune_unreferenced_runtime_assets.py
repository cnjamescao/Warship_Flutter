"""Remove generated runtime image intermediates not referenced by manifest.json.

Run only after the manifest is generated.  Source SVG/PNG, atlases and WAV
masters live outside 图形/运行时PNG and are never considered by this tool.
"""
from __future__ import annotations

import json
from pathlib import Path

PACK = Path(__file__).resolve().parents[1]
RUNTIME = PACK / "图形" / "运行时PNG"


def main() -> None:
    manifest = json.loads((PACK / "manifest.json").read_text(encoding="utf-8"))
    referenced = {
        relative
        for asset in manifest["assets"]
        if asset.get("category") in {"graphic", "ui"}
        for relative in asset.get("runtimeFiles", [])
    }
    removed: list[str] = []
    for path in sorted(RUNTIME.rglob("*")):
        if not path.is_file():
            continue
        relative = str(path.relative_to(PACK))
        if relative not in referenced:
            path.unlink()
            removed.append(relative)
    print(f"Pruned {len(removed)} generated, unreferenced runtime images.")


if __name__ == "__main__":
    main()
