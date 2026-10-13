"""Verify the manifest-defined first-run set fits the Web cold-load budget."""
from __future__ import annotations

import json
from pathlib import Path

PACK = Path(__file__).resolve().parents[1]
BUDGET_BYTES = 18 * 1024 * 1024


def main() -> int:
    manifest = json.loads((PACK / "manifest.json").read_text(encoding="utf-8"))
    first_run: set[str] = set()
    for asset in manifest["assets"]:
        if asset.get("loadGroup") == "firstRun":
            first_run.update(asset.get("runtimeFiles", []))
    total = sum((PACK / relative).stat().st_size for relative in first_run)
    runtime = PACK / "图形" / "运行时PNG"
    referenced = {
        relative
        for asset in manifest["assets"]
        if asset.get("category") in {"graphic", "ui"}
        for relative in asset.get("runtimeFiles", [])
    }
    orphaned = [str(path.relative_to(PACK)) for path in runtime.rglob("*") if path.is_file() and str(path.relative_to(PACK)) not in referenced]
    if total > BUDGET_BYTES or orphaned:
        print("FAIL")
        if total > BUDGET_BYTES:
            print(f"firstRun={total / 1024 / 1024:.2f} MiB exceeds 18.00 MiB")
        if orphaned:
            print(f"unreferenced runtime images: {len(orphaned)}")
        return 1
    print(f"PASS: firstRun={total / 1024 / 1024:.2f} MiB / 18.00 MiB; no unreferenced runtime images.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
