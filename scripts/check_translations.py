#!/usr/bin/env python3
"""Validate translation completeness, formatting arguments, and static UI references."""

import json
from pathlib import Path
import re
import sys

LANGUAGES = {"en", "he", "fr", "ru", "es"}
ROOT = Path(__file__).resolve().parents[1]
FORMAT = re.compile(r"%(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?(?:@|[diuoxXfFeEgGcCsSp%])")
REFERENCE = re.compile(r'L10n\.(?:text|format)\(\s*("(?:[^"\\]|\\.)*")')


RAW_UI = re.compile(
    r'\b(?:Text|Button|Link|Label|Picker|Toggle|TextField|SecureField|DatePicker|Menu)\(\s*("(?:[^"\\]|\\.)*")'
)


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
    for path in source.glob("*.swift"):
        contents = path.read_text()
        for match in RAW_UI.finditer(contents):
            try:
                key = json.loads(match[1])
            except ValueError:
                continue
            if key != "Bee Companion" and any(character.isalpha() for character in key):
                errors.append(f"{path.name}: UI label bypasses localization {key!r}")
        for match in REFERENCE.finditer(contents):
            try:
                key = json.loads(match[1])
            except ValueError:
                continue
            if key not in english:
                errors.append(f"{path.name}: missing UI translation {key!r}")
    return errors


if __name__ == "__main__":
    errors = check()
    if errors:
        print("\n".join(errors), file=sys.stderr)
        raise SystemExit(1)
    print(
        "Translations verified: five matching catalogs, valid formatting arguments and static UI references."
    )
