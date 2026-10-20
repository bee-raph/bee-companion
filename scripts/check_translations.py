#!/usr/bin/env python3
"""Validate translation completeness, formatting arguments, and static UI references."""

import ast
import json
import plistlib
from pathlib import Path
import re
import sys

LANGUAGES = {"en", "he", "fr", "ru", "es"}
ROOT = Path(__file__).resolve().parents[1]
FORMAT = re.compile(r"%(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?(?:@|[diuoxXfFeEgGcCsSp%])")
REFERENCE = re.compile(
    r'(?:L10n\.(?:text|format|message)|CompanionError\.message)\(\s*("(?:[^"\\]|\\.)*")'
)


RAW_UI = re.compile(
    r'\b(?:Text|Button|Link|Label|Picker|Toggle|TextField|SecureField|DatePicker|Menu|TableColumn|Section|help|navigationTitle|accessibilityLabel|alert|confirmationDialog)\(\s*("(?:[^"\\]|\\.)*")'
)


HELPER_LABEL = re.compile(
    r'\b(?:title|subtitle|detail|addTitle|removeTitle):\s*("(?:[^"\\]|\\.)*")'
)


def backend_messages(root):
    values = set()
    for name in ["main.py", "market.py", "reader.py", "crm.py"]:
        path = root / "backend/app" / name
        if not path.exists():
            continue
        for node in ast.walk(ast.parse(path.read_text())):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
                continue
            if node.func.id == "HTTPException":
                arguments = node.args[1:] + [
                    v.value for v in node.keywords if v.arg == "detail"
                ]
            elif node.func.id == "ValueError":
                arguments = node.args
            else:
                continue
            values.update(
                v.value
                for v in arguments
                if isinstance(v, ast.Constant) and isinstance(v.value, str)
            )
    return values


def permission_errors(root):
    info = root / "macos/Info.plist"
    if not info.exists():
        return []
    metadata = plistlib.loads(info.read_bytes())
    errors = []
    if set(metadata.get("CFBundleLocalizations", [])) != LANGUAGES:
        errors.append("App bundle must declare all five interface languages")
    keys = {
        key
        for key in metadata
        if key.startswith("NSCalendars") and key.endswith("UsageDescription")
    }
    for language in LANGUAGES:
        path = (
            root / "macos/Localizations" / (language + ".lproj") / "InfoPlist.strings"
        )
        try:
            entries = re.findall(
                r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;', path.read_text()
            )
            values = unique_keys((json.loads(k), json.loads(v)) for k, v in entries)
            if set(values) != keys or any(not v.strip() for v in values.values()):
                errors.append(
                    f"{language}: missing or empty calendar permission translation"
                )
        except (OSError, ValueError) as error:
            errors.append(str(error))
    return errors


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate translation key: {key}")
        result[key] = value
    return result


def check(root=ROOT):
    source = root / "macos/Sources/Companion"
    try:
        catalog = json.loads(
            (source / "Resources/Translations.json").read_text(),
            object_pairs_hook=unique_keys,
        )
    except (OSError, ValueError) as error:
        return [str(error)]
    errors = []
    if set(catalog) != LANGUAGES:
        errors.append("Expected exactly English, Hebrew, French, Russian and Spanish")
    english = catalog.get("en", {})
    if not english:
        errors.append("English catalog is empty")
    for language in sorted(LANGUAGES):
        values = catalog.get(language, {})
        if set(values) != set(english):
            errors.append(f"{language}: missing or extra translation keys")
        for key, value in values.items():
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{language}: empty translation for {key!r}")
            elif FORMAT.findall(key) != FORMAT.findall(value):
                errors.append(f"{language}: formatting arguments differ for {key!r}")
    for path in source.rglob("*.swift"):
        contents = path.read_text()
        for match in RAW_UI.finditer(contents):
            try:
                key = json.loads(match[1])
            except ValueError:
                continue
            if key != "Bee Companion" and any(character.isalpha() for character in key):
                errors.append(f"{path.name}: UI label bypasses localization {key!r}")
        for match in list(REFERENCE.finditer(contents)) + list(
            HELPER_LABEL.finditer(contents)
        ):
            try:
                key = json.loads(match[1])
            except ValueError:
                continue
            if key not in english:
                errors.append(f"{path.name}: missing UI translation {key!r}")
    for message in sorted(backend_messages(root) - set(english)):
        errors.append(f"Missing backend message translation {message!r}")
    errors.extend(permission_errors(root))
    return errors


if __name__ == "__main__":
    errors = check()
    if errors:
        print("\n".join(errors), file=sys.stderr)
        raise SystemExit(1)
    print(
        "Translations verified: five matching catalogs, valid formatting arguments and static UI references."
    )
