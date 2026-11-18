#!/usr/bin/env python3
"""Generate deterministic local BookX textures without external dependencies."""
import json, math, os, random, struct, zlib
from pathlib import Path

ROOT = Path("BookX/Assets.xcassets")

def png(path, width, height, pixel):
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(pixel(x, y))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(rows), 7)) + chunk(b"IEND", b""))

def save(name, w, h, pixel):
    folder = ROOT / (name + ".imageset")
    folder.mkdir(parents=True, exist_ok=True)
    png(folder / (name + ".png"), w, h, pixel)
    (folder / "Contents.json").write_text(json.dumps({"images": [{"filename": name + ".png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, ensure_ascii=False))

def texture(rgb, seed):
    rng = random.Random(seed)
    noise = [rng.randrange(-23, 24) for _ in range(128 * 512)]
    def pixel(x, y):
        n = noise[y * 128 + x]
        grain = 7 * math.sin(x * .23 + y * .014) + 4 * math.sin(y * .19 + x * .08)
        edge = -15 * (1 - min(x, 127-x) / 64)
        d = n * .34 + grain + edge
        return tuple(max(0, min(255, int(v + d))) for v in rgb) + (255,)
    return pixel

for i, (name, color) in enumerate([
    ("LeatherGreen", (32, 68, 55)), ("LeatherBrown", (99, 49, 35)),
    ("LeatherCharcoal", (69, 67, 62)), ("LinenIvory", (211, 193, 158))
]):
    save(name, 128, 512, texture(color, 113 + i))

def wood(x, y):
    wave = math.sin(y * .22 + 2 * math.sin(x * .04)) * 13 + math.sin(y * .73 + x * .015) * 5
    v = wave + 7 * math.sin(x * .1 + y * .05)
    return (max(0, min(255, int(134+v))), max(0, min(255, int(83+v*.7))), max(0, min(255, int(47+v*.4))), 255)
save("WalnutShelf", 512, 32, wood)

GOLD = (218, 174, 99, 225)
def ornament(kind):
    def pixel(x, y):
        fx = x / 256
        fy = y / 96
        if kind == "OrnamentWaves":
            d = min(abs(fy - (.40 + .12 * math.sin(fx * 19 + phase))) for phase in (0, 1.5, 3.0))
            on = d < .015 and .08 < fx < .92
        elif kind == "OrnamentMountains":
            ridge = .77 - .46 * abs(math.sin(fx * 10)) - .12 * math.sin(fx * 23)
            on = abs(fy-ridge) < .017 and .05 < fx < .95
        else:
            d = min(math.hypot(fx-cx, fy-cy) for cx, cy in ((.3,.55),(.5,.3),(.7,.55)))
            on = .12 < d < .14
        return GOLD if on else (0,0,0,0)
    return pixel
for name in ("OrnamentWaves", "OrnamentMountains", "OrnamentFloral"):
    save(name, 256, 96, ornament(name))
print("Generated 8 BookX texture image sets.")
