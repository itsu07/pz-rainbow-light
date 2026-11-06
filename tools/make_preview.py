"""Make the Workshop preview (preview.png, 256x256) from the frames light_test.py --gif took:
the lit wall next to the lamp in red, green, blue and magenta, 2x2.

Usage (from the RainbowLight folder):
  python tools\\light_test.py --gif      (if the frames are not there yet)
  python tools\\make_preview.py          -> preview.png next to this README
The picture is a screenshot of the game, so preview.png stays out of the repository (.gitignore).
Needs Pillow, like ..\\tools\\make_preview.py.
"""
import argparse
import os
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
FRAMES = 25
# lit wall to the right of the lamp in the 1280x720 game window; leaves out the lamp because the
# player's name label sits right under it
BOX = (675, 185, 875, 385)
HUES = (0, 8, 16, 21)   # frame numbers: red, green, blue, magenta


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--frames', default=str(Path(os.environ.get('USERPROFILE', '')) / 'PZTest_rainbow' / 'client1' / 'Screenshots'))
    ap.add_argument('--out', default=str(HERE.parent / 'preview.png'))
    a = ap.parse_args()
    out = Image.new('RGB', (256, 256))
    for k, i in enumerate(HUES):
        f = Path(a.frames) / f'rl_gif_{i:02d}.png'
        if not f.exists():
            print(f'{f} がありません（先に python tools\\light_test.py --gif）')
            return 1
        tile = Image.open(f).convert('RGB').crop(BOX).resize((128, 128), Image.LANCZOS)
        out.paste(tile, ((k % 2) * 128, (k // 2) * 128))
    out.save(a.out)
    print(f'{a.out}: 256x256, {Path(a.out).stat().st_size // 1024} KB')
    return 0


if __name__ == '__main__':
    sys.exit(main())
