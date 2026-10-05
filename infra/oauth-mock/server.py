#!/usr/bin/env python3
"""OAuth 2.0 token endpoint and a protected API, for TC67.

POST /token   password grant           -> access token "tok-1", refresh token "ref-1"
              refresh_token grant      -> access token "tok-2", refresh token "ref-2"
              client_credentials grant -> access token "tok-c1", then "tok-c2", "tok-c3", ... (no refresh token)
POST /api     accepts "Bearer tok-2" and "Bearer tok-cN" for N >= 2; rejects every other token with 401,
              so each sink has to replace its first token before its event gets through.
GET  /health  200

Token requests go to <state>/grants.log as "<client_id> <grant_type> <refresh_token or ->", and accepted
API bodies to <state>/received.log as "<authorization>\t<body>".

Usage: server.py <port> <state-dir>
"""
import base64
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

PORT = int(sys.argv[1])
STATE = sys.argv[2]
LOCK = threading.Lock()
CLIENT_GRANTS = [0]


def append(name, line):
    with LOCK, open(os.path.join(STATE, name), "a") as f:
        f.write(line + "\n")


def client_id(headers, form):
    auth = headers.get("Authorization", "")
    if auth.startswith("Basic "):
        return base64.b64decode(auth[6:]).decode().split(":", 1)[0]
    return form.get("client_id", "-")


def accepted(auth):
    m = re.fullmatch(r"Bearer tok-c(\d+)", auth)
    return auth == "Bearer tok-2" or (m is not None and int(m.group(1)) >= 2)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body, content_type="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200 if self.path == "/health" else 404, "ok", "text/plain")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path == "/token":
            form = {k: v[0] for k, v in parse_qs(body).items()}
            grant = form.get("grant_type", "")
            append("grants.log", "%s %s %s" % (client_id(self.headers, form), grant, form.get("refresh_token", "-")))
            if grant == "password":
                token = {"access_token": "tok-1", "refresh_token": "ref-1"}
            elif grant == "refresh_token":
                token = {"access_token": "tok-2", "refresh_token": "ref-2"}
            elif grant == "client_credentials":
                with LOCK:
                    CLIENT_GRANTS[0] += 1
                    token = {"access_token": "tok-c%d" % CLIENT_GRANTS[0]}
            else:
                self.reply(400, json.dumps({"error": "unsupported_grant_type"}))
                return
            self.reply(200, json.dumps(dict(token, token_type="Bearer", expires_in=3600, scope="default")))
        elif self.path == "/api":
            auth = self.headers.get("Authorization", "")
            if accepted(auth):
                append("received.log", "%s\t%s" % (auth, body))
                self.reply(200, "{}")
            else:
                self.reply(401, json.dumps({"error": "invalid_token"}))
        else:
            self.reply(404, "{}")


if __name__ == "__main__":
    os.makedirs(STATE, exist_ok=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
