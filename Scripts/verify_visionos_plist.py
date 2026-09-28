#!/usr/bin/env python3
"""Reject unsigned Vision Pro builds whose actual Info.plist cannot open multiple scenes."""
import plistlib
import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit("usage: verify_visionos_plist.py SOURCE_OR_COMPILED_INFO_PLIST")
path = Path(sys.argv[1])
with path.open("rb") as stream:
    info = plistlib.load(stream)
manifest = info.get("UIApplicationSceneManifest")
if not isinstance(manifest, dict):
    sys.exit(f"FAIL {path}: UIApplicationSceneManifest missing or not a dictionary")
if manifest.get("UIApplicationSupportsMultipleScenes") is not True:
    sys.exit(f"FAIL {path}: UIApplicationSupportsMultipleScenes must be Boolean true, got {manifest.get('UIApplicationSupportsMultipleScenes')!r}")
if not isinstance(manifest.get("UISceneConfigurations"), dict):
    sys.exit(f"FAIL {path}: UISceneConfigurations dictionary missing")
if path.name == "Info.plist" and "$(" in str(info):
    sys.exit(f"FAIL {path}: unexpanded build variables in compiled plist")
print(f"PASS {path}: verified nested UIApplicationSupportsMultipleScenes=true, UISceneConfigurations dictionary present")
print(f"  bundle={info.get('CFBundleIdentifier', '(source/unexpanded)')} version={info.get('CFBundleVersion', '(source/unexpanded)')}")
