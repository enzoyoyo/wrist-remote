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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--team", required=True)
    args = parser.parse_args()
    try:
        result = subprocess.run(
            ["ideviceinstaller", "-u", args.udid, "list", "-b", args.bundle,
             "--xml", "-a", "CFBundleIdentifier", "-a", "Entitlements"],
            capture_output=True, check=True, timeout=30,
        )
        apps = plistlib.loads(result.stdout)
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
