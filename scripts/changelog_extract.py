#!/usr/bin/env python3
"""Print the CHANGELOG.md section for a given version (release notes body)."""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: changelog_extract.py <version>")
    version = sys.argv[1].lstrip("vV")
    path = os.path.join(ROOT, "CHANGELOG.md")
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    header = re.compile(r"^## \[?v?" + re.escape(version) + r"\]?(?:\s|$)")
    out = []
    inside = False
    for line in lines:
        if header.match(line):
            inside = True
            continue
        if inside and line.startswith("## "):
            break
        if inside:
            out.append(line)

    text = "\n".join(out).strip()
    if text:
        print(text)


if __name__ == "__main__":
    main()
