#!/usr/bin/env python3
"""Turn a record README.md (Markdown) into a tracker.ceph.com draft.

tracker.ceph.com is Redmine with Textile formatting, so fenced code blocks,
inline code, links and tables are converted.  Output per record:
  <record>/tracker.textile   - Subject + field summary + Textile description
  <record>/tracker.json      - payload for POST /issues.json (Redmine API)

usage: to-tracker.py <record-dir>...
"""
import json
import re
import sys
from pathlib import Path

PROJECT = "bluestore"
TRACKER_BUG = 1               # "Bug"
CF = {"Severity": 4, "Regression": 13, "Backport": 2, "Tags": 31}
SEVERITY = {"major": "2 - major", "minor": "3 - minor", "critical": "1 - critical"}
REPO_URL = "https://github.com/cephtools/tools/tree/main/trackers/bluestore-2026-09"


def inline(s):
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'"\1":\2', s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"*\1*", s)
    # `code` -> @code@ (Textile); escape nothing else
    s = re.sub(r"`([^`]+)`", r"@\1@", s)
    return s


def join_continuations(md):
    """Join wrapped list-item / paragraph continuation lines (Textile is line based)."""
    res, in_code = [], False
    for line in md.splitlines():
        if line.startswith("```"):
            in_code = not in_code
            res.append(line)
            continue
        if (not in_code and res and line.startswith("  ") and line.strip()
                and not re.match(r"^\s*([-*]|\d+\.) ", line)
                and re.match(r"^\s*([-*]|\d+\.) ", res[-1])):
            res[-1] = res[-1] + " " + line.strip()
            continue
        res.append(line)
    return "\n".join(res)


def md_to_textile(md):
    md = join_continuations(md)
    out, in_code, table_hdr = [], False, False
    for line in md.splitlines():
        if line.startswith("```"):
            out.append("</pre>" if in_code else "<pre>")
            in_code = not in_code
            continue
        if in_code:
            out.append(line.replace("<", "&lt;").replace(">", "&gt;"))
            continue
        m = re.match(r"^(#{1,4}) (.*)", line)
        if m:
            out.append("h%d. %s" % (len(m.group(1)) + 1, inline(m.group(2))))
            out.append("")
            continue
        if re.match(r"^\|[-| ]+\|$", line):      # markdown table separator
            continue
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not table_hdr and all(c == "" for c in cells):
                table_hdr = True
                continue
            out.append("|" + "|".join(inline(c) for c in cells) + "|")
            continue
        table_hdr = False
        m = re.match(r"^(\s*)[-*] (.*)", line)
        if m:
            depth = len(m.group(1)) // 2 + 1
            out.append("*" * depth + " " + inline(m.group(2)))
            continue
        m = re.match(r"^(\s*)\d+\. (.*)", line)
        if m:
            out.append("# " + inline(m.group(2)))
            continue
        out.append(inline(line))
    return "\n".join(out).strip() + "\n"


def field(md, name):
    m = re.search(r"^\| %s \| (.*?) \|$" % re.escape(name), md, re.M)
    return m.group(1).strip() if m else ""


def convert(d):
    d = Path(d)
    md = (d / "README.md").read_text()
    title = md.splitlines()[0].lstrip("# ").strip()
    sev_txt = field(md, "Severity").lower()
    sev = next((v for k, v in SEVERITY.items() if sev_txt.startswith(k)), "3 - minor")
    regression = "1" if re.search(r"regress", field(md, "Kind") + field(md, "Affected"), re.I) else "0"
    # body: drop the H1 (it becomes the Subject), link the reproducer files
    body_md = "\n".join(l for l in md.splitlines()[1:]
                        if not l.startswith("| Component |")).strip()
    body_md = re.sub(r"\]\((?!https?:)([^)]+)\)",
                     lambda m: "](%s/%s/%s)" % (REPO_URL, d.name, m.group(1)), body_md)
    body_md = body_md.replace("`common/patches/bluestore-bughunt-tests.patch`",
                              "[bluestore-bughunt-tests.patch](%s/common/patches/bluestore-bughunt-tests.patch)" % REPO_URL)
    files = sorted(p.name for p in d.iterdir()
                   if p.suffix in (".cc", ".sh") and p.is_file())
    body_md += "\n\n## Reproducer files\n" + "\n".join(
        "- [%s](%s/%s/%s)" % (f, REPO_URL, d.name, f) for f in files)
    body_md += ("\n- Test patch for all gtests: [bluestore-bughunt-tests.patch]"
                "(%s/common/patches/bluestore-bughunt-tests.patch)\n" % REPO_URL)
    textile = md_to_textile(body_md)
    (d / "tracker.textile").write_text(
        "Project: %s | Tracker: Bug | Severity: %s | Regression: %s\n"
        "Subject: %s\n\n%s" % (PROJECT, sev, regression, title, textile))
    payload = {"issue": {
        "project_id": PROJECT, "tracker_id": TRACKER_BUG, "subject": title,
        "description": textile,
        "custom_fields": [{"id": CF["Severity"], "value": sev},
                          {"id": CF["Regression"], "value": regression}],
    }}
    (d / "tracker.json").write_text(json.dumps(payload, indent=1) + "\n")
    return title, sev, regression


if __name__ == "__main__":
    for d in sys.argv[1:]:
        t, s, r = convert(d)
        print("%-45s %-9s reg=%s  %s" % (Path(d).name[:45], s, r, t[:70]))
