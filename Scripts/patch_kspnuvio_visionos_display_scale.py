#!/usr/bin/env python3
"""Adapt only KSPlayer's two legacy UIScreen-based layer scale assignments for visionOS.

Run after the pinned KSPlayer checkout/legacy patches; never edit the untouched tvOS copy.
"""
from pathlib import Path

path = Path('Vendor/KSPNUVIO/Sources/KSPlayer/Video/VideoPlayerView.swift')
if not path.is_file():
    raise SystemExit('ERROR: pinned KSPlayer source missing; dependency preparation did not finish')
source = path.read_text()
replacements = (
    ('subtitleLabel.backingLayer?.rasterizationScale = UIScreen.main.scale',
     '''#if os(visionOS)
        // UIScreen is unavailable in visionOS. Avoid hard-coded screen assumptions
        // until the layer scale can be derived from an attached window.
        subtitleLabel.backingLayer?.rasterizationScale = 1.0
        #else
        subtitleLabel.backingLayer?.rasterizationScale = UIScreen.main.scale
        #endif'''),
    ('layer.rasterizationScale = UIScreen.main.scale',
     '''#if os(visionOS)
        layer.rasterizationScale = 1.0
        #else
        layer.rasterizationScale = UIScreen.main.scale
        #endif'''),
)
for old, new in replacements:
    if new in source:
        print('Already patched:', old)
        continue
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'ERROR: expected exactly one occurrence of {old!r}; found {count}; pinned source may have changed')
    source = source.replace(old, new, 1)
path.write_text(source)
assert source.count('#if os(visionOS)') >= 2
print('PASS: patched two visionOS-only KSPlayer UIScreen uses; tvOS branches retained')
