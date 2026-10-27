"""Render the repository SVG into platform icons; requires librsvg's rsvg-convert."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SVG = ROOT / 'design/app-icon.svg'

def render(source, target, size):
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), '-o', str(target), str(source)], check=True)

for size in [16, 32, 64, 128, 256, 512, 1024]:
    render(SVG, ROOT / f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png', size)
for size in [192, 512]:
    render(SVG, ROOT / f'web/icons/Icon-{size}.png', size)
render(SVG, ROOT / 'web/favicon.png', 32)
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    render(SVG, ROOT / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png', size)
with tempfile.TemporaryDirectory() as temporary:
    maskable = Path(temporary) / 'maskable.svg'
    maskable.write_text(SVG.read_text().replace('x="32" y="32" width="960" height="960" rx="216"', 'x="0" y="0" width="1024" height="1024" rx="0"'))
    for size in [192, 512]:
        render(maskable, ROOT / f'web/icons/Icon-maskable-{size}.png', size)
