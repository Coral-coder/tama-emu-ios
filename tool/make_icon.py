# Draws the app icon (an amber egg-shaped toy with a dot-matrix screen) and writes every size.
import sys, os, glob, re
from PIL import Image, ImageDraw
S = 1024
img = Image.new('RGB', (S, S), (12, 13, 16))
d = ImageDraw.Draw(img)
# soft background glow
for r in range(520, 0, -8):
    c = int(12 + (40 - 12) * (1 - r / 520) * 0.6)
    d.ellipse([S/2 - r, S/2 - r + 40, S/2 + r, S/2 + r + 40], fill=(c, c - 2 if c > 2 else 0, max(0, c - 10)))
# egg body
d.ellipse([170, 110, 854, 950], fill=(255, 176, 0))
d.ellipse([200, 140, 824, 920], fill=(255, 190, 40))
# screen
d.rounded_rectangle([290, 300, 734, 640], radius=40, fill=(20, 22, 18))
d.rounded_rectangle([320, 330, 704, 610], radius=24, fill=(185, 195, 163))
# a little pet in dots (16 x 12 grid)
pet = ["....XXXXXX......", "...X......X.....", "..X..X..X..X....", "..X........X....", "..X..XXXX..X....",
       "...X......X.....", "....XXXXXX......", "...X.X..X.X.....", "..X..X..X..X....", "......XX........"]
u = 22
ox, oy = 512 - 7 * u, 350 + 1 * u
for y, row in enumerate(pet):
    for x, ch in enumerate(row):
        if ch == 'X':
            d.rectangle([ox + x * u + 2, oy + y * u + 2, ox + (x + 1) * u - 2, oy + (y + 1) * u - 2], fill=(28, 35, 22))
# three keys
for i, cx in enumerate([380, 512, 644]):
    cy = 760 + (30 if i == 1 else 0)
    d.ellipse([cx - 44, cy - 44, cx + 44, cy + 44], fill=(20, 22, 26))
img.save(sys.argv[1] + '/icon-1024.png')
ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
for f in glob.glob(ios + '/Icon-App-*.png'):
    m = re.search(r'(\d+(?:\.\d+)?)x\d+(?:\.\d+)?@(\d)x', f)
    px = int(round(float(m.group(1)) * int(m.group(2))))
    img.resize((px, px), Image.LANCZOS).save(f)
for dpi, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
    img.resize((px, px), Image.LANCZOS).save(f'android/app/src/main/res/mipmap-{dpi}/ic_launcher.png')
print('icons written')
