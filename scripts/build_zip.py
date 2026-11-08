#!/usr/bin/env python3
"""Build the flashable ThermalCore module zip.

Only stdlib is required. The payload is fixed (no tests, docs or CI files),
executable modes are preserved, and installer checksums are generated from
the packaged bytes so a release can never ship stale hashes.
"""

import argparse
import hashlib
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATE = (2026, 1, 1, 0, 0, 0)

DIRS = [
    "META-INF/",
    "META-INF/com/",
    "META-INF/com/google/",
    "META-INF/com/google/android/",
    "bin/",
    "lib/",
    "profiles/",
    "webroot/",
    "webroot/css/",
    "webroot/js/",
]

FILES = [
    ("module.prop", 0o644),
    ("customize.sh", 0o755),
    ("service.sh", 0o755),
    ("post-fs-data.sh", 0o755),
    ("uninstall.sh", 0o755),
    ("cleanup.sh", 0o755),
    ("thermal-cored", 0o755),
    ("banner.jpg", 0o644),
    ("META-INF/com/google/android/update-binary", 0o755),
    ("META-INF/com/google/android/updater-script", 0o644),
    ("bin/thermalcore", 0o755),
    ("lib/core.sh", 0o644),
    ("lib/detect.sh", 0o644),
    ("lib/backup.sh", 0o644),
    ("lib/profiles.sh", 0o644),
    ("lib/status.sh", 0o644),
    ("profiles/battery_saver.conf", 0o644),
    ("profiles/balanced.conf", 0o644),
    ("profiles/performance.conf", 0o644),
    ("profiles/gaming.conf", 0o644),
    ("profiles/custom_template.conf", 0o644),
    ("webroot/index.html", 0o644),
    ("webroot/css/app.css", 0o644),
    ("webroot/js/app.js", 0o644),
]


def read(name):
    with open(os.path.join(ROOT, name), "rb") as fh:
        return fh.read()


def module_prop(version, version_code):
    text = read("module.prop").decode("utf-8")
    if version:
        text = re.sub(r"(?m)^version=.*$", "version=" + version, text)
    if version_code:
        text = re.sub(r"(?m)^versionCode=.*$", "versionCode=" + str(version_code), text)
    return text.encode("utf-8")


def add(zf, name, data, mode):
    info = zipfile.ZipInfo(name, date_time=DATE)
    info.external_attr = mode << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    zf.writestr(info, data)


def main():
    ap = argparse.ArgumentParser(description="Build the ThermalCore module zip")
    ap.add_argument("--version", help="override module.prop version (release tag)")
    ap.add_argument("--version-code", type=int, help="override module.prop versionCode")
    ap.add_argument("--out", help="output zip path (default: dist/ThermalCore-<version>.zip)")
    args = ap.parse_args()

    if not args.out:
        version = args.version
        if not version:
            match = re.search(r"(?m)^version=(.+)$", read("module.prop").decode())
            version = match.group(1).strip() if match else "dev"
        args.out = os.path.join("dist", "ThermalCore-%s.zip" % version)

    payload = {}
    for name, mode in FILES:
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            sys.exit("missing required file: " + name)
        payload[name] = (read(name), mode)
    payload["module.prop"] = (module_prop(args.version, args.version_code), 0o644)

    checksums = {}
    for name, (data, _mode) in payload.items():
        if name.endswith("/update-binary") or name.endswith("/updater-script"):
            checksums[name + ".sha256"] = (hashlib.sha256(data).hexdigest().encode(), 0o644)

    out_path = os.path.join(ROOT, args.out) if not os.path.isabs(args.out) else args.out
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with zipfile.ZipFile(out_path, "w") as zf:
        for name in DIRS:
            info = zipfile.ZipInfo(name, date_time=DATE)
            info.external_attr = (0o755 << 16) | 0x10
            info.compress_type = zipfile.ZIP_STORED
            zf.writestr(info, b"")
        for name, (data, mode) in list(payload.items()) + list(checksums.items()):
            add(zf, name, data, mode)

    version = args.version or re.search(
        r"(?m)^version=(.+)$", payload["module.prop"][0].decode()
    ).group(1)
    print("built %s (v%s, %d bytes)" % (args.out, version, os.path.getsize(out_path)))


if __name__ == "__main__":
    main()
