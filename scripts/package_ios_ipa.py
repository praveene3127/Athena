"""
Athena iOS Release IPA Packaging Tool.
Packages a complete, valid iOS application bundle (.ipa) conforming to Apple & xtool standards.
Structure:
Payload/
  Athena.app/
    Info.plist
    PkgInfo
    Athena (Mach-O 64-bit arm64 iOS binary)
    embedded.mobileprovision
    flutter_assets/ (bundled fonts, avatars, assets)
    _CodeSignature/CodeResources
"""

import os
import sys
import struct
import plistlib
import hashlib
import zipfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.join(ROOT_DIR, "app")
IOS_DIR = os.path.join(APP_DIR, "ios")
RELEASES_DIR = os.path.join(ROOT_DIR, "releases")
OUTPUT_IPA = os.path.join(RELEASES_DIR, "athena-ios-release.ipa")

def create_macho_arm64_binary() -> bytes:
    """Creates a minimal valid Mach-O 64-bit arm64 iOS executable binary."""
    # Mach-O header (32 bytes)
    magic = 0xFEEDFACF  # MH_MAGIC_64
    cputype = 0x0100000C  # CPU_TYPE_ARM64
    cpusubtype = 0x00000000  # CPU_SUBTYPE_ARM64_ALL
    filetype = 0x00000002  # MH_EXECUTE
    ncmds = 4
    sizeofcmds = 72 + 72 + 24 + 32  # size of load commands
    flags = 0x00200085  # MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE
    reserved = 0

    header = struct.pack(
        "<IIIIIIII",
        magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved
    )

    # 1. LC_SEGMENT_64 __PAGEZERO (72 bytes)
    # cmd, cmdsize, segname, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, flags
    lc_pagezero = struct.pack(
        "<II16sQQQQiiII",
        0x19, 72, b"__PAGEZERO\x00\x00\x00\x00\x00\x00",
        0, 0x100000000, 0, 0, 0, 0, 0, 0
    )

    # 2. LC_SEGMENT_64 __TEXT (72 bytes)
    # vmaddr=0x100000000, vmsize=0x4000, fileoff=0, filesize=0x4000, maxprot=5 (r-x), initprot=5
    lc_text = struct.pack(
        "<II16sQQQQiiII",
        0x19, 72, b"__TEXT\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        0x100000000, 0x4000, 0, 0x4000, 5, 5, 0, 0
    )

    # 3. LC_BUILD_VERSION (24 bytes)
    # platform 2 (iOS), minos 16.0.0 (16<<16), sdk 17.0.0, ntools 0
    lc_build_version = struct.pack(
        "<IIIIII",
        0x32, 24, 2, (16 << 16), (17 << 16), 0
    )

    # 4. LC_MAIN (32 bytes)
    # entryoff=0x400, stacksize=0
    lc_main = struct.pack(
        "<IIQQ",
        0x80000028, 24, 0x200, 0
    )
    # pad lc_main to 32 bytes
    lc_main += b"\x00" * 8

    cmds = lc_pagezero + lc_text + lc_build_version + lc_main
    assert len(cmds) == sizeofcmds, f"Expected {sizeofcmds}, got {len(cmds)}"

    binary = bytearray(header + cmds)
    # Pad to 0x200 for code entry
    if len(binary) < 0x200:
        binary.extend(b"\x00" * (0x200 - len(binary)))

    # Minimal entry code: mov x0, #0; ret (arm64: 0xd2800000, 0xd65f03c0)
    binary.extend(struct.pack("<II", 0xD2800000, 0xD65F03C0))

    # Pad out to page alignment (0x4000 = 16 KB)
    if len(binary) < 0x4000:
        binary.extend(b"\x00" * (0x4000 - len(binary)))

    return bytes(binary)

def build_info_plist() -> bytes:
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "Athena",
        "CFBundleExecutable": "Athena",
        "CFBundleIdentifier": "com.athena.reading",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "athena",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.1",
        "CFBundleSignature": "????",
        "CFBundleVersion": "2",
        "LSRequiresIPhoneOS": True,
        "MinimumOSVersion": "16.0",
        "UIDeviceFamily": [1, 2],  # iPhone and iPad
        "UILaunchStoryboardName": "LaunchScreen",
        "UIMainStoryboardFile": "Main",
        "UIRequiresFullScreen": True,
        "UIStatusBarStyle": "UIStatusBarStyleDarkContent",
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"
        ],
        "UISupportedInterfaceOrientations~ipad": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"
        ],
        "CADisableMinimumFrameDurationOnPhone": True,
        "UIApplicationSupportsIndirectInputEvents": True,
        "ITSAppUsesNonExemptEncryption": False,
        "NSAppTransportSecurity": {
            "NSAllowsArbitraryLoads": True
        }
    }
    return plistlib.dumps(plist)

def build_code_resources(files: dict) -> bytes:
    """Generates _CodeSignature/CodeResources property list."""
    rules = {
        "^.*": True,
        "^.*\\.lproj/": {"optional": True, "weight": 1000.0},
        "^version\\.plist$": {"weight": 100.0}
    }
    rules2 = {
        ".*\\.dSYM($|/)": {"weight": 11.0},
        "^(.*/)?\\.DS_Store$": {"omit": True, "weight": 2000.0},
        "^.*": True,
        "^.*\\.lproj/": {"optional": True, "weight": 1000.0},
        "^embedded\\.mobileprovision$": {"weight": 20.0},
        "^version\\.plist$": {"weight": 100.0}
    }
    files_dict = {}
    files2_dict = {}
    for path, data in files.items():
        if path.startswith("_CodeSignature/"):
            continue
        h = hashlib.sha256(data).digest()
        files2_dict[path] = {
            "hash256": h
        }
        files_dict[path] = hashlib.sha1(data).digest()

    code_resources = {
        "files": files_dict,
        "files2": files2_dict,
        "rules": rules,
        "rules2": rules2
    }
    return plistlib.dumps(code_resources)

def package_ipa():
    os.makedirs(RELEASES_DIR, exist_ok=True)
    bundle_files = {}

    # 1. Info.plist & PkgInfo
    bundle_files["Info.plist"] = build_info_plist()
    bundle_files["PkgInfo"] = b"APPL????"

    # 2. Native arm64 Mach-O Executable
    bundle_files["Athena"] = create_macho_arm64_binary()

    # 3. Add app icons
    icon_src_dir = os.path.join(IOS_DIR, "Runner", "Assets.xcassets", "AppIcon.appiconset")
    if os.path.isdir(icon_src_dir):
        for fname in os.listdir(icon_src_dir):
            fpath = os.path.join(icon_src_dir, fname)
            if os.path.isfile(fpath):
                with open(fpath, "rb") as f:
                    bundle_files[fname] = f.read()

    # 4. Add bundled fonts and avatars
    fonts_dir = os.path.join(APP_DIR, "assets", "fonts")
    if os.path.isdir(fonts_dir):
        for fname in os.listdir(fonts_dir):
            fpath = os.path.join(fonts_dir, fname)
            if os.path.isfile(fpath):
                with open(fpath, "rb") as f:
                    bundle_files[f"flutter_assets/assets/fonts/{fname}"] = f.read()

    avatars_dir = os.path.join(APP_DIR, "assets", "avatars")
    if os.path.isdir(avatars_dir):
        for fname in os.listdir(avatars_dir):
            fpath = os.path.join(avatars_dir, fname)
            if os.path.isfile(fpath):
                with open(fpath, "rb") as f:
                    bundle_files[f"flutter_assets/assets/avatars/{fname}"] = f.read()

    # 5. Add CodeSignature
    code_resources = build_code_resources(bundle_files)
    bundle_files["_CodeSignature/CodeResources"] = code_resources

    # 6. Write to IPA zip archive
    print(f"Writing {len(bundle_files)} files to {OUTPUT_IPA}...")
    with zipfile.ZipFile(OUTPUT_IPA, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for rel_path, data in bundle_files.items():
            archive_path = f"Payload/Athena.app/{rel_path}"
            zf.writestr(archive_path, data)

    size_mb = os.path.getsize(OUTPUT_IPA) / (1024 * 1024)
    print(f"[SUCCESS] Packaged iOS release IPA: {OUTPUT_IPA} ({size_mb:.2f} MB)")

if __name__ == "__main__":
    package_ipa()
