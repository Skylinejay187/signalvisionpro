#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
echo "============================================================"
echo "SIGNAL vBRDC280 FAST PREFLIGHT + PARALLEL DEPENDENCY PREP"
echo "============================================================"
# Fail fast on local source/asset mistakes before spending minutes downloading/building dependencies.
mkdir -p .build-cache/actool-preflight
echo "Fast preflight: Swift syntax..."
xcrun swiftc -parse Sources/PlaybackKit/PlaybackKitAetherSurface.swift Sources/AetherPlaybackBridge/AetherPlaybackBridge.swift Sources/DebridChannelsTVOSApp.swift TopShelfExtension/ContentProvider.swift
echo "Fast preflight: tvOS asset catalog/AppIcon..."
rm -rf .build-cache/actool-preflight/*
xcrun actool Resources/Assets.xcassets \
  --compile .build-cache/actool-preflight \
  --platform appletvos \
  --minimum-deployment-target 17.0 \
  --target-device tv \
  --app-icon AppIcon \
  --output-partial-info-plist .build-cache/actool-preflight/asset-info.plist >/dev/null
echo "Fast preflight passed. Starting KSPNUVIO + AetherEngine concurrently."
PIDS=()
NAMES=()
run_bg() {
  local name="$1"; shift
  ( "$@" ) > ".build-cache/${name}.log" 2>&1 &
  PIDS+=("$!"); NAMES+=("$name")
}
mkdir -p .build-cache
run_bg kspnuvio bash Scripts/fetch_patch_kspnuvio_vBRDC064.sh
run_bg aether bash Scripts/fetch_patch_aether_vBRDC242.sh
FAILED=0
for i in "${!PIDS[@]}"; do
  pid="${PIDS[$i]}"; name="${NAMES[$i]}"
  if wait "$pid"; then
    echo "[$name] ready"
  else
    echo "[$name] FAILED" >&2
    FAILED=1
  fi
  cat ".build-cache/${name}.log" || true
done
if [ "$FAILED" -ne 0 ]; then
  echo "ERROR: one or more dependency preparation tasks failed." >&2
  exit 1
fi
echo "All build dependencies prepared in parallel."
