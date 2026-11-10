#!/usr/bin/env python3
"""Validate addon TOC files (stdlib only). Run from anywhere:
    uv run --no-project python tools/check_toc.py

Checks per addons/*/*_Forever.toc and templates/addon/*_Forever.toc:
  a) TOC base name == directory name (not for the template)
  b) ## Interface: 16001
  c) ## Version: literal X.Y.Z
  d) ## Author: oannes23
  e) every listed file exists, or is gitignored (generated data)
  f) every git-tracked .lua/.xml in the addon dir is listed, or is Bindings.xml
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INTERFACE = "16001"
AUTHOR = "oannes23"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
IMPLICIT = {"bindings.xml"}


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)


def ignored(rel):
    return git("check-ignore", "-q", rel).returncode == 0


def tracked(rel_dir):
    out = git("ls-files", "-z", "--", rel_dir).stdout
    return [p for p in out.split("\0") if p]


def parse(toc):
    meta, files = {}, []
    for raw in toc.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line:
            continue
        m = re.match(r"^##\s*([^:]+?)\s*:\s*(.*?)\s*$", line)
        if m:
            meta[m.group(1)] = m.group(2)
        elif not line.startswith("#"):
            files.append(line.split()[0].replace("\\", "/"))  # drop [Directive ...] suffixes
    return meta, files


def check(toc, is_template):
    errs = []
    d = toc.parent
    rel_d = d.relative_to(ROOT).as_posix()
    meta, files = parse(toc)

    if not is_template and toc.name != f"{d.name}_Forever.toc":
        errs.append(f"name: TOC is '{toc.name}', expected '{d.name}_Forever.toc'")
    if meta.get("Interface") != INTERFACE:
        errs.append(f"Interface: {meta.get('Interface')!r}, expected {INTERFACE}")
    ver = meta.get("Version", "")
    if not SEMVER.match(ver):
        errs.append(f"Version: {ver!r} is not literal semver X.Y.Z")
    if meta.get("Author") != AUTHOR:
        errs.append(f"Author: {meta.get('Author')!r}, expected {AUTHOR!r}")

    for f in files:
        rel = f"{rel_d}/{f}"
        if not (ROOT / rel).is_file() and not ignored(rel):
            errs.append(f"listed file missing (and not gitignored): {f}")

    listed = {f.lower() for f in files}
    for p in tracked(rel_d):
        sub = p[len(rel_d) + 1:]
        if sub.lower().endswith((".lua", ".xml")) and sub.lower() not in listed \
                and sub.lower() not in IMPLICIT:
            errs.append(f"tracked file not listed in TOC: {sub}")
    return errs


def main():
    tocs = [(t, False) for t in sorted((ROOT / "addons").glob("*/*_Forever.toc"))]
    tocs += [(t, True) for t in sorted((ROOT / "templates/addon").glob("*_Forever.toc"))]
    if not tocs:
        print("no TOC files found", file=sys.stderr)
        return 1
    bad = 0
    for toc, tpl in tocs:
        errs = check(toc, tpl)
        rel = toc.relative_to(ROOT)
        if errs:
            bad += 1
            for e in errs:
                print(f"FAIL {rel}: {e}")
        else:
            print(f"ok   {rel}")
    print(f"{len(tocs) - bad}/{len(tocs)} TOCs ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
