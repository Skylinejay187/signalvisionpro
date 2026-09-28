#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION="69a73e5e22184c6db254eb2919f81768afb57a81"
REPOSITORY_URL="https://github.com/tapframe/KSPNUVIO.git"
CACHE_DIR="${ROOT_DIR}/.build-cache/kspnuvio-vBRDC043"
EXTRACT_DIR="${CACHE_DIR}/source"
VENDOR_DIR="${ROOT_DIR}/Vendor/KSPNUVIO"
PATCH_MARKER="${VENDOR_DIR}/.debridchannels-vBRDC049-playback-graphics-stability-patched"
EXPECTED_FFMPEGDECODE_BLOB="77f39b6f47db61c1fa2bb9715348442e5d64d1ba"
EXPECTED_PACKAGE_BLOB="5b7b515e1209e0965dd2a79dde5a189c1550e9b5"
EXPECTED_KSOPTIONS_BLOB="42c9c8f7ffeb8c34548086e1a71c4d4bf092bd05"

if [[ -f "${PATCH_MARKER}" ]] && grep -q "${REVISION}" "${PATCH_MARKER}"; then
  echo "KSPNUVIO decoder + vBRDC049 playback graphics stability patches already present."
  exit 0
fi

rm -rf "${EXTRACT_DIR}"
mkdir -p "${CACHE_DIR}" "${EXTRACT_DIR}"

echo "============================================================"
echo "DEBRID CHANNELS VBRDC049 FETCHING PINNED KSPNUVIO + PLAYBACK GRAPHICS STABILITY PATCHES"
echo "revision=${REVISION}"
echo "mode=sparse-git-checkout (Package.swift + Sources only)"
echo "============================================================"

# GitHub's ZIP contains a documentation filename that macOS unzip cannot create,
# causing exit code 50 before XcodeGen runs. Fetch the exact audited commit with
# sparse checkout so Documents/ is never materialized on disk.
git -C "${EXTRACT_DIR}" init -q
git -C "${EXTRACT_DIR}" remote add origin "${REPOSITORY_URL}"
git -C "${EXTRACT_DIR}" config core.sparseCheckout true
mkdir -p "${EXTRACT_DIR}/.git/info"
cat > "${EXTRACT_DIR}/.git/info/sparse-checkout" <<'SPARSE'
/Package.swift
/Sources/
SPARSE

FETCHED=0
for ATTEMPT in 1 2 3 4 5; do
  if git -C "${EXTRACT_DIR}" fetch --no-tags --depth 1 origin "${REVISION}"; then
    FETCHED=1
    break
  fi
  echo "Pinned KSPNUVIO fetch attempt ${ATTEMPT} failed; retrying..."
  sleep $((ATTEMPT * 3))
done
if [[ "${FETCHED}" != "1" ]]; then
  echo "ERROR: Could not fetch pinned KSPNUVIO revision after retries."
  exit 1
fi

git -C "${EXTRACT_DIR}" checkout -q --detach FETCH_HEAD
SOURCE_DIR="${EXTRACT_DIR}"
if [[ ! -f "${SOURCE_DIR}/Package.swift" || ! -d "${SOURCE_DIR}/Sources" ]]; then
  echo "ERROR: Sparse KSPNUVIO checkout is incomplete."
  exit 1
fi

FFMPEG_FILE="${SOURCE_DIR}/Sources/KSPlayer/MEPlayer/FFmpegDecode.swift"
KSOPTIONS_FILE="${SOURCE_DIR}/Sources/KSPlayer/AVPlayer/KSOptions.swift"
if [[ ! -f "${FFMPEG_FILE}" || ! -f "${KSOPTIONS_FILE}" ]]; then
  echo "ERROR: Pinned KSPNUVIO decoder/options source is missing."
  exit 1
fi

if command -v git >/dev/null 2>&1; then
  ACTUAL_DECODER_BLOB="$(git hash-object "${FFMPEG_FILE}")"
  ACTUAL_KSOPTIONS_BLOB="$(git hash-object "${KSOPTIONS_FILE}")"
  ACTUAL_PACKAGE_BLOB="$(git hash-object "${SOURCE_DIR}/Package.swift")"
  if [[ "${ACTUAL_DECODER_BLOB}" != "${EXPECTED_FFMPEGDECODE_BLOB}" ]]; then
    echo "ERROR: FFmpegDecode.swift does not match audited pinned source."
    echo "expected=${EXPECTED_FFMPEGDECODE_BLOB} actual=${ACTUAL_DECODER_BLOB}"
    exit 1
  fi
  if [[ "${ACTUAL_KSOPTIONS_BLOB}" != "${EXPECTED_KSOPTIONS_BLOB}" ]]; then
    echo "ERROR: KSOptions.swift does not match audited pinned source."
    echo "expected=${EXPECTED_KSOPTIONS_BLOB} actual=${ACTUAL_KSOPTIONS_BLOB}"
    exit 1
  fi
  if [[ "${ACTUAL_PACKAGE_BLOB}" != "${EXPECTED_PACKAGE_BLOB}" ]]; then
    echo "ERROR: Package.swift does not match audited pinned source."
    echo "expected=${EXPECTED_PACKAGE_BLOB} actual=${ACTUAL_PACKAGE_BLOB}"
    exit 1
  fi
fi

python3 - "${FFMPEG_FILE}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
original = text

replacements = [
    (
        'closedCaptionsPacket.corePacket?.pointee.size = Int32(sideData.size)',
        'closedCaptionsPacket.corePacket?.pointee.size = Int32(clamping: sideData.size)'
    ),
    (
'''                            } else if sideData.type == AV_FRAME_DATA_SEI_UNREGISTERED {
                                let size = sideData.size
                                if size > AV_UUID_LEN {
                                    let str = String(cString: sideData.data.advanced(by: Int(AV_UUID_LEN)))
                                    options.sei(string: str)
                                }
''',
'''                            } else if sideData.type == AV_FRAME_DATA_SEI_UNREGISTERED {
                                // The SEI payload is length-delimited and is not guaranteed to end in a
                                // NUL byte. Bound the read to sideData.size instead of String(cString:),
                                // which can walk beyond the payload on malformed or unusual HEVC streams.
                                let size = Int(clamping: sideData.size)
                                let uuidLength = Int(AV_UUID_LEN)
                                if size > uuidLength {
                                    let payload = UnsafeBufferPointer(
                                        start: sideData.data.advanced(by: uuidLength),
                                        count: size - uuidLength
                                    )
                                    let string = String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
                                    if !string.isEmpty {
                                        options.sei(string: string)
                                    }
                                }
'''
    ),
    (
'''                            } else if sideData.type == AV_FRAME_DATA_DOVI_RPU_BUFFER {
                                let data = sideData.data.withMemoryRebound(to: [UInt8].self, capacity: 1) { $0 }
                            } else if sideData.type == AV_FRAME_DATA_DOVI_METADATA { // AVDOVIMetadata
                                let data = sideData.data.withMemoryRebound(to: AVDOVIMetadata.self, capacity: 1) { $0 }
                                let header = av_dovi_get_header(data)
                                let mapping = av_dovi_get_mapping(data)
                                let color = av_dovi_get_color(data)
//                                frame.corePixelBuffer?.transferFunction = kCVImageBufferTransferFunction_ITU_R_2020
                            } else if sideData.type == AV_FRAME_DATA_DYNAMIC_HDR_PLUS { // AVDynamicHDRPlus
                                let data = sideData.data.withMemoryRebound(to: AVDynamicHDRPlus.self, capacity: 1) { $0 }.pointee
                            } else if sideData.type == AV_FRAME_DATA_DYNAMIC_HDR_VIVID { // AVDynamicHDRVivid
                                let data = sideData.data.withMemoryRebound(to: AVDynamicHDRVivid.self, capacity: 1) { $0 }.pointee
''',
'''                            } else if sideData.type == AV_FRAME_DATA_DOVI_RPU_BUFFER {
                                // Metadata is propagated by VideoToolbox/format descriptions elsewhere.
                                // Do not reinterpret an unvalidated side-data buffer when no value is used.
                            } else if sideData.type == AV_FRAME_DATA_DOVI_METADATA {
                                // Intentionally ignored here; the previous code dereferenced the payload
                                // only to discard every result.
                            } else if sideData.type == AV_FRAME_DATA_DYNAMIC_HDR_PLUS {
                                // Intentionally ignored here; avoid unvalidated pointer rebinding.
                            } else if sideData.type == AV_FRAME_DATA_DYNAMIC_HDR_VIVID {
                                // Intentionally ignored here; avoid unvalidated pointer rebinding.
'''
    ),
    (
'''                                    display_primaries_r_x: UInt16(data.display_primaries.0.0.num).bigEndian,
                                    display_primaries_r_y: UInt16(data.display_primaries.0.1.num).bigEndian,
                                    display_primaries_g_x: UInt16(data.display_primaries.1.0.num).bigEndian,
                                    display_primaries_g_y: UInt16(data.display_primaries.1.1.num).bigEndian,
                                    display_primaries_b_x: UInt16(data.display_primaries.2.1.num).bigEndian,
                                    display_primaries_b_y: UInt16(data.display_primaries.2.1.num).bigEndian,
                                    white_point_x: UInt16(data.white_point.0.num).bigEndian,
                                    white_point_y: UInt16(data.white_point.1.num).bigEndian,
                                    minLuminance: UInt32(data.min_luminance.num).bigEndian,
                                    maxLuminance: UInt32(data.max_luminance.num).bigEndian
''',
'''                                    // FFmpeg metadata rationals can legally contain negative or
                                    // oversized numerators. Swift's normal UInt conversions trap on
                                    // those values, which caused the v990 HEVC SIGTRAP. Clamp instead.
                                    display_primaries_r_x: UInt16(clamping: data.display_primaries.0.0.num).bigEndian,
                                    display_primaries_r_y: UInt16(clamping: data.display_primaries.0.1.num).bigEndian,
                                    display_primaries_g_x: UInt16(clamping: data.display_primaries.1.0.num).bigEndian,
                                    display_primaries_g_y: UInt16(clamping: data.display_primaries.1.1.num).bigEndian,
                                    display_primaries_b_x: UInt16(clamping: data.display_primaries.2.0.num).bigEndian,
                                    display_primaries_b_y: UInt16(clamping: data.display_primaries.2.1.num).bigEndian,
                                    white_point_x: UInt16(clamping: data.white_point.0.num).bigEndian,
                                    white_point_y: UInt16(clamping: data.white_point.1.num).bigEndian,
                                    minLuminance: UInt32(clamping: data.min_luminance.num).bigEndian,
                                    maxLuminance: UInt32(clamping: data.max_luminance.num).bigEndian
'''
    ),
    (
'''                                    MaxCLL: UInt16(data.MaxCLL).bigEndian,
                                    MaxFALL: UInt16(data.MaxFALL).bigEndian
''',
'''                                    MaxCLL: UInt16(clamping: data.MaxCLL).bigEndian,
                                    MaxFALL: UInt16(clamping: data.MaxFALL).bigEndian
'''
    ),
    (
'''                                    ambient_illuminance: UInt32(data.ambient_illuminance.num).bigEndian,
                                    ambient_light_x: UInt16(data.ambient_light_x.num).bigEndian,
                                    ambient_light_y: UInt16(data.ambient_light_y.num).bigEndian
''',
'''                                    ambient_illuminance: UInt32(clamping: data.ambient_illuminance.num).bigEndian,
                                    ambient_light_x: UInt16(clamping: data.ambient_light_x.num).bigEndian,
                                    ambient_light_y: UInt16(clamping: data.ambient_light_y.num).bigEndian
'''
    ),
]

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one decoder patch match, found {count}: {old[:80]!r}")
    text = text.replace(old, new, 1)

if text == original:
    raise SystemExit("Decoder patch made no changes")

path.write_text(text)
PY

# vBRDC043 local-only recurring-intro fingerprint patch, with vBRDC049 decoder-thread throttling.
python3 "${ROOT_DIR}/Scripts/patch_kspnuvio_local_intro_vBRDC043.py" "${KSOPTIONS_FILE}" "${FFMPEG_FILE}"

# vBRDC049: backport the Aug 2026 upstream CircularBuffer subtitle-ring leak fix.
CIRCULAR_BUFFER_FILE="${SOURCE_DIR}/Sources/KSPlayer/MEPlayer/CircularBuffer.swift"
if [[ ! -f "${CIRCULAR_BUFFER_FILE}" ]]; then
  echo "ERROR: Pinned KSPNUVIO CircularBuffer source is missing."
  exit 1
fi
python3 "${ROOT_DIR}/Scripts/patch_kspnuvio_playback_stability_vBRDC049.py" "${CIRCULAR_BUFFER_FILE}"

# The sparse checkout intentionally omits Tests and documentation. The upstream
# manifest still declares KSPlayerTests, which makes SwiftPM mis-resolve the
# local package and report the entire Sources directory as one mixed-language
# target. Replace it with a production-only manifest using explicit source
# paths for the two real library targets.
cat > "${SOURCE_DIR}/Package.swift" <<'PACKAGE'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KSPlayer",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v10_15),
        .macCatalyst(.v13),
        .iOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "KSPlayer", targets: ["KSPlayer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kingslay/FFmpegKit.git", from: "6.1.3"),
    ],
    targets: [
        .target(
            name: "DisplayCriteria",
            path: "Sources/DisplayCriteria"
        ),
        .target(
            name: "KSPlayer",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                "DisplayCriteria",
            ],
            path: "Sources/KSPlayer",
            resources: [.process("Metal/Shaders.metal")],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
PACKAGE

# Fail fast if the explicit production target layout is not present.
test -d "${SOURCE_DIR}/Sources/KSPlayer"
test -d "${SOURCE_DIR}/Sources/DisplayCriteria"
grep -q 'path: "Sources/KSPlayer"' "${SOURCE_DIR}/Package.swift"
grep -q 'path: "Sources/DisplayCriteria"' "${SOURCE_DIR}/Package.swift"
if grep -q 'KSPlayerTests' "${SOURCE_DIR}/Package.swift"; then
  echo "ERROR: Production package manifest still contains KSPlayerTests."
  exit 1
fi

rm -rf "${SOURCE_DIR}/.git"
mkdir -p "$(dirname "${VENDOR_DIR}")"
rm -rf "${VENDOR_DIR}"
mv "${SOURCE_DIR}" "${VENDOR_DIR}"
printf 'revision=%s\npatch=vBRDC049-playback-graphics-stability-plus-local-intro-15m-plus-v995-hdr-safety\n' "${REVISION}" > "${PATCH_MARKER}"

echo "Patched local KSPNUVIO vBRDC049 playback-stability vendor ready at ${VENDOR_DIR}"
grep -n "UInt16(clamping\|String(decoding\|Int32(clamping" \
  "${VENDOR_DIR}/Sources/KSPlayer/MEPlayer/FFmpegDecode.swift" | head -40
