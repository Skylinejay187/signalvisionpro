#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_kspnuvio_idet_overflow_vBRDC064.py KSOptions.swift")

path = Path(sys.argv[1])
text = path.read_text()
original = text

property_old = "    private var idetTypeMap = [VideoInterlacingType: UInt]()\n"
property_new = "    // vBRDC064: signed, bounded counters prevent Swift unsigned-underflow traps in idet voting.\n    private var idetTypeMap = [VideoInterlacingType: Int]()\n"
if text.count(property_old) != 1:
    raise SystemExit(f"Expected exactly one idetTypeMap UInt anchor, found {text.count(property_old)}")
text = text.replace(property_old, property_new, 1)

block_old = '''                            idetTypeMap[type] = (idetTypeMap[type] ?? 0) + 1
                            let tff = idetTypeMap[.tff] ?? 0
                            let bff = idetTypeMap[.bff] ?? 0
                            let progressive = idetTypeMap[.progressive] ?? 0
                            let undetermined = idetTypeMap[.undetermined] ?? 0
                            if progressive - tff - bff > 100 {
                                videoInterlacingType = .progressive
                                autoDeInterlace = false
                            } else if bff - progressive > 100 {
                                videoInterlacingType = .bff
                                autoDeInterlace = false
                            } else if tff - progressive > 100 {
                                videoInterlacingType = .tff
                                autoDeInterlace = false
                            } else if undetermined - progressive - tff - bff > 100 {
                                videoInterlacingType = .undetermined
                                autoDeInterlace = false
                            }
'''
block_new = '''                            // Upstream stores these counters as UInt and subtracts competing votes.
                            // A perfectly ordinary sequence such as tff=1/progressive=0 therefore executes
                            // 0 - 1 and traps in Swift. Keep the detector semantics, but use signed counters
                            // and a practical saturation ceiling so every comparison remains arithmetic-safe.
                            let current = idetTypeMap[type] ?? 0
                            idetTypeMap[type] = min(current + 1, 1_000_000)
                            let tff = idetTypeMap[.tff] ?? 0
                            let bff = idetTypeMap[.bff] ?? 0
                            let progressive = idetTypeMap[.progressive] ?? 0
                            let undetermined = idetTypeMap[.undetermined] ?? 0
                            if progressive - tff - bff > 100 {
                                videoInterlacingType = .progressive
                                autoDeInterlace = false
                            } else if bff - progressive > 100 {
                                videoInterlacingType = .bff
                                autoDeInterlace = false
                            } else if tff - progressive > 100 {
                                videoInterlacingType = .tff
                                autoDeInterlace = false
                            } else if undetermined - progressive - tff - bff > 100 {
                                videoInterlacingType = .undetermined
                                autoDeInterlace = false
                            }
'''
if text.count(block_old) != 1:
    raise SystemExit(f"Expected exactly one idet vote block, found {text.count(block_old)}")
text = text.replace(block_old, block_new, 1)

if text == original:
    raise SystemExit("vBRDC064 idet patch made no changes")
if '[VideoInterlacingType: UInt]' in text:
    raise SystemExit("Unsafe UInt idet counter remains after patch")
path.write_text(text)
