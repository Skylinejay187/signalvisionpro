#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION="3d9ca508d67594a795475b99fd3ca9e1ae9ae873"
REPOSITORY_URL="https://github.com/superuser404notfound/AetherEngine.git"
CACHE_DIR="${ROOT_DIR}/.build-cache/aetherengine-vBRDC241"
EXTRACT_DIR="${CACHE_DIR}/source"
VENDOR_DIR="${ROOT_DIR}/Vendor/AetherEngine"
PATCH_MARKER="${VENDOR_DIR}/.debridchannels-vBRDC241-aether-6.57.0-xcode16"
EXPECTED_PACKAGE_BLOB="3e4bc21fd7de71e77f38a3e43cbed4cfa3f6b23b"
EXPECTED_VT_BLOB="5eb1105425d71405afd7d228dec9845796fed64f"
EXPECTED_RENDERER_BLOB="2caf9f243e20fc18eb71d312acbd80bbdc84c119"
EXPECTED_SUBTITLES_BLOB="b6d2ce7836f3feff78a50591be2d680fbcbd2497"
EXPECTED_NATIVE_HOST_BLOB="4b293f8f4285d38960fabbbc564078b4fe8e71a5"

if [[ -f "${PATCH_MARKER}" ]] && grep -q "${REVISION}" "${PATCH_MARKER}"; then
  echo "AetherEngine 6.57.0 Xcode16 compatibility vendor already present."
  exit 0
fi

rm -rf "${EXTRACT_DIR}"
mkdir -p "${CACHE_DIR}" "${EXTRACT_DIR}"

echo "============================================================"
echo "DEBRID CHANNELS vBRDC241 FETCHING AETHERENGINE 6.57.0"
echo "revision=${REVISION}"
echo "mode=namespaced FFmpeg coexistence + Xcode16.4 compatibility"
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
  echo "ERROR: Could not fetch pinned AetherEngine revision after retries."
  exit 1
fi

git -C "${EXTRACT_DIR}" checkout -q --detach FETCH_HEAD
SOURCE_DIR="${EXTRACT_DIR}"

PACKAGE_FILE="${SOURCE_DIR}/Package.swift"
VT_FILE="${SOURCE_DIR}/Sources/AetherEngine/Video/VTCapabilityProbe.swift"
RENDERER_FILE="${SOURCE_DIR}/Sources/AetherEngine/Renderer/SampleBufferRenderer.swift"
SUBTITLES_FILE="${SOURCE_DIR}/Sources/AetherEngine/AetherEngine+Subtitles.swift"
NATIVE_HOST_FILE="${SOURCE_DIR}/Sources/AetherEngine/Native/NativeAVPlayerHost.swift"

for FILE in "${PACKAGE_FILE}" "${VT_FILE}" "${RENDERER_FILE}" "${SUBTITLES_FILE}" "${NATIVE_HOST_FILE}"; do
  if [[ ! -f "${FILE}" ]]; then
    echo "ERROR: Pinned AetherEngine source is incomplete: ${FILE}"
    exit 1
  fi
done

if command -v git >/dev/null 2>&1; then
  check_blob() {
    local file="$1" expected="$2" label="$3"
    local actual
    actual="$(git hash-object "$file")"
    if [[ "$actual" != "$expected" ]]; then
      echo "ERROR: ${label} does not match audited AetherEngine 6.57.0 source."
      echo "expected=${expected} actual=${actual}"
      exit 1
    fi
  }
  check_blob "${PACKAGE_FILE}" "${EXPECTED_PACKAGE_BLOB}" "Package.swift"
  check_blob "${VT_FILE}" "${EXPECTED_VT_BLOB}" "VTCapabilityProbe.swift"
  check_blob "${RENDERER_FILE}" "${EXPECTED_RENDERER_BLOB}" "SampleBufferRenderer.swift"
  check_blob "${SUBTITLES_FILE}" "${EXPECTED_SUBTITLES_BLOB}" "AetherEngine+Subtitles.swift"
  check_blob "${NATIVE_HOST_FILE}" "${EXPECTED_NATIVE_HOST_BLOB}" "NativeAVPlayerHost.swift"
fi

python3 - "${SOURCE_DIR}" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]) / "Sources" / "AetherEngine"

# Xcode 16.4's AVFoundation SDK imports several async AVAsset results as non-Sendable.
# Aether 6.57 is Swift-6-clean on newer SDKs; @preconcurrency keeps the exact runtime
# behavior while treating the older SDK's annotations as legacy declarations.
for rel in [Path("AetherEngine+Subtitles.swift"), Path("Native/NativeAVPlayerHost.swift")]:
    p = root / rel
    s = p.read_text()
    if "@preconcurrency import AVFoundation" not in s:
        count = s.count("import AVFoundation\n")
        if count != 1:
            raise SystemExit(f"Expected one AVFoundation import in {rel}, found {count}")
        s = s.replace("import AVFoundation\n", "@preconcurrency import AVFoundation\n", 1)
        p.write_text(s)

# VideoToolbox declares this supplemental decoder registration unavailable on tvOS in
# the Xcode 16.4 SDK. tvOS still has the following VTIsHardwareDecodeSupported probe,
# so skip only the unsupported registration call on tvOS.
p = root / "Video/VTCapabilityProbe.swift"
s = p.read_text()
old = '''        if #available(tvOS 26.2, iOS 26.2, macOS 16.0, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
'''
new = '''        #if !os(tvOS)
        if #available(iOS 26.2, macOS 16.0, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
        #endif
'''
if old not in s:
    raise SystemExit("VT supplemental-decoder compatibility block changed upstream")
s = s.replace(old, new, 1)
p.write_text(s)

# preferredDynamicRange is an SDK-26 API. A #available check is not enough when
# compiling with Xcode 16.4 because the member is absent from that SDK. Compile the
# new API only when the compiler that ships with the SDK can see it; older compilers
# keep Aether's pre-26 fallback behavior.
p = root / "Renderer/SampleBufferRenderer.swift"
s = p.read_text()
old1 = '''        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            layer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                layer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }
'''
new1 = '''        #if compiler(>=6.2)
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            layer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                layer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }
        #else
        #if os(iOS) || os(macOS)
        if #available(iOS 17.0, macOS 14.0, *) {
            layer.wantsExtendedDynamicRangeContent = isHDR
        }
        #endif
        #endif
'''
old2 = '''        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            displayLayer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                displayLayer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }
'''
new2 = '''        #if compiler(>=6.2)
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            displayLayer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                displayLayer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }
        #else
        #if os(iOS) || os(macOS)
        if #available(iOS 17.0, macOS 14.0, *) {
            displayLayer.wantsExtendedDynamicRangeContent = isHDR
        }
        #endif
        #endif
'''
if s.count(old1) != 1 or s.count(old2) != 1:
    raise SystemExit("SampleBufferRenderer SDK-26 compatibility blocks changed upstream")
s = s.replace(old1, new1, 1).replace(old2, new2, 1)
p.write_text(s)
PY

# Production-only manifest: Debrid Channels uses the core engine only. Pin the
# namespaced FFmpeg build exactly so KSPlayer can keep its independent FFmpegKit
# graph with no duplicate target/module names.
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
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", exact: "3.0.0"),
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
    ]
)
PACKAGE

# Contract checks before handing the local package to XcodeGen/SwiftPM.
grep -q 'AetherFFmpegBuild' "${SOURCE_DIR}/Package.swift"
grep -q 'exact: "3.0.0"' "${SOURCE_DIR}/Package.swift"
grep -q '@preconcurrency import AVFoundation' "${SUBTITLES_FILE}"
grep -q '@preconcurrency import AVFoundation' "${NATIVE_HOST_FILE}"
grep -q '#if !os(tvOS)' "${VT_FILE}"
grep -q '#if compiler(>=6.2)' "${RENDERER_FILE}"
if grep -R -q '^import Libav' "${SOURCE_DIR}/Sources/AetherEngine"; then
  echo "ERROR: Unprefixed Libav import found in Aether 6.57 vendor."
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
printf 'revision=%s\nversion=6.57.0\nffmpeg=AetherFFmpegBuild-3.0.0\npatch=vBRDC241-xcode16.4-compat\n' "${REVISION}" > "${PATCH_MARKER}"

echo "Patched AetherEngine 6.57.0 vendor ready at ${VENDOR_DIR}"
