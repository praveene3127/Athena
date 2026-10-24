import os
import json
from pathlib import Path
from PIL import Image, ImageDraw

def generate_icons():
    root = Path(__file__).resolve().parent.parent
    brand_kit = root / "athena-brand-kit-v3" / "icons"
    src_icon = brand_kit / "app-icon-1024.png"
    
    if not src_icon.exists():
        raise FileNotFoundError(f"Source icon not found at {src_icon}")

    print(f"Loading source brand icon from: {src_icon}")
    base_img = Image.open(src_icon).convert("RGBA")

    # 1. Opaque Master (Solid Black #000000 background, white owl inside) for iOS
    opaque_master = Image.new("RGB", base_img.size, (0, 0, 0))
    opaque_master.paste(base_img, (0, 0), base_img)

    # 2. Squircle Master (RGBA with rounded corners)
    squircle_master = base_img.copy()

    # 3. Round Master (Circle mask for Android round launcher)
    round_master = Image.new("RGBA", base_img.size, (0, 0, 0, 0))
    circle_mask = Image.new("L", base_img.size, 0)
    draw = ImageDraw.Draw(circle_mask)
    draw.ellipse((16, 16, 1008, 1008), fill=255)
    round_master.paste(opaque_master, (0, 0))
    round_master.putalpha(circle_mask)

    # 4. Foreground Master for Android Adaptive Icon
    # Android 108dp icon has a safe zone of 66dp (~61% of canvas).
    # Extract only the white owl symbol (threshold alpha and white pixels)
    owl_mask = Image.new("RGBA", base_img.size, (0, 0, 0, 0))
    # In base_img, the owl pixels are white (R,G,B > 220)
    pixels = base_img.load()
    owl_pixels = owl_mask.load()
    for y in range(base_img.height):
        for x in range(base_img.width):
            r, g, b, a = pixels[x, y]
            if a > 100 and r > 180 and g > 180 and b > 180:
                owl_pixels[x, y] = (255, 255, 255, a)
    
    bbox = owl_mask.getbbox()
    if bbox:
        owl_cropped = owl_mask.crop(bbox)
        # Scale cropped owl so it fits gracefully within the 66% safe zone of 1024 (e.g. 520px)
        target_h = 560
        aspect = owl_cropped.width / owl_cropped.height
        target_w = int(target_h * aspect)
        owl_scaled = owl_cropped.resize((target_w, target_h), Image.Resampling.LANCZOS)
        
        foreground_master = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
        offset_x = (1024 - target_w) // 2
        offset_y = (1024 - target_h) // 2
        foreground_master.paste(owl_scaled, (offset_x, offset_y), owl_scaled)
    else:
        foreground_master = base_img.copy()

    # =========================================================================
    # A. Generate Android Icons
    # =========================================================================
    res_dir = root / "app" / "android" / "app" / "src" / "main" / "res"
    android_specs = {
        "mipmap-mdpi": {"legacy": 48, "foreground": 108},
        "mipmap-hdpi": {"legacy": 72, "foreground": 162},
        "mipmap-xhdpi": {"legacy": 96, "foreground": 216},
        "mipmap-xxhdpi": {"legacy": 144, "foreground": 324},
        "mipmap-xxxhdpi": {"legacy": 192, "foreground": 432},
    }

    print("\n--- Generating Android Icons ---")
    for folder, sizes in android_specs.items():
        folder_path = res_dir / folder
        folder_path.mkdir(parents=True, exist_ok=True)
        
        # 1. Standard squircle icon
        leg_sz = sizes["legacy"]
        leg_img = squircle_master.resize((leg_sz, leg_sz), Image.Resampling.LANCZOS)
        leg_img.save(folder_path / "ic_launcher.png", format="PNG")
        
        # 2. Round icon
        round_img = round_master.resize((leg_sz, leg_sz), Image.Resampling.LANCZOS)
        round_img.save(folder_path / "ic_launcher_round.png", format="PNG")
        
        # 3. Adaptive foreground icon
        fg_sz = sizes["foreground"]
        fg_img = foreground_master.resize((fg_sz, fg_sz), Image.Resampling.LANCZOS)
        fg_img.save(folder_path / "ic_launcher_foreground.png", format="PNG")
        print(f"  [Android] {folder}: legacy={leg_sz}x{leg_sz}, foreground={fg_sz}x{fg_sz}")

    # Android anydpi-v26 adaptive icon definition
    anydpi_dir = res_dir / "mipmap-anydpi-v26"
    anydpi_dir.mkdir(parents=True, exist_ok=True)
    adaptive_xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
'''
    (anydpi_dir / "ic_launcher.xml").write_text(adaptive_xml, encoding="utf-8")
    (anydpi_dir / "ic_launcher_round.xml").write_text(adaptive_xml, encoding="utf-8")

    # Android values/colors.xml for background
    values_dir = res_dir / "values"
    values_dir.mkdir(parents=True, exist_ok=True)
    colors_xml_path = values_dir / "colors.xml"
    colors_xml = '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#000000</color>
</resources>
'''
    colors_xml_path.write_text(colors_xml, encoding="utf-8")

    # =========================================================================
    # B. Generate iOS Icons
    # =========================================================================
    ios_iconset = root / "app" / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    contents_file = ios_iconset / "Contents.json"

    print("\n--- Generating iOS Icons ---")
    if contents_file.exists():
        with open(contents_file, "r", encoding="utf-8") as f:
            contents = json.load(f)
        
        for item in contents.get("images", []):
            fn = item.get("filename")
            size_str = item.get("size", "0x0")
            scale_str = item.get("scale", "1x")
            
            w_pt, h_pt = [float(x) for x in size_str.split("x")]
            scale = float(scale_str.replace("x", ""))
            pixel_w = int(round(w_pt * scale))
            pixel_h = int(round(h_pt * scale))
            
            # iOS requires opaque icons
            if pixel_w == 1024 and pixel_h == 1024:
                resized = opaque_master.resize((1024, 1024), Image.Resampling.LANCZOS)
            else:
                resized = opaque_master.resize((pixel_w, pixel_h), Image.Resampling.LANCZOS)
            
            target_path = ios_iconset / fn
            resized.save(target_path, format="PNG")
            print(f"  [iOS] {fn} -> {pixel_w}x{pixel_h}px")

    # =========================================================================
    # C. Generate Web Icons
    # =========================================================================
    web_dir = root / "app" / "web"
    web_icons_dir = web_dir / "icons"
    web_icons_dir.mkdir(parents=True, exist_ok=True)

    print("\n--- Generating Web Icons ---")
    # PWA icons
    opaque_master.resize((192, 192), Image.Resampling.LANCZOS).save(web_icons_dir / "Icon-192.png", format="PNG")
    opaque_master.resize((512, 512), Image.Resampling.LANCZOS).save(web_icons_dir / "Icon-512.png", format="PNG")
    opaque_master.resize((192, 192), Image.Resampling.LANCZOS).save(web_icons_dir / "Icon-maskable-192.png", format="PNG")
    opaque_master.resize((512, 512), Image.Resampling.LANCZOS).save(web_icons_dir / "Icon-maskable-512.png", format="PNG")
    opaque_master.resize((180, 180), Image.Resampling.LANCZOS).save(web_icons_dir / "apple-touch-icon.png", format="PNG")

    # Favicon
    squircle_master.resize((32, 32), Image.Resampling.LANCZOS).save(web_dir / "favicon.png", format="PNG")

    # Copy favicon.ico and favicon.svg if present in brand kit
    if (brand_kit / "favicon.ico").exists():
        (web_dir / "favicon.ico").write_bytes((brand_kit / "favicon.ico").read_bytes())
    if (brand_kit / "favicon.svg").exists():
        (web_dir / "favicon.svg").write_bytes((brand_kit / "favicon.svg").read_bytes())

    print("\n[SUCCESS] All Athena platform icons generated cleanly from official brand kit.")

if __name__ == "__main__":
    generate_icons()
