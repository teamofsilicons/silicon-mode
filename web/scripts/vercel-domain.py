"""Project-domain helper for the silicon-mode Vercel project. Never prints the token.
usage: python3 -I scripts/vercel-domain.py web/.vercel/project.json add|get|verify   (peek: compare with silicon-peek)"""
import json, os, sys, urllib.request, urllib.error

auth = os.path.expanduser("~/Library/Application Support/com.vercel.cli/auth.json")
tok = json.load(open(auth)).get("token")
proj = json.load(open(sys.argv[1]))
team, pid = proj["orgId"], proj["projectId"]
cmd = sys.argv[2]
DOMAIN = "mode.teamofsilicons.com"


def api(method, path, body=None):
    req = urllib.request.Request("https://api.vercel.com" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def show(st, d):
    keep = {k: d.get(k) for k in ("name", "verified", "verification", "error", "misconfigured", "configuredBy",
                                   "recommendedIPv4", "recommendedCNAME", "aValues", "cnames") if k in d}
    print(st, json.dumps(keep, indent=1))


if cmd == "peek":
    st, d = api("GET", f"/v9/projects/silicon-peek/domains?teamId={team}")
    print(st, [(x["name"], x.get("verified")) for x in d.get("domains", [])])
elif cmd == "add":
    show(*api("POST", f"/v10/projects/{pid}/domains?teamId={team}", {"name": DOMAIN}))
elif cmd == "get":
    show(*api("GET", f"/v9/projects/{pid}/domains/{DOMAIN}?teamId={team}"))
    show(*api("GET", f"/v6/domains/{DOMAIN}/config?teamId={team}"))
elif cmd == "verify":
    show(*api("POST", f"/v9/projects/{pid}/domains/{DOMAIN}/verify?teamId={team}"))
