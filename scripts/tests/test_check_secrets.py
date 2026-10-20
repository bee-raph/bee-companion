import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "check_secrets", Path(__file__).parents[1] / "check_secrets.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def test_private_paths_and_known_values():
    assert module.findings(".runtime/client.json", b"{}", [])
    assert module.findings(".env", b"anything", [])
    assert module.findings("app.py", b"copied credential", [b"credential"])
    assert not module.findings("README.md", b"Use your own key", [])


def test_token_prefixes_are_blocked_without_committing_a_real_token():
    fake = b"lse_" + b"live_" + b"x" * 32
    assert module.findings("app.py", fake, [])
