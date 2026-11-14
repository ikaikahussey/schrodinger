#!/usr/bin/env python3
"""Prepare this Mac for App Store signing using an App Store Connect API key (no Xcode GUI needed).

- Registers this Mac's provisioning UDID as a device (needed for macOS development profiles).
- Ensures Apple Development, Apple Distribution and Mac Installer Distribution certificates exist in the
  login keychain; missing ones are created via the API from a locally generated key + CSR and imported.

Uses only python3 stdlib + the `openssl` and `security` CLIs. Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH.
"""
import base64, json, os, re, subprocess, sys, tempfile, time, urllib.request, urllib.error, urllib.parse

KEY_ID = os.environ["ASC_KEY_ID"]; ISSUER = os.environ["ASC_ISSUER_ID"]; KEY_PATH = os.path.expanduser(os.environ["ASC_KEY_PATH"])
API = "https://api.appstoreconnect.apple.com/v1"
WORK = os.path.expanduser("~/.appstoreconnect/signing"); os.makedirs(WORK, exist_ok=True); os.chmod(WORK, 0o700)

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def der_to_raw(sig):
    # DER ECDSA-Sig-Value -> 64-byte r||s
    assert sig[0] == 0x30; i = 2
    assert sig[i] == 0x02; l = sig[i+1]; r = sig[i+2:i+2+l]; i += 2 + l
    assert sig[i] == 0x02; l = sig[i+1]; s = sig[i+2:i+2+l]
    return r[-32:].rjust(32, b"\0") + s[-32:].rjust(32, b"\0")

def jwt():
    now = int(time.time())
    header = b64u(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    payload = b64u(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}).encode())
    signing = f"{header}.{payload}".encode()
    with tempfile.NamedTemporaryFile(delete=False) as f: f.write(signing); p = f.name
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY_PATH, p], capture_output=True, check=True).stdout
    os.unlink(p)
    return f"{header}.{payload}.{b64u(der_to_raw(der))}"

TOKEN = jwt()
def api(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        msg = e.read().decode(errors="replace")
        raise SystemExit(f"ASC API {method} {path} -> {e.code}: {msg[:600]}")

def sh(*cmd, check=True, **kw): return subprocess.run(cmd, capture_output=True, text=True, check=check, **kw)

# ---------- 1. Device registration (this Mac) ----------
def provisioning_udid():
    out = sh("system_profiler", "SPHardwareDataType").stdout
    m = re.search(r"Provisioning UDID:\s*([0-9A-Fa-f-]+)", out) or re.search(r"Hardware UUID:\s*([0-9A-Fa-f-]+)", out)
    return m.group(1) if m else None

def ensure_device():
    udid = provisioning_udid()
    if not udid: print("device: could not read UDID; skipping"); return
    devs = api("GET", "/devices?filter[platform]=MAC_OS&limit=200")["data"]
    if any(d["attributes"]["udid"].lower() == udid.lower() for d in devs): print(f"device: already registered ({udid})"); return
    name = sh("scutil", "--get", "ComputerName", check=False).stdout.strip() or "Mac"
    api("POST", "/devices", {"data": {"type": "devices", "attributes": {"name": name[:50], "platform": "MAC_OS", "udid": udid}}})
    print(f"device: registered {name} ({udid})")

# ---------- 2. Certificates ----------
WANT = {  # keychain identity name prefix -> ASC certificateType
    "Apple Development": "DEVELOPMENT",
    "Apple Distribution": "DISTRIBUTION",
    "3rd Party Mac Developer Installer": "MAC_INSTALLER_DISTRIBUTION",
}
def local_identities():
    out = sh("security", "find-identity", "-v", check=False).stdout
    return out

def ensure_cert(name, ctype):
    if name in local_identities(): print(f"cert: {name} present"); return
    key = os.path.join(WORK, f"{ctype}.key.pem"); csr = os.path.join(WORK, f"{ctype}.csr"); cer = os.path.join(WORK, f"{ctype}.cer")
    sh("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-subj", "/CN=Schrodinger build/O=Ikaika Hussey/C=US")
    os.chmod(key, 0o600)
    csr_pem = open(csr).read()
    # Keep PEM armor as the API expects a PEM CSR string
    try:
        data = api("POST", "/certificates", {"data": {"type": "certificates", "attributes": {"certificateType": ctype, "csrContent": csr_pem}}})
    except SystemExit as e:
        # Common: certificate limit reached → reuse is impossible without the private key; report clearly.
        print(f"cert: {name} could not be created: {e}"); return
    open(cer, "wb").write(base64.b64decode(data["data"]["attributes"]["certificateContent"]))
    sh("security", "import", key, "-k", os.path.expanduser("~/Library/Keychains/login.keychain-db"), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", "-T", "/usr/bin/productbuild", check=False)
    sh("security", "import", cer, "-k", os.path.expanduser("~/Library/Keychains/login.keychain-db"), "-T", "/usr/bin/codesign", "-T", "/usr/bin/productbuild", check=False)
    # Allow codesign to use the key without a UI prompt.
    sh("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", "", os.path.expanduser("~/Library/Keychains/login.keychain-db"), check=False)
    print(f"cert: {name} created and imported ({data['data']['id']})")

def ensure_wwdr():
    # Apple Worldwide Developer Relations intermediate (G3) must be present for the chain to validate.
    if sh("security", "find-certificate", "-c", "Apple Worldwide Developer Relations", check=False).returncode == 0: return
    try:
        p = os.path.join(WORK, "AppleWWDRCAG3.cer")
        urllib.request.urlretrieve("https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer", p)
        sh("security", "add-certificates", "-k", os.path.expanduser("~/Library/Keychains/login.keychain-db"), p, check=False)
        print("wwdr: installed intermediate")
    except Exception as e: print(f"wwdr: could not install intermediate: {e}")

# ---------- 3. App Store provisioning profiles (manual signing for export) ----------
BUNDLE_ID = os.environ.get("BUNDLE_ID", "org.schrodinger.app")
PROFILE_DIR = os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")

def local_cert_sha1(name):
    pem = sh("security", "find-certificate", "-c", name, "-p", check=False).stdout
    if "BEGIN CERTIFICATE" not in pem: return None
    import hashlib
    der = base64.b64decode("".join(l for l in pem.splitlines() if "CERTIFICATE" not in l))
    return hashlib.sha1(der).hexdigest().upper()

def api_cert_id(ctype, local_sha1):
    import hashlib
    for c in api("GET", f"/certificates?filter[certificateType]={ctype}&limit=200")["data"]:
        der = base64.b64decode(c["attributes"]["certificateContent"])
        if hashlib.sha1(der).hexdigest().upper() == local_sha1: return c["id"]
    return None

def ensure_profiles():
    bid = api("GET", f"/bundleIds?filter[identifier]={BUNDLE_ID}&limit=5")["data"]
    bid = next((b for b in bid if b["attributes"]["identifier"] == BUNDLE_ID), None)
    if not bid: print(f"profiles: bundle id {BUNDLE_ID} not found"); return {}
    sha = local_cert_sha1("Apple Distribution")
    cert = api_cert_id("DISTRIBUTION", sha) if sha else None
    if not cert: print("profiles: local Apple Distribution certificate not found in the team; cannot build profiles"); return {}
    os.makedirs(PROFILE_DIR, exist_ok=True)
    out = {}
    for ptype, name, ext in (("IOS_APP_STORE", "Schrodinger iOS App Store", "mobileprovision"), ("MAC_APP_STORE", "Schrodinger macOS App Store", "provisionprofile")):
        existing = [p for p in api("GET", f"/profiles?filter[name]={urllib.parse.quote(name)}&limit=10")["data"] if p["attributes"]["name"] == name]
        prof = None
        for p in existing:
            certs = api("GET", f"/profiles/{p['id']}/certificates")["data"]
            if p["attributes"]["profileState"] == "ACTIVE" and any(c["id"] == cert for c in certs): prof = p; break
            api("DELETE", f"/profiles/{p['id']}")
        if not prof:
            prof = api("POST", "/profiles", {"data": {"type": "profiles", "attributes": {"name": name, "profileType": ptype},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid["id"]}}, "certificates": {"data": [{"type": "certificates", "id": cert}]}}}})["data"]
            print(f"profiles: created {name}")
        else: print(f"profiles: reusing {name}")
        content = base64.b64decode(prof["attributes"]["profileContent"])
        path = os.path.join(PROFILE_DIR, f"{prof['attributes']['uuid']}.{ext}")
        open(path, "wb").write(content)
        out[ptype] = name
    return out

if __name__ == "__main__":
    ensure_device()
    ensure_wwdr()
    for n, t in WANT.items(): ensure_cert(n, t)
    print("identities:\n" + "\n".join(l for l in local_identities().splitlines() if "Apple" in l or "Mac Developer" in l))
    profiles = ensure_profiles()
    os.makedirs("build", exist_ok=True)
    with open("build/profiles.env", "w") as f:
        f.write(f"IOS_PROFILE={json.dumps(profiles.get('IOS_APP_STORE', ''))}\nMAC_PROFILE={json.dumps(profiles.get('MAC_APP_STORE', ''))}\n")
