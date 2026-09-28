from pathlib import Path
import sys
root = Path(sys.argv[1]) / "Sources" / "AetherEngine"

# tvOS 26-only UITraitCollection HDR diagnostic.
p = root / "Display" / "DisplayCriteriaController.swift"
s = p.read_text()
old = '''    private static func headroomLimitLabel(_ traits: UITraitCollection) -> String {
        guard #available(tvOS 26.0, *) else { return "n/a" }
        switch traits.hdrHeadroomUsageLimit {
        case .active: return "active"
        case .inactive: return "inactive"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }'''
new = '''    private static func headroomLimitLabel(_ traits: UITraitCollection) -> String {
        #if compiler(>=6.2)
        guard #available(tvOS 26.0, *) else { return "n/a" }
        switch traits.hdrHeadroomUsageLimit {
        case .active: return "active"
        case .inactive: return "inactive"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
        #else
        return "n/a"
        #endif
    }'''
if old not in s:
    raise SystemExit("Aether Xcode16 patch: headroomLimitLabel anchor not found")
p.write_text(s.replace(old, new, 1))

# tvOS/iOS 26-only AVSampleBufferDisplayLayer.preferredDynamicRange.
p = root / "Renderer" / "SampleBufferRenderer.swift"
s = p.read_text()
old = '''        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            layer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                layer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }'''
new = '''        #if compiler(>=6.2)
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
        #endif'''
if s.count(old) != 1:
    raise SystemExit(f"Aether Xcode16 patch: makeDisplayLayer anchor count={s.count(old)}")
s = s.replace(old, new, 1)
old2 = '''        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            displayLayer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                displayLayer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }'''
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
        #endif'''
if s.count(old2) != 1:
    raise SystemExit(f"Aether Xcode16 patch: setHDROutput anchor count={s.count(old2)}")
p.write_text(s.replace(old2, new2, 1))

# VideoToolbox supplemental AV1 decoder registration post-dates the Xcode 16.4 SDK.
p = root / "Video" / "VTCapabilityProbe.swift"
s = p.read_text()
old = '''        if #available(tvOS 26.2, iOS 26.2, macOS 16.0, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }'''
new = '''        #if compiler(>=6.2)
        if #available(tvOS 26.2, iOS 26.2, macOS 16.0, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
        #endif'''
if old not in s:
    raise SystemExit("Aether Xcode16 patch: VT supplemental decoder anchor not found")
p.write_text(s.replace(old, new, 1))

print("Applied Debrid Channels Xcode 16.4 compatibility shim to AetherEngine 6.81.0")
