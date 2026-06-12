#!/usr/bin/env bash
# Move/inspect the on-device client over the runtime MCP (adb forward 8790->8788).
~/Android/Sdk/platform-tools/adb forward tcp:8790 tcp:8788 >/dev/null 2>&1
python3 - "$@" <<'PY'
import json, urllib.request, sys
def rs(src,t=5):
    b=json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_script","arguments":{"source":src}}}).encode()
    r=urllib.request.Request("http://127.0.0.1:8790/mcp",b,{"Content-Type":"application/json","Accept":"text/event-stream"})
    raw=urllib.request.urlopen(r,timeout=t).read().decode()
    for l in raw.splitlines():
        if l.startswith("data: "):
            try: return json.loads(json.loads(l[6:])["result"]["content"][0]["text"])["value"]
            except: return l[6:][:120]
print(rs('return {"id":root.my_id, "phase":root.phase}'))
if len(sys.argv)>2:
    print("moved:", rs(f'root.avatar.position = Vector3({sys.argv[1]},0,{sys.argv[2]}); return [root.avatar.position.x, root.avatar.position.z]'))
PY
