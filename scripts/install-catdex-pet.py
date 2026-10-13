#!/usr/bin/env python3
"""Overwrite Catdex (Terminal) with a validated repair, keeping a backup.

Dry-run by default. The desktop artwork and width are never changed. If the
desktop selected the terminal pet, select Catdex there to restore its aspect
ratio. No app or terminal process is restarted.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import tomllib


def atomic_write(path, data, mode=0o644):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".catdex-", delete=False) as f:
        temporary = Path(f.name)
        f.write(data)
    try:
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def replace_setting(text, section, key, value):
    lines = text.splitlines(keepends=True)
    current_section = None
    replacements = 0
    for i, line in enumerate(lines):
        header = re.fullmatch(r"\s*\[([^\]]+)\]\s*(?:#.*)?", line.strip())
        if header:
            current_section = header[1]
        if current_section != section:
            continue
        match = re.fullmatch(r"(\s*" + re.escape(key) + r"\s*=\s*)([^#\r\n]*)([^\r\n]*)(\r?\n)?", line)
        if match:
            lines[i] = match[1] + value + (" " + match[3] if match[3] else "") + (match[4] or "")
            replacements += 1
    if replacements != 1:
        raise ValueError(f"Expected exactly one [{section}] {key}, found {replacements}")
    return "".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("staged", type=Path)
    parser.add_argument("--codex-dir", type=Path, default=Path.home() / ".codex")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    report = json.loads((args.staged / "validation.json").read_text())
    visual = json.loads((args.staged / "visual-qa.json").read_text())
    if (report.get("ok") is not True or visual.get("verdict") != "pass"
            or visual.get("terminal_review") != "pass"):
        raise ValueError("Deterministic and visual QA must pass before installation")
    config_path = args.codex_dir / "config.toml"
    before_config = config_path.read_bytes()
    before = tomllib.loads(before_config.decode())
    if before["tui"]["pet"] not in ("custom:catdex", "custom:catdex-terminal"):
        raise ValueError("TUI pet selection changed; refusing to replace a different selected pet")
    desktop_dir = args.codex_dir / "pets" / "catdex"
    terminal_dir = args.codex_dir / "pets" / "catdex-terminal"
    old_manifest_bytes = (terminal_dir / "pet.json").read_bytes()
    old_manifest = json.loads(old_manifest_bytes)
    if old_manifest.get("id") != "catdex-terminal":
        raise ValueError("Expected the existing Catdex (Terminal) pet")
    terminal_manifest = json.loads((args.staged / "terminal" / "pet.json").read_text())
    if (terminal_manifest.get("id") != "catdex-terminal"
            or terminal_manifest.get("displayName") != "Catdex (Terminal)"):
        raise ValueError("Staged pet must retain the Catdex (Terminal) identity")
    terminal_bytes = (args.staged / "terminal" / "spritesheet.webp").read_bytes()
    terminal_hash = hashlib.sha256(terminal_bytes).hexdigest()
    if terminal_hash != report["terminal_sha256"]:
        raise ValueError("Staged artwork changed after validation")

    after_config = replace_setting(before_config.decode(), "tui", "pet", '"custom:catdex-terminal"')
    old_desktop_pet = before.get("desktop", {}).get("selected-avatar-id")
    new_desktop_pet = old_desktop_pet
    if old_desktop_pet == "custom:catdex-terminal":
        desktop_manifest = json.loads((desktop_dir / "pet.json").read_text())
        desktop_sheet = desktop_dir / desktop_manifest["spritesheetPath"]
        if (desktop_manifest.get("id") != "catdex"
                or hashlib.sha256(desktop_sheet.read_bytes()).hexdigest() != report["desktop_sha256"]):
            raise ValueError("Desktop Catdex must contain the validated proportional artwork")
        new_desktop_pet = "custom:catdex"
        after_config = replace_setting(after_config, "desktop", "selected-avatar-id", '"custom:catdex"')
    after_config = after_config.encode()
    # Parse both texts so timestamps and unrelated TOML values retain their types.
    expected = tomllib.loads(before_config.decode())
    expected["tui"]["pet"] = "custom:catdex-terminal"
    if old_desktop_pet != new_desktop_pet:
        expected["desktop"]["selected-avatar-id"] = new_desktop_pet
    if tomllib.loads(after_config.decode()) != expected:
        raise ValueError("Unrelated settings must remain unchanged")

    # Keep the pet ID and directory, but change the image URL when its bytes change.
    revision_name = "spritesheet-" + terminal_hash[:12] + ".webp"
    terminal_manifest["spritesheetPath"] = revision_name
    manifest_bytes = (json.dumps(terminal_manifest, indent=2) + "\n").encode()
    writes = {revision_name: terminal_bytes, "spritesheet.webp": terminal_bytes,
              "pet.json": manifest_bytes}
    originals = {name: (terminal_dir / name).read_bytes() if (terminal_dir / name).exists() else None
                 for name in writes}
    changes = {"mode": "overwrite-terminal", "terminal": str(terminal_dir),
               "desktop_artwork_changed": False, "desktop_width_changed": False,
               "desktop_pet": [old_desktop_pet, new_desktop_pet],
               "tui_pet": [before["tui"]["pet"], "custom:catdex-terminal"],
               "terminal_sha256": terminal_hash, "spritesheet_path": revision_name}
    if not args.apply:
        print(json.dumps(dict(dry_run=True, **changes), indent=2))
        return
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = args.codex_dir / "pet-backups" / "catdex-terminal" / stamp
    backup.mkdir(parents=True)
    shutil.copy2(config_path, backup / "config.toml")
    shutil.copytree(terminal_dir, backup / "catdex-terminal")
    installed = False
    changed_files = []
    config_written = False
    config_mode = config_path.stat().st_mode & 0o777
    try:
        if (config_path.read_bytes() != before_config
                or (terminal_dir / "pet.json").read_bytes() != old_manifest_bytes):
            raise ValueError("Pet or config changed before installation")
        for name, data in writes.items():
            atomic_write(terminal_dir / name, data)
            changed_files.append(name)
        if config_path.read_bytes() != before_config:
            raise ValueError("Config changed during installation; leaving concurrent edits intact")
        if after_config != before_config:
            atomic_write(config_path, after_config, config_mode)
            config_written = True
        for name, data in writes.items():
            if (terminal_dir / name).read_bytes() != data:
                raise ValueError(f"Installed file verification failed: {name}")
        if tomllib.loads(config_path.read_text()) != expected:
            raise ValueError("Installed config verification failed")
        installed = True
    finally:
        if not installed:
            for name in reversed(changed_files):
                if originals[name] is None:
                    (terminal_dir / name).unlink(missing_ok=True)
                else:
                    atomic_write(terminal_dir / name, originals[name])
            if config_written and config_path.read_bytes() == after_config:
                atomic_write(config_path, before_config, config_mode)
    receipt = dict(applied=True, backup=str(backup), **changes)
    (args.staged / "terminal-installation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    (backup / "installation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
