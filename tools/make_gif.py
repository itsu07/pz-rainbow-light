"""Make an animated GIF of one trip around the rainbow from the frames light_test.py --gif took.

Usage (from the RainbowLight folder):
  python tools\\light_test.py --gif      take the frames (test server + one game, by itself)
  python tools\\make_gif.py              -> rainbow_light.gif next to this README

Options: --frames DIR (default %USERPROFILE%\\PZTest_rainbow\\client1\\Screenshots),
         --crop x,y,w,h (part of the 1280x720 game window, default around the lamp),
         --loop-ms N (one trip, default 2000 = PERIOD_MS in RainbowLight_Client.lua),
         --pattern GLOB (which frames, default rl_gif_*.png; the mirror ball test takes rl_ball_run_*.png),
         --out FILE
Standard library only: reads the PNGs itself and writes the GIF itself (256 colors chosen
from all frames together by median cut, so every frame shares one palette).
"""
import argparse
import os
import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent


# ---------- PNG (8-bit RGB or RGBA, not interlaced: what the game writes) ----------

def read_png(path, crop):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'{path}: not a PNG')
    pos, idat = 8, []
    width = height = color = None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b'IHDR':
            width, height, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', body)
            if depth != 8 or color not in (2, 6) or interlace:
                raise ValueError(f'{path}: unsupported PNG (depth {depth}, color {color})')
        elif kind == b'IDAT':
            idat.append(body)
        elif kind == b'IEND':
            break
    bpp = 3 if color == 2 else 4
    raw = zlib.decompress(b''.join(idat))
    stride = width * bpp
    x0, y0, w, h = crop
    prev = bytearray(stride)
    rows = []
    for y in range(min(height, y0 + h)):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        if y >= y0:
            seg = line[x0 * bpp:(x0 + w) * bpp]
            if bpp == 4:
                seg = bytes(b for i, b in enumerate(seg) if i % 4 != 3)
            rows.append(bytes(seg))
    # the game writes the image bottom-up (glReadPixels) and flips it when saving; if a frame
    # ever comes out upside down, flip here
    return rows


# ---------- palette: median cut over 5-bit-per-channel color counts of all frames ----------

def build_palette(frames, size=256):
    counts = {}
    for rows in frames:
        for row in rows:
            for i in range(0, len(row), 3):
                k = ((row[i] >> 3) << 10) | ((row[i + 1] >> 3) << 5) | (row[i + 2] >> 3)
                counts[k] = counts.get(k, 0) + 1
    boxes = [list(counts.items())]
    while len(boxes) < size:
        # split the box with the most pixels along its widest channel
        boxes.sort(key=lambda b: sum(c for _, c in b) if len(b) > 1 else -1)
        box = boxes.pop()
        if len(box) < 2:
            boxes.append(box)
            break
        spans = []
        for sh in (10, 5, 0):
            vals = [(k >> sh) & 31 for k, _ in box]
            spans.append((max(vals) - min(vals), sh))
        sh = max(spans)[1]
        box.sort(key=lambda kc: (kc[0] >> sh) & 31)
        total, run, cut = sum(c for _, c in box), 0, 1
        for i, (_, c) in enumerate(box):
            run += c
            if run >= total / 2:
                cut = max(1, min(len(box) - 1, i))
                break
        boxes += [box[:cut], box[cut:]]
    palette = []
    for box in boxes:
        n = sum(c for _, c in box)
        r = sum(((k >> 10) & 31) * c for k, c in box) / n
        g = sum(((k >> 5) & 31) * c for k, c in box) / n
        b = sum((k & 31) * c for k, c in box) / n
        palette.append((int(r * 8.23), int(g * 8.23), int(b * 8.23)))
    while len(palette) < size:
        palette.append((0, 0, 0))
    # nearest palette entry for every 5-bit color that occurs
    lookup = {}
    for k in counts:
        r, g, b = ((k >> 10) & 31) * 8.23, ((k >> 5) & 31) * 8.23, (k & 31) * 8.23
        lookup[k] = min(range(len(palette)),
                        key=lambda i: (palette[i][0] - r) ** 2 + (palette[i][1] - g) ** 2 + (palette[i][2] - b) ** 2)
    return palette, lookup


def index_frame(rows, lookup):
    out = bytearray()
    for row in rows:
        for i in range(0, len(row), 3):
            out.append(lookup[((row[i] >> 3) << 10) | ((row[i + 1] >> 3) << 5) | (row[i + 2] >> 3)])
    return bytes(out)


# ---------- GIF89a with LZW ----------

def lzw(pixels, min_size=8):
    clear, end = 1 << min_size, (1 << min_size) + 1
    out, bits, nbits = bytearray(), 0, 0
    size = min_size + 1

    def emit(code):
        nonlocal bits, nbits
        bits |= code << nbits
        nbits += size
        while nbits >= 8:
            out.append(bits & 255)
            bits >>= 8
            nbits -= 8

    table = {bytes([i]): i for i in range(clear)}
    nxt = end + 1
    emit(clear)
    w = b''
    for p in pixels:
        wc = w + bytes([p])
        if wc in table:
            w = wc
            continue
        emit(table[w])
        if nxt < 4096:
            table[wc] = nxt
            nxt += 1
            if nxt > (1 << size) and size < 12:
                size += 1
        else:
            emit(clear)
            table = {bytes([i]): i for i in range(clear)}
            nxt, size = end + 1, min_size + 1
        w = bytes([p])
    if w:
        emit(table[w])
    emit(end)
    if nbits:
        out.append(bits & 255)
    blocks = bytearray([min_size])
    for i in range(0, len(out), 255):
        chunk = out[i:i + 255]
        blocks += bytes([len(chunk)]) + chunk
    blocks.append(0)
    return bytes(blocks)


def write_gif(path, w, h, palette, frames, delay_cs):
    g = bytearray(b'GIF89a')
    g += struct.pack('<HHBBB', w, h, 0xF7, 0, 0)          # global table, 256 colors
    for r, gg, b in palette:
        g += bytes([r, gg, b])
    g += b'\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00'   # loop forever
    for pixels in frames:
        g += struct.pack('<BBBBHBB', 0x21, 0xF9, 4, 0, delay_cs, 0, 0)
        g += struct.pack('<BHHHHB', 0x2C, 0, 0, w, h, 0)
        g += lzw(pixels)
    g.append(0x3B)
    Path(path).write_bytes(g)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--frames', default=str(Path(os.environ.get('USERPROFILE', '')) / 'PZTest_rainbow' / 'client1' / 'Screenshots'))
    ap.add_argument('--crop', default='390,110,600,310')
    ap.add_argument('--loop-ms', type=int, default=2000)
    ap.add_argument('--pattern', default='rl_gif_*.png')
    ap.add_argument('--out', default=str(HERE.parent / 'rainbow_light.gif'))
    a = ap.parse_args()
    files = sorted(Path(a.frames).glob(a.pattern))
    if not files:
        print(f'{a.frames} に {a.pattern} がありません（先に python tools\\light_test.py --gif か --ball）')
        return 1
    crop = tuple(int(v) for v in a.crop.split(','))
    frames = []
    for f in files:
        frames.append(read_png(f, crop))
        print(f'read {f.name}', flush=True)
    palette, lookup = build_palette(frames)
    indexed = [index_frame(rows, lookup) for rows in frames]
    delay = max(2, round(a.loop_ms / len(files) / 10))
    write_gif(a.out, crop[2], len(frames[0]), palette, indexed, delay)
    print(f'{a.out}: {len(files)} frames x {delay * 10} ms = {len(files) * delay * 10} ms per loop, '
          f'{Path(a.out).stat().st_size // 1024} KB')
    return 0


if __name__ == '__main__':
    sys.exit(main())
