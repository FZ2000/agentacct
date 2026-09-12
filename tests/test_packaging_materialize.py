"""Frozen framework aliases must not bypass the installer's payload contract."""

import importlib.util
import stat
from pathlib import Path

import pytest


_SPEC = importlib.util.spec_from_file_location(
    "materialize_cli", Path(__file__).parents[1] / "packaging/materialize-cli.py"
)
assert _SPEC is not None and _SPEC.loader is not None
_MODULE = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MODULE)
materialize = _MODULE.materialize


def test_framework_aliases_become_independent_files(tmp_path):
    root = tmp_path / "cli"
    version = root / "Python.framework/Versions/3.14"
    version.mkdir(parents=True)
    binary = version / "Python"
    binary.write_bytes(b"synthetic executable")
    binary.chmod(0o755)
    (version / "Resources").mkdir()
    (version / "Resources/Info.plist").write_text("fixture")
    (version.parent / "Current").symlink_to("3.14", target_is_directory=True)
    (root / "Python.framework/Python").symlink_to("Versions/Current/Python")
    (root / "Python.framework/Resources").symlink_to("Versions/Current/Resources", target_is_directory=True)
    (root / "Python").symlink_to("Python.framework/Python")

    materialize(root)

    assert not any(p.is_symlink() for p in root.rglob("*"))
    assert (root / "Python").read_bytes() == binary.read_bytes()
    assert stat.S_IMODE((root / "Python").stat().st_mode) == 0o755
    assert (root / "Python").stat().st_ino != binary.stat().st_ino
    assert (root / "Python.framework/Resources/Info.plist").read_text() == "fixture"
    before = binary.stat().st_ino
    materialize(root)
    assert binary.stat().st_ino == before  # Already regular output is a no-op.


@pytest.mark.parametrize("kind", ["external_file", "external_directory", "broken", "link_cycle", "directory_cycle", "fifo", "shared_write"])
def test_invalid_payload_is_rejected_without_replacing_source(tmp_path, kind):
    root = tmp_path / "cli"
    root.mkdir()
    sentinel = root / "agentacct"
    sentinel.write_text("keep original")
    inode = sentinel.stat().st_ino
    alias = root / "alias"
    if kind == "external_file":
        outside = tmp_path / "private"
        outside.write_text("must not copy")
        alias.symlink_to(outside)
    elif kind == "external_directory":
        alias.symlink_to(tmp_path, target_is_directory=True)
    elif kind == "broken":
        alias.symlink_to("absent")
    elif kind == "link_cycle":
        alias.symlink_to("other")
        (root / "other").symlink_to("alias")
    elif kind == "directory_cycle":
        alias.symlink_to(".", target_is_directory=True)
    elif kind == "fifo":
        import os
        os.mkfifo(alias)
    else:
        sentinel.chmod(0o666)

    with pytest.raises(ValueError):
        materialize(root)
    assert sentinel.read_text() == "keep original"
    assert sentinel.stat().st_ino == inode
    assert not list(tmp_path.glob(".agentacct-materialize-*"))


def test_linked_root_is_rejected(tmp_path):
    actual = tmp_path / "actual"
    actual.mkdir()
    alias = tmp_path / "cli"
    alias.symlink_to(actual, target_is_directory=True)
    with pytest.raises(ValueError, match="regular directory"):
        materialize(alias)
