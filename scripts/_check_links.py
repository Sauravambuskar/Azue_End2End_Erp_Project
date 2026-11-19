#!/usr/bin/env python3
"""Check that every relative markdown link in the repository resolves.

Called by scripts/validate-local.sh.

Why this is a CI check and not a one-off: the guidance folder is 16 chapters
that cross-reference each other and the code. A renamed file silently breaks
links, and a guide with dead links is a guide nobody trusts. External http
links are not checked - they fail for reasons unrelated to this repository.
"""
from __future__ import annotations

import pathlib
import re
import sys

LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
SKIP_DIRS = (".venv", "node_modules", ".terraform", ".git", "__pycache__")

# Paths that are deliberately absent: exercise files the learner creates and
# then deletes during a break-it exercise.
EXPECTED_ABSENT = {
    "db/migrations/V004__add_product_barcode.sql",
    "db/migrations/V005__bad_lock.sql",
    "db/migrations/V006__will_fail.sql",
    "pipelines/sneaky.yml",
    "src/erp-api/app/vulnerable.py",
}


def main() -> int:
    root = pathlib.Path(".")
    broken: list[str] = []
    checked = 0

    for md in sorted(root.rglob("*.md")):
        if any(part in SKIP_DIRS for part in md.parts):
            continue

        text = md.read_text(encoding="utf-8", errors="replace")
        for _label, target in LINK_RE.findall(text):
            if target.startswith(("http://", "https://", "#", "mailto:")):
                continue

            path_part = target.split("#")[0]
            if not path_part:
                continue

            resolved = (md.parent / path_part).resolve()
            try:
                rel = resolved.relative_to(root.resolve()).as_posix()
            except ValueError:
                rel = path_part

            if rel in EXPECTED_ABSENT:
                continue

            checked += 1
            if not resolved.exists():
                broken.append(f"{md.as_posix()} -> {target}")

    if broken:
        print(f"{len(broken)} broken link(s):")
        for entry in broken:
            print(f"  {entry}")
        return 1

    print(f"{checked} relative link(s) resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
