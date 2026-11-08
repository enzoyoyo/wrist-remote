#!/usr/bin/env python3
"""Read signed installation metadata without copying app data or credentials."""

import argparse
import plistlib
import subprocess
import sys


def matches_identity(apps, bundle_id, team_id):
    if not isinstance(apps, list) or len(apps) != 1:
        return False
    app = apps[0]
    if not isinstance(app, dict):
        return False
    entitlements = app.get("Entitlements")
    return (
        app.get("CFBundleIdentifier") == bundle_id
        and isinstance(entitlements, dict)
        and entitlements.get("application-identifier") == f"{team_id}.{bundle_id}"
        and entitlements.get("com.apple.developer.team-identifier") == team_id
    )


def read_installed_apps(udid, bundle_id):
    arguments = ["-u", udid, "list", "-b", bundle_id,
                 "--xml", "-a", "CFBundleIdentifier", "-a", "Entitlements"]
    try:
        result = subprocess.run(
            ["ideviceinstaller", *arguments], capture_output=True, check=True, timeout=30,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        # A device discovered by CoreDevice can be available only over Wi-Fi.
        # Keep the exact UDID and identity requirements on that transport.
        result = subprocess.run(
            ["ideviceinstaller", "--network", *arguments],
            capture_output=True, check=True, timeout=30,
        )
    return plistlib.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--team", required=True)
    args = parser.parse_args()
    try:
        apps = read_installed_apps(args.udid, args.bundle)
        valid = matches_identity(apps, args.bundle, args.team)
    except (OSError, subprocess.SubprocessError, plistlib.InvalidFileException, ValueError):
        valid = False
    if not valid:
        print("Installed iPhone signing identity could not be verified; stopped.", file=sys.stderr)
        return 1
    print("Installed iPhone bundle and signed Team identity verified read-only.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
