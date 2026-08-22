#!/usr/bin/env python3
"""生成 DoubaoVoiceSwitch 的 macOS app icon。"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
RESOURCE_DIR = ROOT / "Sources" / "DoubaoVoiceSwitch" / "Resources"
ICONSET_DIR = RESOURCE_DIR / "AppIcon.iconset"
ICON_FILE = RESOURCE_DIR / "AppIcon.icns"
SOURCE_PNG = RESOURCE_DIR / "AppIcon-1024.png"


def draw_voice_mark(
    draw: ImageDraw.ImageDraw,
    bounds: tuple[int, int, int, int],
    color: tuple[int, int, int, int],
    background: tuple[int, int, int, int],
) -> None:
    """绘制极简语音恢复符号。"""
    x0, y0, x1, y1 = bounds
    width = x1 - x0
    height = y1 - y0
    stroke = max(16, int(width * 0.075))
    radius = int(width * 0.22)

    draw.rounded_rectangle(
        bounds,
        radius=radius,
        outline=color,
        width=stroke,
    )

    draw.rectangle(
        (
            x0 + width * 0.62,
            y0 - stroke,
            x1 + stroke,
            y0 + height * 0.36,
        ),
        fill=background,
    )

    bar_width = max(14, int(width * 0.085))
    center_y = y0 + height * 0.52
    for center_x_ratio, bar_height_ratio in [(0.38, 0.32), (0.50, 0.54), (0.62, 0.32)]:
        center_x = x0 + width * center_x_ratio
        bar_height = height * bar_height_ratio
        draw.rounded_rectangle(
            (
                center_x - bar_width / 2,
                center_y - bar_height / 2,
                center_x + bar_width / 2,
                center_y + bar_height / 2,
            ),
            radius=bar_width // 2,
            fill=color,
        )


def make_source_icon() -> Image.Image:
    """生成 1024px 源图。"""
    size = 1024
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    card = (92, 92, 932, 932)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(card, radius=190, fill=(0, 0, 0, 75))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(30)), (0, 22))

    draw = ImageDraw.Draw(icon)
    surface = (246, 247, 250, 255)
    draw.rounded_rectangle(card, radius=190, fill=surface)
    draw.rounded_rectangle((108, 108, 916, 916), radius=174, outline=(255, 255, 255, 165), width=4)
    draw_voice_mark(
        draw,
        (270, 270, 754, 754),
        color=(46, 123, 246, 255),
        background=surface,
    )
    return icon


def write_iconset(source: Image.Image) -> None:
    """写入 iconset 所需的所有尺寸。"""
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)
    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for filename, icon_size in sizes:
        resized = source.resize((icon_size, icon_size), Image.Resampling.LANCZOS)
        resized.save(ICONSET_DIR / filename)


def main() -> None:
    """生成 PNG、iconset 和 icns。"""
    RESOURCE_DIR.mkdir(parents=True, exist_ok=True)
    source = make_source_icon()
    source.save(SOURCE_PNG)
    write_iconset(source)
    if ICON_FILE.exists():
        ICON_FILE.unlink()
    subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(ICONSET_DIR)], check=True)
    os.replace(RESOURCE_DIR / "AppIcon.icns", ICON_FILE)


if __name__ == "__main__":
    main()
