#!/bin/bash
set -euo pipefail
# Also covers older GitHub workflow files: environment survives subsequent steps.
# Xcode reads XCODE_XCCONFIG_FILE for app AND Swift package targets.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'XCODE_XCCONFIG_FILE=%s\n' "$(pwd)/Scripts/visionos_arm64_all_targets.xcconfig" >> "$GITHUB_ENV"
fi
bash Scripts/fetch_patch_kspnuvio_vBRDC064.sh
python3 Scripts/patch_kspnuvio_visionos_display_scale.py
bash Scripts/fetch_patch_aether_vBRDC242.sh
python3 - <<'PYTHON'
from pathlib import Path
p=Path('Vendor/AetherPlaybackKit/Package.swift')
s=p.read_text()
if '.visionOS(' not in s:
    s=s.replace('        .tvOS(.v17),','        .tvOS(.v17),\n        .visionOS(.v2),')
    p.write_text(s)
assert '.visionOS(' in p.read_text()
PYTHON
