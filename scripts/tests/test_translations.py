import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "translations", Path(__file__).parents[1] / "check_translations.py"
)
translations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(translations)


def fixture(tmp_path, value="Hello %@"):
    source = tmp_path / "macos/Sources/Companion"
    (source / "Resources").mkdir(parents=True)
    catalog = {language: {"Hello %@": value} for language in translations.LANGUAGES}
    target = source / "Resources/Translations.json"
    target.write_text(json.dumps(catalog))
    return source, target, catalog


def test_repository_translations_are_complete():
    assert translations.check() == []


def test_detects_missing_ui_labels_and_format_arguments(tmp_path):
    source, target, catalog = fixture(tmp_path)
    (source / "Screen.swift").write_text('Text(L10n.text("Missing label"))')
    catalog["he"]["Hello %@"] = "שלום"
    target.write_text(json.dumps(catalog))
    errors = translations.check(tmp_path)
    assert any("Missing label" in error for error in errors)
    assert any("formatting arguments" in error for error in errors)


def test_detects_empty_and_missing_translations(tmp_path):
    _, target, catalog = fixture(tmp_path)
    catalog["fr"] = {}
    catalog["es"]["Hello %@"] = ""
    target.write_text(json.dumps(catalog))
    assert len(translations.check(tmp_path)) == 2


def test_rejects_duplicate_translation_keys(tmp_path):
    _, target, _ = fixture(tmp_path)
    target.write_text('{"en": {"Title": "Title", "Title": "Other"}}')
    assert "Duplicate translation key" in translations.check(tmp_path)[0]


def test_detects_unlocalized_interface_label(tmp_path):
    source, _, _ = fixture(tmp_path)
    (source / "Screen.swift").write_text('Button("Save") { }')
    assert any(
        "bypasses localization" in error for error in translations.check(tmp_path)
    )


def test_detects_missing_helper_labels_and_backend_messages(tmp_path):
    source, _, _ = fixture(tmp_path)
    (source / "Screen.swift").write_text(
        'BeeEmptyState(title: "Missing heading", detail: "Hello %@")'
    )
    backend = tmp_path / "backend/app"
    backend.mkdir(parents=True)
    (backend / "main.py").write_text(
        'raise HTTPException(401, "Missing server message")'
    )
    errors = translations.check(tmp_path)
    assert any("Missing heading" in error for error in errors)
    assert any("Missing server message" in error for error in errors)


def test_detects_missing_calendar_permission_translations(tmp_path):
    import plistlib

    fixture(tmp_path)
    (tmp_path / "macos/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleLocalizations": sorted(translations.LANGUAGES),
                "NSCalendarsFullAccessUsageDescription": "Calendar access",
            }
        )
    )
    errors = translations.check(tmp_path)
    assert len(errors) == 5
    assert all("InfoPlist.strings" in error for error in errors)
