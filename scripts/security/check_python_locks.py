#!/usr/bin/env python3
"""Validate the system-test probe's exact, hash-locked dependencies."""

import re
import sys
from pathlib import Path


REQUIREMENT_RE = re.compile(r"^([A-Za-z0-9_.-]+)==([^\s;\\]+)")


def canonical(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def load(path: Path, require_hashes: bool) -> dict[str, str]:
    result = {}
    current = ""
    hashed = False
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if raw and not raw[0].isspace():
            if current and require_hashes and not hashed:
                raise ValueError(f"{path}: {current} has no SHA-256 hash")
            match = REQUIREMENT_RE.match(line)
            if not match:
                raise ValueError(f"{path}:{line_number}: requirement must use exact == pin")
            current = canonical(match.group(1))
            result[current] = match.group(2)
            hashed = "--hash=sha256:" in raw
        elif "--hash=sha256:" in raw:
            hashed = True
    if current and require_hashes and not hashed:
        raise ValueError(f"{path}: {current} has no SHA-256 hash")
    return result


def main() -> int:
    component = Path("system-tests/probe")
    try:
        direct = load(component / "requirements.txt", False)
        locked = load(component / "requirements.lock", True)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"PYTHON LOCK CHECK FAILED: {exc}", file=sys.stderr)
        return 1
    stale = [f"{name}=={version}" for name, version in direct.items() if locked.get(name) != version]
    if stale:
        print(f"PYTHON LOCK CHECK FAILED: stale entries: {', '.join(stale)}", file=sys.stderr)
        return 1
    print("Python lock check passed for system-tests/probe.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
