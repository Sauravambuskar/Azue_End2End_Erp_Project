#!/usr/bin/env python3
"""Validate that every pipeline and manifest YAML file parses.

Called by scripts/validate-local.sh. Exits non-zero and lists the offenders
if any file fails to parse.

This catches the single most common pipeline mistake: a YAML indentation
error that Azure DevOps only reports when you push and queue a run.
"""
from __future__ import annotations

import glob
import sys

try:
    import yaml
except ImportError:
    print("pyyaml not installed: pip install pyyaml", file=sys.stderr)
    sys.exit(0)  # skip rather than fail


TARGETS = (
    glob.glob("pipelines/**/*.yml", recursive=True)
    + glob.glob("pipelines/**/*.yaml", recursive=True)
    + glob.glob("k8s/base/*.yaml")
    + glob.glob("security/**/*.yml", recursive=True)
    + ["docker-compose.yml"]
)


def main() -> int:
    bad: list[str] = []
    checked = 0

    for path in sorted(set(TARGETS)):
        try:
            with open(path, encoding="utf-8") as fh:
                list(yaml.safe_load_all(fh))
            checked += 1
        except FileNotFoundError:
            continue
        except Exception as exc:  # noqa: BLE001 - report anything that fails
            bad.append(f"{path}: {exc}")

    if bad:
        for entry in bad:
            print(entry)
        return 1

    print(f"{checked} YAML file(s) parsed cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
