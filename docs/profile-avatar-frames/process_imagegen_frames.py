from pathlib import Path
from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIR = Path(r"C:\Users\Administrator\.codex\generated_images\019f23ee-c512-7481-a0a7-db1f4776c183")
DOC_DIR = ROOT / "docs" / "profile-avatar-frames" / "imagegen-refined"
ASSET_DIR = ROOT / "assets" / "images" / "profile"

SOURCES = {
    1: "ig_06a77e0a954802b4016a46b4a5ecdc819b9e5e06e8d87a74f8.png",
    2: "ig_0d2b33aeaaa95912016a46b7411ba48199b269782e1795eff5.png",
    3: "ig_06a77e0a954802b4016a46b533bb10819b89ec23fb383ca7f8.png",
    4: "ig_06a77e0a954802b4016a46b579dc1c819bad8e1249161d1f60.png",
    5: "ig_06a77e0a954802b4016a46b5c5a4b8819bb3943fa14baf3f78.png",
    6: "ig_06a77e0a954802b4016a46b6141d28819bbfc977152c8f3d3a.png",
    7: "ig_06a77e0a954802b4016a46b666b110819b9ed4e87fb2d30255.png",
}


def remove_green(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    px = rgba.load()
    width, height = rgba.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = px[x, y]
            dominance = g - max(r, b)
            if g > 95 and dominance > 14:
                if dominance >= 72:
                    new_alpha = 0
                else:
                    new_alpha = int(a * (1 - (dominance - 14) / 58))
                px[x, y] = (r, g, b, new_alpha)
    return rgba


def fit_to_square(image: Image.Image, size: int = 512) -> Image.Image:
    bbox = image.getbbox()
    if bbox is None:
        return Image.new("RGBA", (size, size), (0, 0, 0, 0))

    cropped = image.crop(bbox)
    canvas_margin = 34
    max_edge = size - canvas_margin * 2
    ratio = min(max_edge / cropped.width, max_edge / cropped.height)
    resized = cropped.resize(
        (round(cropped.width * ratio), round(cropped.height * ratio)),
        Image.Resampling.LANCZOS,
    )
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(
        resized,
        ((size - resized.width) // 2, (size - resized.height) // 2),
    )
    return canvas


def make_contact_sheet(images: list[Image.Image]) -> Image.Image:
    tile = 180
    label_h = 28
    sheet = Image.new("RGBA", (tile * 7, tile + label_h), (238, 245, 255, 255))
    for index, image in enumerate(images, start=1):
        thumb = image.resize((150, 150), Image.Resampling.LANCZOS)
        x = (index - 1) * tile + 15
        sheet.alpha_composite(thumb, (x, 10))
    return sheet


def main() -> None:
    DOC_DIR.mkdir(parents=True, exist_ok=True)
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    processed = []

    for level, filename in SOURCES.items():
        source = SOURCE_DIR / filename
        raw_out = DOC_DIR / f"avatar_frame_lv{level}_raw.png"
        alpha_out = DOC_DIR / f"avatar_frame_lv{level}_alpha.png"
        asset_out = ASSET_DIR / f"avatar_frame_lv{level}.png"

        raw = Image.open(source)
        raw.save(raw_out)
        alpha = remove_green(raw)
        fitted = fit_to_square(alpha)
        alpha.save(alpha_out)
        fitted.save(asset_out)
        processed.append(fitted)

        center_alpha = fitted.getpixel((256, 256))[3]
        corner_alpha = fitted.getpixel((0, 0))[3]
        print(f"LV{level}: center alpha={center_alpha}, corner alpha={corner_alpha}, {asset_out}")

    make_contact_sheet(processed).save(DOC_DIR / "avatar_frame_contact_sheet.png")


if __name__ == "__main__":
    main()
