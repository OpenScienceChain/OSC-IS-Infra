#!/usr/bin/env python3
"""Create a deterministic, runtime-configured WebApp bundle for the edge bucket."""

from __future__ import annotations

import argparse
import gzip
import io
import json
import tarfile
from pathlib import Path


FIXED_MTIME = 0


def payload(source_revision: str) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "sourceRevision": source_revision,
        "demoMode": True,
        "apiBaseUrl": "/api/v1",
    }


def add_bytes(archive: tarfile.TarFile, name: str, value: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(value)
    info.mode = 0o644
    info.mtime = FIXED_MTIME
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    archive.addfile(info, io.BytesIO(value))


def build(source: Path, output: Path, source_revision: str) -> None:
    if not source.is_dir():
        raise SystemExit(f"WebApp source directory is absent: {source}")
    if not (source / "index.html").is_file():
        raise SystemExit("WebApp bundle must contain index.html")
    if len(source_revision) != 40 or any(c not in "0123456789abcdef" for c in source_revision):
        raise SystemExit("source revision must be a lower-case 40-character Git SHA")

    files: list[tuple[str, bytes]] = []
    for path in sorted(source.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink():
            raise SystemExit(f"WebApp bundle may not contain symbolic links: {path}")
        if path.is_file():
            relative = path.relative_to(source).as_posix()
            if relative not in {"assets/runtime-config.json", "release.json"}:
                files.append((relative, path.read_bytes()))

    encoded = (json.dumps(payload(source_revision), separators=(",", ":")) + "\n").encode()
    files.append(("assets/runtime-config.json", encoded))
    files.append(("release.json", encoded))
    files.sort(key=lambda item: item[0])

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=FIXED_MTIME) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for name, value in files:
                    add_bytes(archive, name, value)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    args = parser.parse_args()
    build(args.source, args.output, args.source_revision)


if __name__ == "__main__":
    main()
