#!/usr/bin/env python3
"""Publish a separately signed app without modifying a running executable's inode."""

import os
from pathlib import Path
import sys
import uuid


def publish_bundle(staged: Path, destination: Path) -> Path | None:
    staged = staged.absolute()
    destination = destination.absolute()
    if staged == destination or not staged.is_dir():
        raise ValueError("A separate, complete staged bundle is required")
    destination.parent.mkdir(parents=True, exist_ok=True)
    previous = None
    if destination.exists():
        backups = destination.parent / ".previous-builds"
        backups.mkdir(exist_ok=True)
        previous = backups / f"{destination.stem}-{uuid.uuid4()}.app"
        # Rename, never copy over or re-sign an executable used by a running process.
        os.replace(destination, previous)
    try:
        os.replace(staged, destination)
    except BaseException:
        if previous is not None:
            os.replace(previous, destination)
        raise
    return previous


if __name__ == "__main__":
    previous = publish_bundle(Path(sys.argv[1]), Path(sys.argv[2]))
    if previous:
        print(f"Previous bundle preserved at: {previous}")
