#!/usr/bin/env python3
"""wowapi — query the WoW: Forever API surface from local Blizzard sources.

Sources (populated by scripts/sync-reference.sh):
  reference/upstream/wow-ui-source            (Gethe mirror, branch `forever`)
    Interface/AddOns/Blizzard_APIDocumentationGenerated/*.lua  -> typed docs + secrecy flags
  reference/upstream/BlizzardInterfaceResources (Ketho, branch `forever`)
    Resources/GlobalAPI.lua                   -> every global function that exists in the client
    Resources/Events.lua                      -> every event, grouped by system

Usage:
  uv run tools/wowapi.py fn UnitHealth            # signature + secrecy flags (exact or Namespace.Name)
  uv run tools/wowapi.py fn 'C_Spell.GetSpell*'   # glob
  uv run tools/wowapi.py event UNIT_AURA          # event payload + flags
  uv run tools/wowapi.py search cooldown          # substring over fn/event/table names
  uv run tools/wowapi.py ns C_DamageMeter         # whole system/namespace
  uv run tools/wowapi.py exists SomeGlobalFunc    # is it in GlobalAPI.lua (incl. undocumented)?
  uv run tools/wowapi.py flags                    # histogram of secrecy/restriction flags
  uv run tools/wowapi.py flagged SecretWhenUnitAuraRestricted   # list APIs carrying a flag
  uv run tools/wowapi.py overrides               # Forever-specific FrameXML override files
  uv run tools/wowapi.py build-index              # write reference/generated/api-index.json
Add --json to any query for machine-readable output.
"""
from __future__ import annotations

import fnmatch
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI_SRC = ROOT / "reference/upstream/wow-ui-source"
DOC_DIR = UI_SRC / "Interface/AddOns/Blizzard_APIDocumentationGenerated"
BIR = ROOT / "reference/upstream/BlizzardInterfaceResources/Resources"
INDEX_OUT = ROOT / "reference/generated/api-index.json"

# Keys on a doc entry that are about secrecy / restriction (Midnight-era "addon disarmament").
SECRECY_PREFIXES = ("Secret", "ConstSecret", "ReturnsNeverSecret", "HasRestrictions",
                    "RequiresNonSecret", "RequiresValidAndPublicCVar")
STRUCTURAL = {"Name", "Type", "Arguments", "Returns", "Payload", "LiteralName",
              "Fields", "Documentation", "Namespace", "Environment"}

# ---------------------------------------------------------------- Lua literal parser
_TOKEN = re.compile(r"""
    (?P<ws>\s+|--\[\[.*?\]\]|--[^\n]*)
  | (?P<str>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')
  | (?P<num>-?0x[0-9a-fA-F]+|-?\d+\.?\d*(?:[eE][-+]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z0-9_.:]*)
  | (?P<op>[-+*/])
  | (?P<sym>[{}=,;\[\]()])
""", re.S | re.X)


def _tokens(src: str):
    pos = 0
    while pos < len(src):
        m = _TOKEN.match(src, pos)
        if not m:
            raise SyntaxError(f"bad char {src[pos]!r} at {pos}")
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        yield kind, m.group()


def _sym(v):
    if isinstance(v, dict):
        return v.get("$ref") or v.get("$expr") or str(v)
    return str(v)


class _P:
    def __init__(self, src: str):
        self.t = list(_tokens(src))
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.t[j] if j < len(self.t) else (None, None)

    def next(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def value(self):
        v = self.atom()
        while self.peek()[0] == "op":  # constant expressions, e.g. A.MAX + A.EXTRA -> symbolic
            _, op = self.next()
            rhs = self.atom()
            v = {"$expr": f"{_sym(v)} {op} {_sym(rhs)}"}
        return v

    def atom(self):
        kind, v = self.next()
        if v == "{":
            return self.table()
        if kind == "str":
            return bytes(v[1:-1], "utf-8").decode("unicode_escape", errors="replace")
        if kind == "num":
            return int(v, 0) if re.fullmatch(r"-?(0x[0-9a-fA-F]+|\d+)", v) else float(v)
        if v in ("true", "false"):
            return v == "true"
        if v == "nil":
            return None
        if kind == "name":  # identifier reference, e.g. Enum.Foo.Bar
            return {"$ref": v}
        raise SyntaxError(f"unexpected {v!r}")

    def table(self):
        arr, obj = [], {}
        while True:
            kind, v = self.peek()
            if v == "}":
                self.next()
                break
            if kind == "name" and self.peek(1)[1] == "=":
                self.next(); self.next()
                obj[v] = self.value()
            elif v == "[":
                self.next(); key = self.value(); self.next(); self.next()  # [k] =
                obj[str(key)] = self.value()
            else:
                arr.append(self.value())
            if self.peek()[1] in (",", ";"):
                self.next()
        if obj and arr:
            obj["$array"] = arr
            return obj
        return obj if obj else arr


def parse_lua_table_file(path: Path):
    src = path.read_text(encoding="utf-8", errors="replace")
    start = src.index("{")
    p = _P(src[start:])
    p.next()
    return p.table()


# ---------------------------------------------------------------- index
def build_index() -> dict:
    if not DOC_DIR.exists():
        sys.exit(f"missing {DOC_DIR} — run scripts/sync-reference.sh")
    systems, functions, events, tables = [], [], [], []
    for f in sorted(DOC_DIR.glob("*.lua")):
        if f.name.startswith("Blizzard_"):
            continue
        try:
            doc = parse_lua_table_file(f)
        except Exception as e:  # keep going; report
            print(f"warn: {f.name}: {e}", file=sys.stderr)
            continue
        if not isinstance(doc, dict):
            continue
        ns = doc.get("Namespace")
        sysname = doc.get("Name")
        systems.append({"system": sysname, "namespace": ns, "file": f.name,
                        "environment": doc.get("Environment")})
        for fn in doc.get("Functions", []) or []:
            full = f"{ns}.{fn['Name']}" if ns else fn["Name"]
            functions.append(_entry(fn, full, sysname, f.name))
        for ev in doc.get("Events", []) or []:
            e = _entry(ev, ev.get("LiteralName", ev["Name"]), sysname, f.name)
            events.append(e)
        for t in doc.get("Tables", []) or []:
            tables.append({"name": t.get("Name"), "kind": t.get("Type"), "system": sysname,
                           "file": f.name, "fields": t.get("Fields"), "values": t.get("Values")})
    return {
        "build": (UI_SRC / "version.txt").read_text().strip() if (UI_SRC / "version.txt").exists() else None,
        "systems": systems, "functions": functions, "events": events, "tables": tables,
    }


def _entry(d: dict, full: str, system: str, file: str) -> dict:
    flags = {k: v for k, v in d.items() if k not in STRUCTURAL and k not in ("Payload", "Arguments", "Returns")}
    return {
        "name": full, "system": system, "file": file, "flags": flags, "doc": d.get("Documentation"),
        "args": d.get("Arguments", []), "returns": d.get("Returns", []), "payload": d.get("Payload", []),
    }


_cache = None


def idx():
    global _cache
    if _cache is None:
        if INDEX_OUT.exists() and INDEX_OUT.stat().st_mtime > max(
                (p.stat().st_mtime for p in DOC_DIR.glob("*.lua")), default=0):
            _cache = json.loads(INDEX_OUT.read_text())
        else:
            _cache = build_index()
    return _cache


# ---------------------------------------------------------------- rendering
def _fmt_param(p):
    s = f"{p.get('Name')}: {p.get('Type')}"
    if p.get("Nilable"):
        s += "?"
    if "Default" in p:
        s += f" = {p['Default']}"
    if p.get("InnerType"):
        s += f"<{p['InnerType']}>"
    return s


def render(e: dict) -> str:
    out = []
    if e["payload"] or e["name"].isupper():
        out.append(f"EVENT {e['name']}   [{e['system']} · {e['file']}]")
        for p in e["payload"]:
            out.append(f"    {_fmt_param(p)}")
    else:
        args = ", ".join(_fmt_param(a) for a in e["args"])
        out.append(f"{e['name']}({args})   [{e['system']} · {e['file']}]")
        for r in e["returns"]:
            out.append(f"    -> {_fmt_param(r)}")
    for line in e.get("doc") or []:
        out.append(f"    # {line}")
    sec = {k: v for k, v in e["flags"].items() if k.startswith(SECRECY_PREFIXES)}
    other = {k: v for k, v in e["flags"].items() if k not in sec}
    if sec:
        out.append("    SECRECY: " + ", ".join(f"{k}={v}" for k, v in sec.items()))
    if other:
        out.append("    flags: " + ", ".join(f"{k}={v}" for k, v in other.items()))
    return "\n".join(out)


def _match(name: str, pat: str) -> bool:
    if any(c in pat for c in "*?["):
        return fnmatch.fnmatchcase(name, pat) or fnmatch.fnmatchcase(name.split(".")[-1], pat)
    return name == pat or name.split(".")[-1] == pat


def global_api() -> set[str]:
    p = BIR / "GlobalAPI.lua"
    return set(parse_lua_table_file(p)) if p.exists() else set()


def main(argv):
    as_json = "--json" in argv
    argv = [a for a in argv if a != "--json"]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__); return 0
    cmd, *rest = argv
    q = rest[0] if rest else ""
    I = idx()
    res = []
    if cmd == "build-index":
        INDEX_OUT.parent.mkdir(parents=True, exist_ok=True)
        data = build_index()
        INDEX_OUT.write_text(json.dumps(data, indent=1))
        print(f"wrote {INDEX_OUT.relative_to(ROOT)}: {len(data['functions'])} functions, "
              f"{len(data['events'])} events, {len(data['tables'])} tables, build {data['build']}")
        return 0
    if cmd == "fn":
        res = [e for e in I["functions"] if _match(e["name"], q)]
    elif cmd == "event":
        res = [e for e in I["events"] if _match(e["name"], q)]
    elif cmd == "search":
        ql = q.lower()
        res = [e for e in I["functions"] + I["events"] if ql in e["name"].lower()]
        tabs = [t for t in I["tables"] if ql in (t["name"] or "").lower()]
        if not as_json:
            for t in tabs:
                print(f"TABLE {t['name']} ({t['kind']})  [{t['system']} · {t['file']}]")
    elif cmd == "ns":
        res = [e for e in I["functions"] + I["events"]
               if e["system"] == q or e["name"].startswith(q + ".")]
    elif cmd == "table":
        tabs = [t for t in I["tables"] if _match(t["name"] or "", q)]
        print(json.dumps(tabs, indent=1)); return 0
    elif cmd == "exists":
        g = global_api()
        documented = [e["name"] for e in I["functions"] if _match(e["name"], q)]
        print(json.dumps({"query": q, "in_GlobalAPI": q in g, "documented_as": documented}, indent=1))
        return 0
    elif cmd == "flags":
        from collections import Counter
        c = Counter()
        for e in I["functions"] + I["events"]:
            for k, v in e["flags"].items():
                c[f"{k}={v}" if isinstance(v, str) else k] += 1
        for k, n in c.most_common():
            print(f"{n:6d}  {k}")
        return 0
    elif cmd == "overrides":  # Forever (Camelot) override files in FrameXML, with first comment line
        base = UI_SRC / "Interface/AddOns"
        for d in sorted(base.glob("*/**/Camelot")) + sorted(base.glob("**/*_Camelot.lua")):
            files = [d] if d.is_file() else sorted(p for p in d.rglob("*") if p.is_file())
            print(f"## {d.relative_to(base)}")
            for p in files:
                note = ""
                if p.suffix == ".lua":
                    for line in p.read_text(errors="replace").splitlines()[:15]:
                        if line.strip().startswith("--") and len(line.strip()) > 4:
                            note = "  # " + line.strip().lstrip("-").strip()[:110]; break
                print(f"- {p.name}{note}")
        return 0
    elif cmd == "flagged":
        res = [e for e in I["functions"] + I["events"] if q in e["flags"]]
    else:
        print(__doc__); return 2
    if as_json:
        print(json.dumps(res, indent=1))
    else:
        for e in res:
            print(render(e)); print()
        print(f"({len(res)} result{'s' if len(res) != 1 else ''}; build {I.get('build')})", file=sys.stderr)
    return 0 if res else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
