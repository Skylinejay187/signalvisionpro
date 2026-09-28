#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION="c7e7adb5476f8d86fa484e249f6443d01d6999f8"
VERSION="6.81.0"
REPOSITORY_URL="https://github.com/superuser404notfound/AetherEngine.git"
CACHE_DIR="${ROOT_DIR}/.build-cache/aetherengine-vBRDC259"
EXTRACT_DIR="${CACHE_DIR}/source"
VENDOR_DIR="${ROOT_DIR}/Vendor/AetherEngine"
PATCH_MARKER="${VENDOR_DIR}/.debridchannels-vBRDC259-aether-6.81.0"

if [[ -f "${PATCH_MARKER}" ]] && grep -q "${REVISION}" "${PATCH_MARKER}"; then
  echo "AetherEngine ${VERSION} Debrid Channels vendor already present."
  exit 0
fi

rm -rf "${EXTRACT_DIR}"
mkdir -p "${CACHE_DIR}" "${EXTRACT_DIR}"

echo "============================================================"
echo "DEBRID CHANNELS vBRDC259 FETCHING AETHERENGINE ${VERSION}"
echo "revision=${REVISION}"
echo "mode=namespaced FFmpeg + native live/IPTV host contracts"
echo "============================================================"

git -C "${EXTRACT_DIR}" init -q
git -C "${EXTRACT_DIR}" remote add origin "${REPOSITORY_URL}"
git -C "${EXTRACT_DIR}" config core.sparseCheckout true
mkdir -p "${EXTRACT_DIR}/.git/info"
cat > "${EXTRACT_DIR}/.git/info/sparse-checkout" <<'SPARSE'
/Package.swift
/Sources/AetherEngine/
SPARSE

FETCHED=0
for ATTEMPT in 1 2 3 4 5; do
  if git -C "${EXTRACT_DIR}" fetch --no-tags --depth 1 origin "${REVISION}"; then
    FETCHED=1
    break
  fi
  echo "Pinned AetherEngine fetch attempt ${ATTEMPT} failed; retrying..."
  sleep $((ATTEMPT * 3))
done
if [[ "${FETCHED}" != "1" ]]; then
  echo "ERROR: Could not fetch pinned AetherEngine ${VERSION} revision after retries."
  exit 1
fi

git -C "${EXTRACT_DIR}" checkout -q --detach FETCH_HEAD
SOURCE_DIR="${EXTRACT_DIR}"

# Debrid Channels intentionally vendors only the core engine. Keep Aether's namespaced
# FFmpeg graph deterministic and separate from KSPNUVIO/FFmpegKit.
cat > "${SOURCE_DIR}/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v16),
        .tvOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AetherEngine", targets: ["AetherEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", exact: "3.2.1"),
        .package(url: "https://github.com/superuser404notfound/LibDovi", exact: "2.1.0"),
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
            ],
            path: "Sources/AetherEngine",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ],
    // Xcode 16.4 CI compatibility: avoid Swift 6 strict-Sendable diagnostics
    // becoming hard errors inside AVFoundation async imports.
    swiftLanguageModes: [.v5]
)
PACKAGE

# Aether 6.81 also contains APIs introduced by the tvOS 26/Xcode 26 SDK. Debrid
# Channels currently compiles on GitHub Actions with Xcode 16.4, so compile out only
# those SDK-new diagnostics/render hints while preserving the 6.81 live/IPTV core.
python3 "${ROOT_DIR}/Scripts/patch_aether_681_xcode164.py" "${SOURCE_DIR}"

# Contracts: Aether 6.81 is required because the live IPTV fixes and host contracts
# used by vBRDC259 do not exist in the old 6.57 integration.
grep -q 'AetherFFmpegBuild' "${SOURCE_DIR}/Package.swift"
grep -q 'exact: "3.2.1"' "${SOURCE_DIR}/Package.swift"
grep -R -q 'liveSourceReset' "${SOURCE_DIR}/Sources/AetherEngine"
grep -R -q 'nativeRemoteHLS' "${SOURCE_DIR}/Sources/AetherEngine"
grep -R -q 'liveJoinProfile' "${SOURCE_DIR}/Sources/AetherEngine"
grep -R -q 'hasFirstFrameReadyForDisplay' "${SOURCE_DIR}/Sources/AetherEngine"
grep -R -q 'liveJoinStartsImmediately' "${SOURCE_DIR}/Sources/AetherEngine"
grep -R -q 'preferredDecodePath' "${SOURCE_DIR}/Sources/AetherEngine"
grep -R -q 'public final class HLSLiveIngestReader' "${SOURCE_DIR}/Sources/AetherEngine"
if grep -R -q '^import Libav' "${SOURCE_DIR}/Sources/AetherEngine"; then
  echo "ERROR: Unprefixed Libav import found in Aether ${VERSION} vendor."
  grep -R -n '^import Libav' "${SOURCE_DIR}/Sources/AetherEngine" || true
  exit 1
fi
if ! grep -R -q '^import AetherLibav' "${SOURCE_DIR}/Sources/AetherEngine"; then
  echo "ERROR: Namespaced Aether FFmpeg imports are missing."
  exit 1
fi

rm -rf "${SOURCE_DIR}/.git"
mkdir -p "$(dirname "${VENDOR_DIR}")"
rm -rf "${VENDOR_DIR}"
mv "${SOURCE_DIR}" "${VENDOR_DIR}"
printf 'revision=%s\nversion=%s\nffmpeg=AetherFFmpegBuild-3.2.1\npatch=vBRDC259-live-recovery-ladder\n' "${REVISION}" "${VERSION}" > "${PATCH_MARKER}"

echo "Pinned AetherEngine ${VERSION} vendor ready at ${VENDOR_DIR}"
