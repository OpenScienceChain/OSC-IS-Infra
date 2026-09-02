#!/usr/bin/env python3
"""Render Argo CD bootstrap manifests from verified immutable artifacts."""

from __future__ import annotations

import argparse
from pathlib import Path


def render(source: Path, destination: Path, replacements: dict[str, str]) -> None:
    text = source.read_text(encoding="utf-8")
    for token, value in replacements.items():
        text = text.replace(token, value)
    if "__" in text:
        raise SystemExit(f"Unresolved bootstrap token in {source}")
    destination.write_text(text, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--repository-image", required=True)
    parser.add_argument("--baseline-revision", required=True)
    parser.add_argument("--rollout-revision", required=True)
    args = parser.parse_args()
    if "@sha256:" not in args.repository_image:
        raise SystemExit("Repository image must be immutable")
    args.destination.mkdir(parents=True, exist_ok=True)
    replacements = {
        "__REPOSITORY_IMAGE__": args.repository_image,
        "__BASELINE_REVISION__": args.baseline_revision,
        "__ROLLOUT_REVISION__": args.rollout_revision,
    }
    render(
        args.bootstrap / "repository-server.yaml",
        args.destination / "repository-server.yaml",
        replacements,
    )
    render(
        args.bootstrap / "application-aws.yaml",
        args.destination / "application.yaml",
        replacements,
    )
    print(f"Rendered Argo CD bootstrap at {args.destination}")


if __name__ == "__main__":
    main()
