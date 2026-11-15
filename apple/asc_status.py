#!/usr/bin/env python3
"""Report TestFlight state for the app: recent builds, processing state, missing compliance, and internal groups.
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (same as asc_prepare.py). Pass --fix to add every processed build
to all internal beta groups (creating a default "Internal" group if none exists)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_prepare as asc  # reuses jwt()/api()

APP_ID = os.environ.get("ASC_APP_ID", "6834190372")
fix = "--fix" in sys.argv

builds = asc.api("GET", f"/builds?filter[app]={APP_ID}&sort=-uploadedDate&limit=12&fields[builds]=version,uploadedDate,processingState,expired,usesNonExemptEncryption,buildAudienceType&include=preReleaseVersion").get("data", [])
pre = {p["id"]: p["attributes"] for p in asc.api("GET", f"/preReleaseVersions?filter[app]={APP_ID}&limit=50").get("data", [])}
print(f"--- TestFlight builds for app {APP_ID} ({len(builds)} most recent)")
if not builds: print("  (none — uploads have not been accepted by App Store Connect)")
for b in builds:
    a = b["attributes"]; pv = b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}
    plat = pre.get(pv.get("id"), {}).get("platform", "?"); mv = pre.get(pv.get("id"), {}).get("version", "?")
    enc = a.get("usesNonExemptEncryption")
    flag = " MISSING-COMPLIANCE" if enc is None else ""
    print(f"  {plat:6} {mv} ({a['version']})  {a['processingState']:11} uploaded {a['uploadedDate'][:16]}{' expired' if a.get('expired') else ''}{flag}")

groups = asc.api("GET", f"/betaGroups?filter[app]={APP_ID}&fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds").get("data", [])
print(f"--- beta groups: {len(groups)}")
for g in groups:
    ga = g["attributes"]; testers = asc.api("GET", f"/betaGroups/{g['id']}/betaTesters?limit=50&fields[betaTesters]=email").get("data", [])
    print(f"  {ga['name']} (internal={ga['isInternalGroup']}, allBuilds={ga.get('hasAccessToAllBuilds')}) testers: {', '.join(t['attributes'].get('email') or '?' for t in testers) or 'none'}")

if fix:
    internal = [g for g in groups if g["attributes"]["isInternalGroup"]]
    if not internal:
        g = asc.api("POST", "/betaGroups", {"data": {"type": "betaGroups", "attributes": {"name": "Internal", "isInternalGroup": True, "hasAccessToAllBuilds": True},
                                               "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})["data"]
        internal = [g]; print(f"  created internal group 'Internal' (all builds) {g['id']}")
    for g in internal:
        if g["attributes"].get("hasAccessToAllBuilds"): continue
        ids = [{"type": "builds", "id": b["id"]} for b in builds if b["attributes"]["processingState"] == "VALID"]
        if ids:
            asc.api("POST", f"/betaGroups/{g['id']}/relationships/builds", {"data": ids}); print(f"  added {len(ids)} builds to group {g['attributes']['name']}")
    # Internal groups need testers who are team members with the Developer/App Manager/Admin role.
    users = asc.api("GET", "/users?limit=50&fields[users]=username,roles").get("data", [])
    print("  team members eligible as internal testers: " + ", ".join(u["attributes"]["username"] for u in users))
