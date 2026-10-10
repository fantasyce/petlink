#!/usr/bin/env python3
"""Validate the shipped catalogs, including interpolation arguments."""
from pathlib import Path
import plistlib
import json
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
resources = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "client/Resources"
catalogs = {}
for language in ("en", "zh-Hans"):
    path = resources / f"{language}.lproj/Localizable.strings"
    assert path.is_file(), f"Missing shipped language: {language}"
    catalogs[language] = plistlib.loads(subprocess.check_output(
        ["plutil", "-convert", "xml1", "-o", "-", str(path)]))
assert catalogs["en"].keys() == catalogs["zh-Hans"].keys(), "Catalog coverage differs"
for key, value in catalogs["en"].items():
    assert value.strip(), f"Empty English translation: {key}"
    assert not re.search(r"[\u3400-\u9fff]", value), f"Untranslated English: {key}"
    assert sorted(re.findall(r"\{\d+\}", key)) == sorted(re.findall(r"\{\d+\}", value)), f"Lost arguments: {key}"
for source in (root / "client").glob("*.swift"):
    if source.stem.endswith("Tests"):
        continue
    code = re.sub(r"(?m)^\s*//[^\n]*", "", source.read_text())
    for literal in re.findall(r'L10n\.text\(("(?:[^"\\]|\\.)*")', code):
        key = json.loads(literal)
        assert key in catalogs["en"], f"Missing translation in {source.name}: {key}"
    for literal in re.finditer(r'"(?:[^"\\]|\\.)*"', code):
        if not re.search(r"[\u3400-\u9fff]", literal.group()):
            continue
        # Language choices retain their own names. The model isolation prompt
        # is an internal protocol instruction, not interface text.
        if source.name == "PencilUI.swift" and literal.group() == '"简体中文"':
            continue
        if source.name == "AvatarAgentAdapters.swift" and "你是来访桌宠的只读问答分身" in literal.group():
            continue
        assert code[max(0, literal.start()-10):literal.start()] == "L10n.text(", f"Unlocalized interface text in {source.name}: {literal.group()[:70]}"
print(f"Both shipped catalogs cover {len(catalogs['en'])} messages with matching arguments")
