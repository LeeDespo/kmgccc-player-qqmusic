#!/usr/bin/env python3
"""Inventory every tracked file and fail only on obsolete live references or broken live Markdown links."""
from __future__ import annotations

import collections
import hashlib
import pathlib
import re
import subprocess
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
paths = [
    p.decode("utf-8", "surrogateescape")
    for p in subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z"]).split(b"\0")
    if p
]
obsolete = re.compile(
    r"Tools/QQMusicHelper(?:/|\b)|QQMusicHelperProcess\.swift|"
    r"QQMusicWebAPI|qqmusic-api-python|docs/qqmusic(?:/|\b)|"
    r"integration/GUIDE\.md|scripts/components/qqmusic-helper\.sh"
)
todo = re.compile(r"\b(?:TODO|FIXME|HACK|WIP)\b", re.IGNORECASE)
links = re.compile(r"!?\[[^\]\n]*\]\(([^)\n]+)\)|^\[[^\]\n]+\]:\s*(\S+)", re.MULTILINE)
exempt = {
    ".gitignore",
    "qqmusic/check-repository-rules.sh",
    "qqmusic/audit-residue.py",
    "qqmusic/integration/removals.txt",
    "qqmusic/integration/sync.sh",
}
def historical(p: str) -> bool:
    return (
        p in exempt
        or p in {"CHANGELOG.md", "qqmusic/CHANGELOG.md"}
        or p.startswith(("qqmusic/integration/modules/", "qqmusic/integration/patches/", "qqmusic/release-notes/"))
    )

file_count = 0
binary_count = 0
obsolete_live = []
obsolete_history = []
missing_active = []
missing_history = []
todo_hits = []
doc_digests = collections.defaultdict(list)
for rel in paths:
    path = ROOT / rel
    if not path.is_file() or path.is_symlink():
        continue
    file_count += 1
    contents = path.read_bytes()
    if b"\0" in contents:
        binary_count += 1
        continue
    try:
        text = contents.decode("utf-8")
    except UnicodeDecodeError:
        binary_count += 1
        continue

    history = historical(rel)
    if rel.endswith(".md") and not history:
        doc_digests[hashlib.sha256(contents).hexdigest()].append(rel)
    for line_no, line in enumerate(text.splitlines(), 1):
        if obsolete.search(line):
            item = (rel, line_no, line.strip()[:160])
            (obsolete_history if history else obsolete_live).append(item)
        if not history and todo.search(line):
            todo_hits.append((rel, line_no, line.strip()[:120]))

    if not rel.endswith(".md"):
        continue
    for match in links.finditer(text):
        target = (match.group(1) or match.group(2) or "").strip()
        target = target.split(" ", 1)[0].strip("<>")
        if not target or target.startswith(("#", "//", "$", "{")):
            continue
        parsed = urllib.parse.urlsplit(target)
        if parsed.scheme or parsed.netloc:
            continue
        candidate = urllib.parse.unquote(parsed.path)
        if not candidate or any(c in candidate for c in "<>*{}"):
            continue
        if candidate.startswith("/"):
            linked = ROOT / candidate.lstrip("/")
        else:
            linked = path.parent / candidate
        if not linked.exists():
            entry = (rel, text[:match.start()].count("\n") + 1, target)
            (missing_history if history else missing_active).append(entry)

def examples(label: str, items: list, max_lines: int = 18) -> None:
    print(f"{label}: {len(items)}")
    for item in items[:max_lines]:
        print("  " + ":".join(map(str, item)))
    if len(items) > max_lines:
        print(f"  ... {len(items) - max_lines} more")

print(f"Tracked file inventory: {len(paths)} entries; {file_count} files; {binary_count} binary/undecodable")
examples("Obsolete references in live files", obsolete_live)
examples("Obsolete references in historical/generated/guard files (permitted)", obsolete_history, 8)
examples("Missing local Markdown targets in live files", missing_active)
examples("Missing local Markdown targets in history/generated files (informational)", missing_history, 8)
examples("TODO/FIXME/HACK/WIP in live files (informational)", todo_hits, 12)
duplicates = [entries for entries in doc_digests.values() if len(entries) > 1]
print(f"Exact duplicate live Markdown documents: {len(duplicates)} group(s)")
for group in duplicates:
    print("  " + ", ".join(group))
if obsolete_live or missing_active:
    print("FAIL: live reference hygiene needs repair", file=sys.stderr)
    sys.exit(1)
print("PASS: no obsolete live references, broken live Markdown targets, or exact duplicate live docs")
