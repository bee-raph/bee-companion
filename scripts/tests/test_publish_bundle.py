import importlib.util
from pathlib import Path
from unittest.mock import patch
import pytest

spec = importlib.util.spec_from_file_location(
    "publish_bundle", Path(__file__).parents[1] / "publish_bundle.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def bundle(path, content):
    binary = path / "Contents" / "MacOS" / "Companion"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(content)
    return binary


def test_publishing_preserves_running_binary_inode(tmp_path):
    target = tmp_path / "Bee Companion.app"
    old_binary = bundle(target, b"old signed executable")
    old_inode = old_binary.stat().st_ino
    staged = tmp_path / "stage" / "Bee Companion.app"
    bundle(staged, b"new signed executable")
    with old_binary.open("rb") as running:
        previous = module.publish_bundle(staged, target)
        assert running.read() == b"old signed executable"
        preserved = previous / "Contents" / "MacOS" / "Companion"
        assert preserved.stat().st_ino == old_inode
        assert preserved.read_bytes() == b"old signed executable"
        assert old_binary.read_bytes() == b"new signed executable"
        assert old_binary.stat().st_ino != old_inode


def test_publication_failure_restores_existing_bundle(tmp_path):
    target = tmp_path / "Bee Companion.app"
    binary = bundle(target, b"original")
    staged = tmp_path / "stage" / "Bee Companion.app"
    bundle(staged, b"replacement")
    original = module.os.replace

    def replace(source, destination):
        if source == staged:
            raise OSError("Simulated publication failure")
        return original(source, destination)

    with patch.object(module.os, "replace", side_effect=replace):
        with pytest.raises(OSError):
            module.publish_bundle(staged, target)
    assert binary.read_bytes() == b"original"


def test_invalid_stage_leaves_existing_app_untouched(tmp_path):
    target = tmp_path / "Bee Companion.app"
    binary = bundle(target, b"original")
    with pytest.raises(ValueError):
        module.publish_bundle(target, target)
    assert binary.read_bytes() == b"original"
