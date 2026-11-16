#!/usr/bin/env python3
"""Print recent crash reports into the build log so they can be read remotely.
1. TestFlight crash submissions from App Store Connect (needs ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH).
2. Local macOS crash reports for Schrodinger in ~/Library/Logs/DiagnosticReports.
Prints only the exception and the crashed thread's frames. Never fails the build."""
import glob, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
APP_ID = os.environ.get("ASC_APP_ID", "6834190372")
LIMIT = 3

def summarize_text(log):
    """Apple text crash log (TestFlight): exception lines + crashed thread block."""
    lines = log.splitlines(); out = []
    keys = ("Hardware Model", "OS Version", "Version:", "Exception Type", "Exception Codes", "Termination Reason", "Triggered by Thread",
            "Crashed Thread", "Application Specific Information", "Fatal error", "Assertion", "precondition")
    out += [l for l in lines if any(k in l for k in keys)][:14]
    for i, l in enumerate(lines):
        if "Crashed:" in l:
            block = lines[i:i + 30]
            out += [b for b in block if b.strip()][:30]
            break
    return "\n".join(out) or "\n".join(lines[:40])

def summarize_ips(path):
    """macOS .ips crash report: JSON header line + JSON body."""
    raw = open(path, errors="replace").read()
    head, _, body = raw.partition("\n")
    try: b = json.loads(body)
    except Exception: return raw[:3000]
    out = [f"time: {json.loads(head).get('timestamp', '?')}  app: {b.get('procName')} {b.get('bundleInfo', {}).get('CFBundleShortVersionString', '')} ({b.get('bundleInfo', {}).get('CFBundleVersion', '')})"]
    ex = b.get("exception", {}); out.append(f"exception: {ex.get('type')} {ex.get('signal', '')} {ex.get('subtype', '')}")
    for k in ("asi", "termination"):
        if k in b: out.append(f"{k}: {json.dumps(b[k])[:600]}")
    images = b.get("usedImages", [])
    for t in b.get("threads", []):
        if not t.get("triggered"): continue
        for f in t.get("frames", [])[:30]:
            img = images[f["imageIndex"]].get("name", "?") if f.get("imageIndex", -1) < len(images) else "?"
            out.append(f"  {img:28} {f.get('symbol', hex(f.get('imageOffset', 0)))}  {f.get('sourceFile', '')}:{f.get('sourceLine', '')}")
    return "\n".join(out)

print("--- crash reports")
try:
    import asc_prepare as asc
    subs = asc.api("GET", f"/apps/{APP_ID}/betaFeedbackCrashSubmissions?limit=10").get("data", [])
    subs.sort(key=lambda s: s["attributes"].get("createdDate", ""), reverse=True)
    print(f"TestFlight crash submissions: {len(subs)}")
    for s in subs[:LIMIT]:
        a = s["attributes"]
        print(f"== {a.get('createdDate', '?')[:19]}  {a.get('deviceModel', '?')} {a.get('osVersion', '?')}  build {a.get('appBuildVersion', '?')}  comment: {a.get('comment') or '-'}")
        try:
            log = asc.api("GET", f"/betaFeedbackCrashSubmissions/{s['id']}/crashLog").get("data", {}).get("attributes", {}).get("logText", "")
            print(summarize_text(log) if log else "(no crash log attached yet)")
        except BaseException as e: print(f"(crash log unavailable: {e})")
except BaseException as e:
    print(f"TestFlight crash submissions unavailable: {e}")

reports = sorted(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/Schrodinger*.ips")), key=os.path.getmtime, reverse=True)
print(f"macOS crash reports on this Mac: {len(reports)}")
for r in reports[:LIMIT]:
    print(f"== {os.path.basename(r)}")
    try: print(summarize_ips(r))
    except BaseException as e: print(f"(unreadable: {e})")
