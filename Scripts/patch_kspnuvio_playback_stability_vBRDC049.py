#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_kspnuvio_playback_stability_vBRDC049.py CircularBuffer.swift")

path = Path(sys.argv[1])
text = path.read_text()
old = '''                if predicate(item) {
                    result.append(item)
                    _buffer[Int(i & mask)] = nil
                    headIndex = i + 1
                }
'''
new = '''                if predicate(item) {
                    result.append(item)
                    // vBRDC049: backport upstream KSPlayer fix 4a7add3c (Aug 9 2026).
                    // search(where:) advances headIndex over every slot through the match;
                    // clear all of those slots instead of leaking skipped subtitle frames
                    // behind the new head. Without this, the fixed 255-frame subtitle ring
                    // can become permanently full after ordinary 10-15 minute playback.
                    while headIndex <= i {
                        _buffer[Int(headIndex & mask)] = nil
                        headIndex &+= 1
                    }
                }
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f"Expected exactly one CircularBuffer search anchor, found {count}")
text = text.replace(old, new, 1)
path.write_text(text)
