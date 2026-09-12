#!/usr/bin/env python3
"""Make a frozen onedir payload satisfy the app's no-link install contract.

PyInstaller preserves framework aliases on macOS. Copy only aliases resolving
inside this build output; never relax the installed payload validator. Run before
smoke tests, provenance stamping, and distribution signing.
"""

from __future__ import annotations

import argparse
import shutil
import stat
import tempfile
from pathlib import Path


def materialize(root: Path) -> None:
    if root.is_symlink() or not root.is_dir():
        raise ValueError("Frozen payload must be a regular directory")
    root = root.resolve()
    has_links = False

    def validate(path: Path, ancestors: frozenset[Path]) -> None:
        nonlocal has_links
        has_links |= path.is_symlink()
        try:
            target = path.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise ValueError(f"Broken or cyclic payload alias: {path}") from error
        if not target.is_relative_to(root):
            raise ValueError(f"Payload alias leaves build output: {path}")
        mode = target.stat().st_mode
        if mode & 0o022:
            raise ValueError(f"Payload entry is writable by other users: {path}")
        if stat.S_ISDIR(mode):
            if target in ancestors:
                raise ValueError(f"Cyclic payload directory alias: {path}")
            for child in target.iterdir():
                validate(child, ancestors | {target})
        elif not stat.S_ISREG(mode):
            raise ValueError(f"Unsupported payload entry: {path}")

    # Validate the complete alias graph before copying or replacing any output.
    validate(root, frozenset())
    if not has_links:
        return
    with tempfile.TemporaryDirectory(prefix=".agentacct-materialize-", dir=root.parent) as temporary:
        stage = Path(temporary) / "payload"
        previous = Path(temporary) / "previous"
        shutil.copytree(root, stage, symlinks=False)
        root.rename(previous)
        try:
            stage.rename(root)
        except BaseException:
            previous.rename(root)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("payload", type=Path)
    materialize(parser.parse_args().payload)
