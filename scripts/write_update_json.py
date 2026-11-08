#!/usr/bin/env python3
"""Write update.json for KernelSU/APatch/MMRL manager updates."""

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--version-code", required=True, type=int)
    ap.add_argument("--repo", default="ridhzlabs/thermalcore")
    ap.add_argument("--branch", default="main")
    args = ap.parse_args()

    version = args.version.lstrip("vV")
    data = {
        "version": version,
        "versionCode": args.version_code,
        "zipUrl": "https://github.com/%s/releases/download/v%s/ThermalCore-%s.zip"
        % (args.repo, version, version),
        "changelog": "https://raw.githubusercontent.com/%s/%s/CHANGELOG.md"
        % (args.repo, args.branch),
    }
    out = os.path.join(ROOT, "update.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    print("wrote " + out)


if __name__ == "__main__":
    main()
