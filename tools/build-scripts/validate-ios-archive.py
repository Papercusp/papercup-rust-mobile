#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate a built Papercusp .xcarchive against the release contract (P-009).

`test -f Info.plist` proves an archive exists, not that it is the right
candidate. This checks what App Store Connect will judge, from the archive
itself rather than from project settings: the product identity, resolved
version strings, a device (not simulator) arm64 executable built with the
iOS 26+ SDK, the embedded privacy manifest, no Sentry framework, and (for
the TestFlight route) a signed bundle with an embedded profile. It writes a
candidate manifest that binds those facts to the exact source revision.

Pure Python (plistlib + Mach-O header parsing), so the fixture test runs on
Linux; CI runs it on the macOS archive.
"""
import argparse
import json
import plistlib
import re
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BUNDLE_ID = "com.papercuspai.operator.mobile"
CPU_TYPE_ARM64 = 0x0100000C
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF


class ArchiveError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ArchiveError(message)


def project_setting(key, project):
    match = re.search(rf'^\s+{key}:\s*"?([^"\n]+)"?\s*$', project, re.MULTILINE)
    require(match is not None, f"ios/project.yml has no {key}")
    return match.group(1).strip()


def load_plist(path):
    require(path.is_file(), f"missing {path}")
    with path.open("rb") as handle:
        return plistlib.load(handle)


def version_tuple(text):
    return (int(text >> 16), int((text >> 8) & 0xFF), int(text & 0xFF))


def arm64_slice(data):
    """Return the thin arm64 Mach-O bytes from a thin or fat executable."""
    require(len(data) >= 8, "executable is truncated")
    (magic,) = struct.unpack_from(">I", data, 0)
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        (count,) = struct.unpack_from(">I", data, 4)
        entry = ">iiQQI" if magic == FAT_MAGIC_64 else ">iiIII"
        step = struct.calcsize(entry)
        for index in range(count):
            cpu, _sub, offset, size, _align = struct.unpack_from(entry, data, 8 + index * step)
            if cpu & 0xFFFFFFFF == CPU_TYPE_ARM64:
                return data[offset:offset + size]
        raise ArchiveError("fat executable has no arm64 slice")
    return data


def build_version(macho):
    """(platform, minos, sdk) from the arm64 slice's LC_BUILD_VERSION."""
    require(len(macho) >= 32, "arm64 slice is truncated")
    magic, cputype, _sub, _ftype, ncmds, _size, _flags = struct.unpack_from("<IiiIIII", macho, 0)
    require(magic == MH_MAGIC_64, "executable is not a 64-bit Mach-O")
    require(cputype & 0xFFFFFFFF == CPU_TYPE_ARM64, "executable is not arm64")
    offset = 32
    for _ in range(ncmds):
        require(offset + 8 <= len(macho), "load commands run past the executable")
        cmd, cmdsize = struct.unpack_from("<II", macho, offset)
        require(cmdsize >= 8, "malformed load command")
        if cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from("<III", macho, offset + 8)
            return platform, version_tuple(minos), version_tuple(sdk)
        offset += cmdsize
    raise ArchiveError("executable has no LC_BUILD_VERSION")


def validate(args):
    project = (REPO_ROOT / "ios/project.yml").read_text() if args.project is None else Path(args.project).read_text()
    bundle_id = args.bundle_id
    require(f"PRODUCT_BUNDLE_IDENTIFIER: {bundle_id}\n" in project,
            f"ios/project.yml does not declare app bundle id {bundle_id}")
    version = args.version or project_setting("MARKETING_VERSION", project)
    min_os = project_setting("IPHONEOS_DEPLOYMENT_TARGET", project)
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_sha or "") is not None,
            "--source-sha must be the exact 40-hex candidate revision")

    archive = Path(args.archive)
    meta = load_plist(archive / "Info.plist")
    props = meta.get("ApplicationProperties") or {}
    app_rel = props.get("ApplicationPath")
    require(isinstance(app_rel, str) and app_rel.endswith(".app"),
            "archive Info.plist has no ApplicationProperties.ApplicationPath (not an app archive)")
    app = archive / "Products" / app_rel
    require(app.is_dir(), f"archived app bundle is missing: {app}")
    require(props.get("CFBundleIdentifier") == bundle_id,
            f"archive bundle id {props.get('CFBundleIdentifier')!r} != {bundle_id}")

    info = load_plist(app / "Info.plist")
    require(info.get("CFBundleIdentifier") == bundle_id,
            f"app bundle id {info.get('CFBundleIdentifier')!r} != {bundle_id}")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = info.get(key)
        require(isinstance(value, str) and "$(" not in value, f"{key} is unresolved: {value!r}")
    require(info["CFBundleShortVersionString"] == version,
            f"CFBundleShortVersionString {info['CFBundleShortVersionString']!r} != {version}")
    require(re.fullmatch(r"[1-9][0-9]*", info["CFBundleVersion"]) is not None,
            f"CFBundleVersion must be a positive integer build number: {info['CFBundleVersion']!r}")
    if args.build is not None:
        require(info["CFBundleVersion"] == str(args.build),
                f"CFBundleVersion {info['CFBundleVersion']!r} != requested build {args.build}")
    require(info.get("DTPlatformName") == "iphoneos",
            f"archive targets {info.get('DTPlatformName')!r}, not the iphoneos device platform")
    sdk_name = info.get("DTSDKName", "")
    require(sdk_name.startswith("iphoneos"), f"DTSDKName {sdk_name!r} is not an iphoneos SDK")
    plist_sdk_major = int(str(info.get("DTPlatformVersion", "0")).split(".")[0] or 0)
    require(plist_sdk_major >= args.min_sdk,
            f"built with iOS SDK {info.get('DTPlatformVersion')!r}; App Store requires {args.min_sdk}+")
    require(info.get("MinimumOSVersion") == min_os,
            f"MinimumOSVersion {info.get('MinimumOSVersion')!r} != deployment target {min_os}")

    executable = app / str(info.get("CFBundleExecutable", ""))
    require(info.get("CFBundleExecutable") and executable.is_file(), "app executable is missing")
    platform, minos, sdk = build_version(arm64_slice(executable.read_bytes()))
    require(platform == PLATFORM_IOS, f"executable platform {platform} is not iOS device ({PLATFORM_IOS})")
    require(sdk[0] >= args.min_sdk, f"executable links SDK {sdk}; App Store requires {args.min_sdk}+")

    privacy = load_plist(app / "PrivacyInfo.xcprivacy")
    require(privacy.get("NSPrivacyTracking") is False, "embedded privacy manifest must declare no tracking")
    frameworks = sorted(p.name for p in (app / "Frameworks").glob("*")) if (app / "Frameworks").is_dir() else []
    require(not any("sentry" in name.lower() for name in frameworks),
            f"release candidate embeds a Sentry framework: {frameworks}")

    signed = (app / "_CodeSignature" / "CodeResources").is_file()
    if args.require_signed:
        require(signed, "TestFlight archive is not code-signed")
        require((app / "embedded.mobileprovision").is_file(), "signed archive has no embedded profile")

    return {
        "sourceSha": args.source_sha,
        "archive": str(archive),
        "app": app_rel,
        "bundleId": bundle_id,
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "sdkName": sdk_name,
        "executableSdk": ".".join(map(str, sdk)),
        "executableMinOs": ".".join(map(str, minos)),
        "frameworks": frameworks,
        "signed": signed,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("archive")
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--version", help="expected marketing version (default: ios/project.yml)")
    parser.add_argument("--build", type=int, help="expected App Store build number")
    parser.add_argument("--min-sdk", type=int, default=26)
    parser.add_argument("--require-signed", action="store_true")
    parser.add_argument("--project", help=argparse.SUPPRESS)
    parser.add_argument("--manifest", help="write the candidate manifest JSON here")
    args = parser.parse_args(argv)
    try:
        manifest = validate(args)
    except (ArchiveError, OSError, ValueError, struct.error, plistlib.InvalidFileException) as error:
        print(f"ERROR: archive validation failed: {error}", file=sys.stderr)
        return 1
    text = json.dumps(manifest, indent=2, sort_keys=True)
    if args.manifest:
        Path(args.manifest).write_text(text + "\n")
    print(f"OK: archive {manifest['app']} {manifest['version']} ({manifest['build']}) "
          f"SDK {manifest['executableSdk']} at {manifest['sourceSha']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
