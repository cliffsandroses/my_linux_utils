#!/usr/bin/env python3
"""Your PSN Account ID for chiaki-ng (Remote Play), as the 8-byte base64 value its registration wants.

Uses the npsso cookie of a normal PlayStation sign-in, so Sony's Remote Play login page (the one that says
"Something went wrong") isn't needed:
  1. Sign in at https://www.playstation.com in your browser.
  2. Open https://ca.account.sony.com/api/v1/ssocookie and copy the npsso value (64 characters).
  3. Run this and paste it. It is a sign-in token: it is never saved, printed or sent anywhere but Sony.

Same flow as the open-source PSNAWP and psn-api libraries. Standard library only.
    psn-account-id.py              # asks for the npsso
    psn-account-id.py --test       # self-check of the encoding, no network
"""
import base64, getpass, json, sys, urllib.error, urllib.parse, urllib.request

CLIENT_ID = "09515159-7237-4370-9b40-3806e67c0891"          # the PlayStation app's public client id
BASIC = "MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A="
REDIRECT = "com.scee.psxandroid.scecompcall://redirect"
AUTHZ = "https://ca.account.sony.com/api/authz/v3/oauth/authorize"
TOKEN = "https://ca.account.sony.com/api/authz/v3/oauth/token"
ME = "https://dms.api.playstation.com/api/v1/devices/accounts/me"


def encode(account_id):
    """chiaki-ng's format: the 64-bit account number as 8 little-endian bytes, base64."""
    return base64.b64encode(int(account_id).to_bytes(8, "little")).decode()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def account_id(npsso):
    q = urllib.parse.urlencode({"access_type": "offline", "client_id": CLIENT_ID, "redirect_uri": REDIRECT,
                                "response_type": "code", "scope": "psn:mobile.v2.core psn:clientapp"})
    req = urllib.request.Request(f"{AUTHZ}?{q}", headers={"Cookie": f"npsso={npsso}"})
    try:
        urllib.request.build_opener(NoRedirect).open(req, timeout=20)
        raise SystemExit("Sony didn't hand back a sign-in code. Sign in at playstation.com again and copy a fresh npsso.")
    except urllib.error.HTTPError as e:
        loc = e.headers.get("Location", "")
    code = urllib.parse.parse_qs(urllib.parse.urlsplit(loc).query).get("code", [""])[0]
    if not code:
        raise SystemExit("That npsso didn't work (expired or mistyped). Sign in at playstation.com, open the ssocookie link again and copy the new value.")
    body = urllib.parse.urlencode({"code": code, "redirect_uri": REDIRECT, "grant_type": "authorization_code", "token_format": "jwt"}).encode()
    tok = json.load(urllib.request.urlopen(urllib.request.Request(TOKEN, data=body, headers={
        "Authorization": f"Basic {BASIC}", "Content-Type": "application/x-www-form-urlencoded"}), timeout=20))["access_token"]
    me = json.load(urllib.request.urlopen(urllib.request.Request(ME, headers={"Authorization": f"Bearer {tok}"}), timeout=20))
    return me["accountId"]


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        assert encode(1) == "AQAAAAAAAAA=" and len(base64.b64decode(encode(2**63 + 5))) == 8
        print("psn-account-id: ok"); sys.exit(0)
    npsso = getpass.getpass("npsso (from https://ca.account.sony.com/api/v1/ssocookie, hidden as you paste): ").strip().strip('"')
    if len(npsso) != 64:
        raise SystemExit(f"That's {len(npsso)} characters; the npsso is 64. Copy only the value between the quotes.")
    aid = account_id(npsso)
    print("\nYour PSN Account ID for chiaki-ng (paste this into the PSN Account ID box):\n")
    print("   ", encode(aid), "\n")
