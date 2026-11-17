#!/usr/bin/env python3
"""Exit 0 if App Store Connect already has build number BUILD for PLATFORM (IOS or MAC_OS), else 1.
Usage: asc_has_build.py BUILD PLATFORM. Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (same as asc_prepare.py).
build.command uses it to skip an upload another machine already made for the same commit (same build number),
which App Store Connect would otherwise reject as a duplicate. Any API error counts as "not there" (exit 1)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_prepare as asc  # reuses jwt()/api()

APP_ID = os.environ.get("ASC_APP_ID", "6834190372")
build, platform = sys.argv[1], sys.argv[2]
try:
    r = asc.api("GET", f"/builds?filter[app]={APP_ID}&filter[version]={build}&include=preReleaseVersion&limit=10")
except SystemExit as e:
    print(f"asc_has_build: {e}"); sys.exit(1)
pre = {p["id"]: p["attributes"].get("platform") for p in r.get("included", []) if p.get("type") == "preReleaseVersions"}
for b in r.get("data", []):
    pv = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
    if pre.get(pv) == platform:
        sys.exit(0)
sys.exit(1)
