import bpy, sys, os
from pathlib import Path
args = sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
if len(args) != 2: raise SystemExit('usage: blender --background source.blend --python export_paid_fab_usdz.py -- output.usdz source_dir')
out = Path(args[0]).resolve(); source_dir = Path(args[1]).resolve(); out.parent.mkdir(parents=True, exist_ok=True)
# Make missing relative image paths resolve against the authoritative supplied texture directory.
tex = source_dir / 'textures'
for image in bpy.data.images:
    if image.source != 'FILE' or image.packed_file is not None: continue
    p = Path(bpy.path.abspath(image.filepath)) if image.filepath else None
    if p and p.exists(): continue
    candidates = [tex / Path(image.filepath).name, source_dir / Path(image.filepath).name] if image.filepath else []
    for c in candidates:
        if c.exists(): image.filepath = str(c); break
missing=[]
for image in bpy.data.images:
    if image.source == 'FILE' and image.packed_file is None and image.filepath:
        p=Path(bpy.path.abspath(image.filepath))
        if not p.exists(): missing.append((image.name,str(p)))
if missing: raise SystemExit('Missing image dependencies: '+repr(missing))
# Preserve authored object hierarchy/materials; do not apply speculative theater transforms here.
kwargs=dict(filepath=str(out), export_materials=True, export_textures=True, relative_paths=True)
try:
    bpy.ops.wm.usd_export(**kwargs)
except TypeError:
    kwargs.pop('export_textures', None)
    bpy.ops.wm.usd_export(**kwargs)
if not out.exists() or out.stat().st_size < 1_000_000: raise SystemExit(f'USDZ export missing/suspiciously small: {out}')
print(f'Exported {out} ({out.stat().st_size} bytes)')
