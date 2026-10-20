#!/usr/bin/env python3
import argparse, json
from pathlib import Path
from app.main import app

p = argparse.ArgumentParser()
p.add_argument("--check", action="store_true")
args = p.parse_args()
path = Path(__file__).resolve().parents[1] / "backend/openapi.json"
text = json.dumps(app.openapi(), indent=2, sort_keys=True) + "\n"
if args.check:
    if not path.exists() or path.read_text() != text:
        raise SystemExit("API schema changed: regenerate backend/openapi.json")
else:
    path.write_text(text)
