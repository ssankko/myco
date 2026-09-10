#!/usr/bin/env python3
"""Fetches AutoEq's parametric presets and writes them as one compact JSON file.

Only the ParametricEQ.txt files and the licence are checked out, through a blobless sparse
clone under /tmp. Each entry is {"n": name, "m": measurer, "f": form, "p": preamp dB,
"e": [[type, fc, gain, q], ...]} with type one of PK, LSC, HSC. Measurers who publish on
squig.link are left out: the app reads those sites live and fits their measurements itself.
"""
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.request

REPO = "https://github.com/jaakkopasanen/AutoEq"
SQUIG_SITES = "https://squig.link/squigsites.json"
ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Sources" / "Myco" / "Resources"
FILTER = re.compile(r"Filter \d+: ON (PK|LSC|HSC) Fc ([\d.]+) Hz Gain (-?[\d.]+) dB Q ([\d.]+)")
PREAMP = re.compile(r"Preamp: (-?[\d.]+) dB")


def key(name):
    """A measurer name as both sides spell it: AutoEq writes Super* Review as Super Review."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def number(text):
    value = float(text)
    return int(value) if value == int(value) else value


def parse(path):
    text = path.read_text(encoding="utf-8")
    preamp = PREAMP.search(text)
    filters = [[t, number(fc), number(gain), number(q)] for t, fc, gain, q in FILTER.findall(text)]
    if preamp is None or not filters:
        return None
    # The form directory may carry the measurement rig in front: "GRAS 43AG-7 over-ear".
    measurer, form = path.relative_to(clone / "results").parts[:2]
    return {
        "n": path.parent.name,
        "m": measurer,
        "f": form.split()[-1],
        "p": number(preamp.group(1)),
        "e": filters,
    }


with urllib.request.urlopen(urllib.request.Request(SQUIG_SITES, headers={"User-Agent": "Myco"}), timeout=30) as response:
    squig = {key(site["name"]) for site in json.load(response)}

with tempfile.TemporaryDirectory(prefix="autoeq-") as tmp:
    clone = pathlib.Path(tmp) / "AutoEq"
    subprocess.run(
        ["git", "clone", "--quiet", "--depth", "1", "--filter=blob:none", "--no-checkout", REPO, clone],
        check=True)
    subprocess.run(
        ["git", "-C", clone, "sparse-checkout", "set", "--no-cone", "/results/**/*ParametricEQ.txt", "/LICENSE"],
        check=True)
    subprocess.run(["git", "-C", clone, "checkout", "--quiet"], check=True)

    entries = [parse(p) for p in sorted((clone / "results").rglob("*ParametricEQ.txt"))]
    entries = [e for e in entries if e is not None and key(e["m"]) not in squig]
    RESOURCES.mkdir(parents=True, exist_ok=True)
    out = RESOURCES / "autoeq.json"
    out.write_text(json.dumps(entries, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    (RESOURCES / "AutoEq-LICENSE.txt").write_text((clone / "LICENSE").read_text(encoding="utf-8"))

print(f"{len(entries)} presets, {out.stat().st_size} bytes, {out.relative_to(ROOT)}", file=sys.stderr)
