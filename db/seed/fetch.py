#!/usr/bin/env python3
"""Refresh link-issues.json: a snapshot of recent issues from Dyalog/link,
used as demo data. Needs the GitHub CLI (gh). Loading the snapshot does not."""
import json, re, subprocess, sys, unicodedata
from datetime import date

REPO, OPEN, CLOSED = "Dyalog/link", 25, 15
BODY_MAX, COMMENT_MAX, COMMENTS = 2500, 1200, 3

def gh(path):
    return json.loads(subprocess.run(["gh", "api", "--paginate", "--slurp", path],
                                     check=True, capture_output=True, text=True).stdout)

def clean(text, limit):
    # Plain text only: characters outside the BMP (styled letters, symbols)
    # are folded to their plain form where one exists, else dropped.
    # Everything else, APL glyphs included, is left exactly as it is.
    def plain(c):
        if ord(c) <= 0xFFFF:
            return c
        folded = unicodedata.normalize("NFKC", c)
        return folded if all(ord(f) <= 0xFFFF for f in folded) else ""
    text = "".join(plain(c) for c in (text or "").replace("\r\n", "\n")).strip()
    return text if len(text) <= limit else text[:limit].rstrip() + " …"

pages = gh(f"repos/{REPO}/issues?state=all&per_page=100&sort=created&direction=desc")
issues = [i for page in pages for i in page if "pull_request" not in i]
chosen = [i for i in issues if i["state"] == "open"][:OPEN] + [i for i in issues if i["state"] == "closed"][:CLOSED]
chosen.sort(key=lambda i: i["created_at"])          # load oldest first

out = []
for i in chosen:
    comments = [clean(c["body"], COMMENT_MAX) for page in gh(f"repos/{REPO}/issues/{i['number']}/comments?per_page=100") for c in page]
    out.append({
        "source": i["html_url"],
        "title": clean(i["title"], 256),
        "body": (clean(i["body"], BODY_MAX) + f"\n\n(From {REPO}#{i['number']})").strip(),
        "state": i["state"],
        "state_reason": i.get("state_reason") if i["state"] == "closed" else None,
        "labels": [clean(l["name"], 50) for l in i["labels"]],
        "comments": [c for c in comments if c][:COMMENTS],
    })

used = {n for i in out for n in i["labels"]}  # names after clean()
labels = [{"name": clean(l["name"], 50), "color": l["color"], "description": clean(l.get("description"), 100)}
          for page in gh(f"repos/{REPO}/labels?per_page=100") for l in page if clean(l["name"], 50) in used]

json.dump({"source": f"https://github.com/{REPO}", "fetched": date.today().isoformat(),
           "labels": labels, "issues": out}, sys.stdout, ensure_ascii=False, indent=1)
