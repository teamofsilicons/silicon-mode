"""Careful Namecheap zone editing for teamofsilicons.com (setHosts replaces the whole zone).

Unlike `namecheap dns add`, this keeps the zone's EmailType (MX records only survive setHosts when
EmailType=MX) and refuses to write if anything it can't round-trip is present (inactive/DDNS hosts).
Credentials come from ~/.config/namecheap-cli/config.json and are never printed.

usage:
  python3 -I scripts/namecheap-zone.py snapshot <out.xml>              raw getHosts XML (records + EmailType)
  python3 -I scripts/namecheap-zone.py show <snapshot.xml>             summary of a snapshot
  python3 -I scripts/namecheap-zone.py add <snapshot.xml> TYPE NAME VALUE TTL [TYPE NAME VALUE TTL ...]
        re-reads the live zone, checks it still equals <snapshot.xml>, then setHosts(live + new)
  python3 -I scripts/namecheap-zone.py restore <snapshot.xml>          setHosts exactly from the snapshot
  python3 -I scripts/namecheap-zone.py diff <a.xml> <b.xml>            record-level diff (+ EmailType)
"""
import json, os, sys, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

DOMAIN_SLD, DOMAIN_TLD = "teamofsilicons", "com"
URL = "https://api.namecheap.com/xml.response"
NS = "{http://api.namecheap.com/xml.response}"

cfg = json.load(open(os.path.expanduser("~/.config/namecheap-cli/config.json")))
creds = cfg["credentials"]
if cfg.get("sandbox"):
    sys.exit("refusing: CLI config is in sandbox mode")


def call(command, params, post=False):
    q = {"ApiUser": creds["apiUser"], "ApiKey": creds["apiKey"], "UserName": creds["userName"],
         "ClientIp": creds["clientIp"], "Command": command, **params}
    data = urllib.parse.urlencode(q).encode()
    if post:
        req = urllib.request.Request(URL, data=data, method="POST", headers={"Content-Type": "application/x-www-form-urlencoded"})
    else:
        req = urllib.request.Request(URL + "?" + data.decode(), method="GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        xml = r.read().decode()
    root = ET.fromstring(xml)
    if root.get("Status") != "OK":
        errs = [e.text for e in root.iter(NS + "Error")]
        raise SystemExit(f"{command} failed: {errs}")
    return xml, root


def parse(xml):
    root = ET.fromstring(xml)
    res = next(root.iter(NS + "DomainDNSGetHostsResult"))
    hosts = []
    for h in res.iter(NS + "host"):
        hosts.append({k: h.get(k) for k in ("HostId", "Name", "Type", "Address", "MXPref", "TTL", "IsActive", "IsDDNSEnabled")})
    return {"EmailType": res.get("EmailType"), "IsUsingOurDNS": res.get("IsUsingOurDNS"), "hosts": hosts}


def key(h):
    return (h["Name"], h["Type"], h["Address"], h["MXPref"] if h["Type"] == "MX" else None, h["TTL"])


def snapshot():
    xml, _ = call("namecheap.domains.dns.getHosts", {"SLD": DOMAIN_SLD, "TLD": DOMAIN_TLD})
    return xml


def summary(z):
    from collections import Counter
    c = Counter(h["Type"] for h in z["hosts"])
    inactive = [h["Name"] for h in z["hosts"] if h["IsActive"] != "true"]
    ddns = [h["Name"] for h in z["hosts"] if h["IsDDNSEnabled"] == "true"]
    return f"{len(z['hosts'])} records {dict(c)} EmailType={z['EmailType']} OurDNS={z['IsUsingOurDNS']} inactive={inactive} ddns={ddns}"


def set_hosts(z, extra):
    if any(h["IsActive"] != "true" or h["IsDDNSEnabled"] == "true" for h in z["hosts"]):
        sys.exit("refusing: zone has inactive or DDNS hosts that setHosts can't preserve")
    params = {"SLD": DOMAIN_SLD, "TLD": DOMAIN_TLD}
    if z["EmailType"]:
        params["EmailType"] = z["EmailType"]
    rows = [(h["Name"], h["Type"], h["Address"], h["MXPref"], h["TTL"]) for h in z["hosts"]] + extra
    for i, (name, typ, addr, mx, ttl) in enumerate(rows, 1):
        params[f"HostName{i}"] = name
        params[f"RecordType{i}"] = typ
        params[f"Address{i}"] = addr
        params[f"TTL{i}"] = ttl or "1800"
        if typ == "MX":
            params[f"MXPref{i}"] = mx or "10"
    _, root = call("namecheap.domains.dns.setHosts", params, post=True)
    r = next(root.iter(NS + "DomainDNSSetHostsResult"))
    print("setHosts:", r.get("IsSuccess"), f"({len(rows)} records, EmailType={params.get('EmailType')})")


cmd = sys.argv[1]
if cmd == "snapshot":
    xml = snapshot()
    open(sys.argv[2], "w").write(xml)
    print("saved;", summary(parse(xml)))
elif cmd == "show":
    print(summary(parse(open(sys.argv[2]).read())))
elif cmd == "diff":
    a, b = parse(open(sys.argv[2]).read()), parse(open(sys.argv[3]).read())
    ka, kb = {key(h) for h in a["hosts"]}, {key(h) for h in b["hosts"]}
    for k in sorted(ka - kb, key=str):
        print("-", k)
    for k in sorted(kb - ka, key=str):
        print("+", k)
    print("EmailType:", a["EmailType"], "->", b["EmailType"], "| records:", len(a["hosts"]), "->", len(b["hosts"]))
elif cmd == "add":
    snap = parse(open(sys.argv[2]).read())
    live = parse(snapshot())
    if {key(h) for h in live["hosts"]} != {key(h) for h in snap["hosts"]} or live["EmailType"] != snap["EmailType"]:
        sys.exit("refusing: live zone changed since the snapshot; take a new snapshot first")
    rest = sys.argv[3:]
    if len(rest) % 4:
        sys.exit("records are TYPE NAME VALUE TTL")
    extra = [(rest[i + 1], rest[i], rest[i + 2], None, rest[i + 3]) for i in range(0, len(rest), 4)]
    existing = {(h["Name"], h["Type"]) for h in live["hosts"]}
    for name, typ, *_ in extra:
        if typ in ("A", "CNAME") and ((name, "A") in existing or (name, "CNAME") in existing):
            sys.exit(f"refusing: {name} already has an A/CNAME record")
    set_hosts(live, extra)
elif cmd == "restore":
    set_hosts(parse(open(sys.argv[2]).read()), [])
else:
    sys.exit(__doc__)
