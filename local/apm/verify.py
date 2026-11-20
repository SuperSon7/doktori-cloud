import base64, json, secrets, time, urllib.request, urllib.parse
from datetime import datetime, timezone
from pathlib import Path
ROOT=Path(__file__).resolve().parent
TRACE=secrets.token_hex(16); PARENT=secrets.token_hex(8)
def get(url,headers=None):
    with urllib.request.urlopen(urllib.request.Request(url,headers=headers or {}), timeout=8) as r:
        return json.load(r)
def poll(fn, seconds=50):
    end=time.monotonic()+seconds; error=None
    while time.monotonic()<end:
        try:
            result=fn()
            if result: return result
        except Exception as e: error=repr(e)
        time.sleep(1)
    raise AssertionError(f"Timed out: {error}")
def spans(doc):
    out=[]
    for batch in doc.get("batches",doc.get("resourceSpans",[])):
        for scope in batch.get("scopeSpans",batch.get("instrumentationLibrarySpans",[])):
            out.extend(scope.get("spans",[]))
    return out
def ident(value):
    if len(value) in (16,32) and all(c in '0123456789abcdef' for c in value): return value
    return base64.b64decode(value).hex()
def attrs(span): return {a['key']:next(iter(a['value'].values())) for a in span.get('attributes',[])}
poll(lambda:get("http://127.0.0.1:18090/api/actuator/health").get('status')=='UP')
response=get("http://127.0.0.1:18090/api/policies/reading-genres",{'traceparent':f'00-{TRACE}-{PARENT}-01'})
assert response['message']=='OK'
assert [r['code'] for r in response['data']]==['APM_FIRST','APM_SECOND'], response
trace=poll(lambda: get(f"http://127.0.0.1:13200/api/traces/{TRACE}",{'Accept':'application/json'}))
ss=spans(trace)
server=[s for s in ss if s.get('kind') in ('SPAN_KIND_SERVER',2)]
db=[s for s in ss if attrs(s).get('db.system')=='mysql' or attrs(s).get('db.system.name')=='mysql']
assert len(server)==1 and db,[(s['name'],attrs(s)) for s in ss]
assert ident(server[0]['parentSpanId'])==PARENT
assert all(ident(s['traceId'])==TRACE for s in ss)
by_id={ident(s['spanId']):s for s in ss}
for s in db:
    parent=ident(s['parentSpanId']); visited=set()
    while parent!=ident(server[0]['spanId']):
        assert parent in by_id and parent not in visited, 'DB span not descended from HTTP server'
        visited.add(parent);parent=ident(by_id[parent]['parentSpanId'])
query='{service_name="doktori-api-pilot"} |= "trace_id='+TRACE+'" |= "request_complete"'
logs=poll(lambda:get('http://127.0.0.1:13101/loki/api/v1/query_range?'+urllib.parse.urlencode({'query':query,'limit':20}))['data']['result'])
assert any('status=200' in line for stream in logs for _,line in stream['values'])
env=dict(line.split('=',1) for line in (ROOT/'.runtime/.env').read_text().splitlines())
auth='Basic '+base64.b64encode(('lab:'+env['GRAFANA_PASSWORD']).encode()).decode()
proxied=get(f'http://127.0.0.1:13001/api/datasources/proxy/uid/apm-tempo/api/traces/{TRACE}',{'Authorization':auth,'Accept':'application/json'})
assert spans(proxied)
proxied_logs=get('http://127.0.0.1:13001/api/datasources/proxy/uid/apm-loki/loki/api/v1/query_range?'+urllib.parse.urlencode({'query':query,'limit':20}),{'Authorization':auth})
assert proxied_logs['data']['result']
report=dict(verified_at=datetime.now(timezone.utc).isoformat(),trace_id=TRACE,request='GET /api/policies/reading-genres',response=response,http_server_spans=len(server),mysql_spans=len(db),span_names=[s['name'] for s in ss],db_descendant_of_http=True,w3c_parent_preserved=True,log_correlation=True,grafana_trace_and_log_queries_passed=True,scope='real source slice; isolated MySQL fixture; not full API runtime',cloud_deployed=False)
out=ROOT/'reports';out.mkdir(exist_ok=True)
(out/'verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(out/'trace.json').write_text(json.dumps(trace,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
