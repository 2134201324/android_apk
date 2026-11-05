#!/usr/bin/env python3
"""
make-icon.py —— 按应用名生成一套专属图标（几何图形 + 配色由名字哈希决定）

用法：
    python3 make-icon.py --name "记账本" --res app/src/main/res

产出：
    mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png           圆角底 + 白色图形
    mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher_foreground.png 透明底 + 白色图形（adaptive 前景）
    并改写 res/values/colors.xml 里的 ic_launcher_background

为什么不用文字做图标：
    中文字形要带字体文件，容器里不一定有；只画几何图形则零依赖，
    而且 48px 下文字本来也糊成一团。图形 + 配色足以让每个应用可区分。

没有 PIL 时脚本退出码 2，调用方应保留模板默认图标，不要因此中断构建。
"""
import argparse
import hashlib
import math
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit(2)

# 与 Material 深色系协调的六组主色
PALETTE = [
    (79, 140, 255),
    (16, 185, 129),
    (244, 63, 94),
    (245, 158, 11),
    (139, 92, 246),
    (6, 182, 212),
]
SHAPES = ["hexagon", "triangle", "circle", "square", "diamond", "rings"]
DENSITIES = {"mdpi": 1.0, "hdpi": 1.5, "xhdpi": 2.0, "xxhdpi": 3.0, "xxxhdpi": 4.0}
SS = 4  # 超采样倍数，用于抗锯齿


def pick(name: str):
    h = hashlib.sha256(name.encode("utf-8")).hexdigest()
    return SHAPES[int(h[0:2], 16) % len(SHAPES)], PALETTE[int(h[2:4], 16) % len(PALETTE)]


def mix(c, target, t):
    return tuple(int(c[i] + (target[i] - c[i]) * t) for i in range(3))


def draw_shape(d, n, shape, color, width, cx=None, cy=None, rad=None):
    cx = n / 2 if cx is None else cx
    cy = n / 2 if cy is None else cy
    rad = n * 0.30 if rad is None else rad

    def poly(k, r, rot=-90):
        return [
            (cx + r * math.cos(math.radians(360 / k * i + rot)),
             cy + r * math.sin(math.radians(360 / k * i + rot)))
            for i in range(k)
        ]

    if shape == "hexagon":
        d.polygon(poly(6, rad), outline=color, width=width)
        d.polygon(poly(3, rad * 0.52), outline=color, width=width)
    elif shape == "triangle":
        d.polygon(poly(3, rad * 1.08), outline=color, width=width)
        d.polygon(poly(3, rad * 0.50, rot=90), outline=color, width=width)
    elif shape == "circle":
        r = rad * 0.92
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=color, width=width)
        r2 = rad * 0.38
        d.ellipse([cx - r2, cy - r2, cx + r2, cy + r2], outline=color, width=width)
    elif shape == "square":
        r = rad * 0.86
        d.rounded_rectangle([cx - r, cy - r, cx + r, cy + r],
                            radius=rad * 0.22, outline=color, width=width)
        r2 = rad * 0.36
        d.rounded_rectangle([cx - r2, cy - r2, cx + r2, cy + r2],
                            radius=rad * 0.10, outline=color, width=width)
    elif shape == "diamond":
        pts = [(cx, cy - rad), (cx + rad * 0.82, cy), (cx, cy + rad), (cx - rad * 0.82, cy)]
        d.polygon(pts, outline=color, width=width)
        d.line([(cx, cy - rad * 0.55), (cx, cy + rad * 0.55)], fill=color, width=width)
    else:  # rings
        for k, r in ((1.0, rad * 0.95), (0.62, rad * 0.60)):
            d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=color, width=width)


def rounded_mask(n, radius):
    m = Image.new("L", (n, n), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, n - 1, n - 1], radius=radius, fill=255)
    return m


def make_icon(size, shape, color, with_bg=True):
    n = int(size * SS)
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if with_bg:
        top = mix(color, (255, 255, 255), 0.10)
        bottom = mix(color, (0, 0, 0), 0.55)
        for y in range(n):
            t = y / max(1, n - 1)
            d.line([(0, y), (n, y)], fill=(*mix(top, bottom, t), 255))
        img.putalpha(rounded_mask(n, int(n * 0.22)))
        d = ImageDraw.Draw(img)
    draw_shape(d, n, shape, (255, 255, 255, 255), max(2, int(n * 0.045)))
    return img.resize((size, size), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--res", required=True, help="app/src/main/res 目录")
    args = ap.parse_args()

    shape, color = pick(args.name)
    print(f"  图形={shape}  主色=#{color[0]:02X}{color[1]:02X}{color[2]:02X}")

    for dens, scale in DENSITIES.items():
        out_dir = os.path.join(args.res, f"mipmap-{dens}")
        os.makedirs(out_dir, exist_ok=True)
        # 传统图标：48dp
        make_icon(int(48 * scale), shape, color, with_bg=True).save(
            os.path.join(out_dir, "ic_launcher.png"))
        # adaptive 前景：108dp，内容已落在中心安全区
        make_icon(int(108 * scale), shape, color, with_bg=False).save(
            os.path.join(out_dir, "ic_launcher_foreground.png"))

    # adaptive icon 的前景与背景
    anydpi = os.path.join(args.res, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8") as f:
        f.write(f"""<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
""")

    # 背景色取主色压暗，与前景白图形对比足够
    bg = mix(color, (0, 0, 0), 0.62)
    colors_path = os.path.join(args.res, "values", "colors.xml")
    os.makedirs(os.path.dirname(colors_path), exist_ok=True)
    with open(colors_path, "w", encoding="utf-8") as f:
        f.write(f"""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#{bg[0]:02X}{bg[1]:02X}{bg[2]:02X}</color>
</resources>
""")
    print(f"  已生成 5 档图标 + adaptive 配置")


if __name__ == "__main__":
    main()
