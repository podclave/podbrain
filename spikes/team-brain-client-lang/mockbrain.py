#!/usr/bin/env python3
# Minimal stand-in for the gateway: just enough to validate client equivalence.
import json, re
from http.server import BaseHTTPRequestHandler, HTTPServer
MEM = {}  # id -> {content,type}
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def _send(self, obj, code=200):
        b=json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _auth(self):
        return self.headers.get("Authorization")=="Bearer testsecret"
    def do_GET(self):
        if not self._auth(): return self._send({"error":"unauth"},401)
        if self.path=="/agentmemory/health": return self._send({"status":"healthy","mock":True})
        m=re.match(r"/agentmemory/memories/(.+)",self.path)
        if m:
            i=m.group(1); return self._send(MEM.get(i,{}) and {"content":MEM[i]["content"],"id":i} or {})
        return self._send({},404)
    def do_POST(self):
        if not self._auth(): return self._send({"error":"unauth"},401)
        n=int(self.headers.get("Content-Length",0)); raw=self.rfile.read(n)
        if self.path=="/agentmemory/remember":
            d=json.loads(raw); i="m%d"%(len(MEM)+1); MEM[i]={"content":d["content"],"type":d.get("type","fact")}
            return self._send({"memory":{"id":i},"status":"saved"})
        if self.path=="/agentmemory/smart-search":
            d=json.loads(raw); q=d["query"].lower()
            hits=[{"obsId":i} for i,v in MEM.items() if any(w in v["content"].lower() for w in q.split())]
            return self._send({"results":hits})
        return self._send({},404)
HTTPServer(("127.0.0.1",8099),H).serve_forever()
