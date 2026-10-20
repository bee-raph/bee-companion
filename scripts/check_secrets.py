#!/usr/bin/env python3
"""Inspect staged file contents without printing credentials. Exits nonzero on findings."""

import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = [
    re.compile(rb"lse_live_[A-Za-z0-9]{20,}"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(rb"sk-(?:proj-)?[A-Za-z0-9_-]{24,}"),
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
]


def findings(path, data, known):
    parts = Path(path).parts
    if any(part.startswith(".runtime") or part == "secrets" for part in parts):
        return True
    if Path(path).name.startswith(".env") and Path(path).name != ".env.example":
        return True
    if Path(path).suffix.lower() in {".pem", ".p12", ".pfx", ".key", ".sqlite", ".db"}:
        return True
    return any(pattern.search(data) for pattern in PATTERNS) or any(
        value in data for value in known
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--staged", action="store_true", required=True)
    parser.parse_args()
    names = (
        subprocess.check_output(
            ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
            cwd=ROOT,
        )
        .decode()
        .split("\0")
    )
    known = []
    runtime = ROOT / ".runtime"
    for name in ["lse_api_key", "db_password"]:
        path = runtime / name
        if path.exists() and len(path.read_bytes().strip()) >= 12:
            known.append(path.read_bytes().strip())
    password = runtime / "initial-login.txt"
    if password.exists() and "Password: " in password.read_text():
        known.append(password.read_text().split("Password: ", 1)[1].strip().encode())
    bad = []
    for name in filter(None, names):
        data = subprocess.check_output(["git", "show", ":" + name], cwd=ROOT)
        if findings(name, data, known):
            bad.append(name)
    if bad:
        print("Secret or private deployment material detected in these staged paths:")
        for name in bad:
            print(name)
        return 1
    print(
        f"Secret check passed for {sum(bool(name) for name in names)} staged files. No known local keys/passwords or recognizable tokens found."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
