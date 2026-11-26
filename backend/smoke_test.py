import json, subprocess, urllib.request, uuid, os, sys, datetime
BASE="https://silicon-mode.cells.teamofsilicons.com"
KEY="cs_publishable_59pEz0JOT9tBU-XxYS_dmDkiY1yUxmhXjKpNP-gzdVk"
def call(method, path, body=None, token=None, headers=None):
    h={"apikey":KEY,"Content-Type":"application/json"}
    if token: h["Authorization"]="Bearer "+token
    h.update(headers or {})
    req=urllib.request.Request(BASE+path, method=method, data=json.dumps(body).encode() if body is not None else None, headers=h)
    try:
        with urllib.request.urlopen(req) as r: return r.status, json.loads(r.read() or b'null')
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:500]
slt=subprocess.check_output([os.path.expanduser("~/.apps/bin/silicon-accounts"),"login","--app","silicon-mode","-q"]).decode().strip()
st,s=call("POST","/auth/silicon",{"slt":slt,"app":"silicon-mode","cookie":False},headers={"Idempotency-Key":str(uuid.uuid4())})
print("auth/silicon", st, {k:('<r>' if 'token' in k else v) for k,v in s.items()} if isinstance(s,dict) else s)
tok=s["access_token"]
st,dev=call("POST","/rest/v1/rpc/register_device",{"p_install_id":"00000000-0000-4000-8000-000000000001","p_kind":"mac","p_name":"Smoke Test Mac","p_model":"MacBookPro18,1"},tok)
print("register_device", st, dev)
sid=str(uuid.uuid4()); qid=str(uuid.uuid4()); now=datetime.datetime.now(datetime.timezone.utc).isoformat()
batch={"device_id":dev,"app_version":"0.1.0","status":{"mode":"active","lid_angle":60,"silicon_angle":60,"agents_working":1,"agents_waiting":1,"questions_pending":1},
 "sessions":[{"id":sid,"provider":"claude_code","provider_session_id":"smoke","title":"Smoke test","project":"silicon-mode","state":"waiting","waiting_reason":"permission","last_event_at":now}],
 "events":[{"session_id":sid,"seq":1,"at":now,"kind":"tool_call","summary":"Bash: npm test"}],
 "questions":[{"id":qid,"session_id":sid,"kind":"permission","title":"Allow Bash: npm test?","options":[{"id":"allow","label":"Allow","role":"allow"},{"id":"deny","label":"Deny","role":"deny"}]}]}
st,r=call("POST","/rest/v1/rpc/push_batch",{"p":batch},tok); print("push_batch", st, r)
st,r=call("POST","/rest/v1/rpc/answer_question",{"p_question":qid,"p_option":"allow","p_from":"web"},tok); print("answer_question", st, r)
st,r=call("POST","/rest/v1/rpc/push_batch",{"p":{"device_id":dev}},tok); print("push_batch(answers)", st, r)
aid=r["answers"][0]["id"] if isinstance(r,dict) and r.get("answers") else None
st,r=call("POST","/rest/v1/rpc/push_batch",{"p":{"device_id":dev,"consumed":[{"id":aid,"outcome":"applied"}],"question_updates":[{"id":qid,"state":"answered"}]}},tok); print("consume", st, r)
st,r=call("GET","/rest/v1/devices?select=id,name,device_status(mode,agents_working)",None,tok); print("devices", st, r)
st,r=call("GET","/rest/v1/rpc/usage_heatmap?p_days=7",None,tok); print("heatmap", st, r)
# cleanup the smoke device
st,r=call("DELETE",f"/rest/v1/devices?id=eq.{dev}",None,tok); print("cleanup", st)
