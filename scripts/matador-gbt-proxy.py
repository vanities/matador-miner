#!/usr/bin/env python3
"""matador-gbt-proxy - least-privilege getblocktemplate proxy for a solo fleet (phase 2).

Lets a fleet of disposable matador-miner workers solo-mine through ONE coordinator node
without each running a full node or holding the node's RPC credentials. It impersonates a
btxd JSON-RPC endpoint but only allows the two mining methods (getblocktemplate,
submitblock), forwarding them to the real btxd; every other RPC method is refused.

Workers need ZERO code change - matador's solo RPC client already does HTTP JSON-RPC with
basic auth, so a worker just points at the proxy:

    matador-miner --mode solo \
      --rpcconnect coordinator.lan --rpcport 4071 \
      --rpcuser <rig-label> --rpcpassword <FLEET_TOKEN> \
      --payoutaddress <fleet-wallet>     # one shared wallet; per-rig coinbase extranonce
                                         # keeps their work disjoint (see --worker)

The proxy authenticates workers by the basic-auth PASSWORD == the fleet token (the
username is free-form and used only as a log label / which rig is pulling work). It forwards
to btxd using the node's own cookie or rpcuser/rpcpassword.

SECURITY: bind to LAN/VPN only (default 127.0.0.1; set --listen 10.x / 0.0.0.0 behind a
firewall). It exposes ONLY getblocktemplate + submitblock - never the wallet/stop/etc RPCs.

Run on the coordinator (same host as btxd, or one that can reach its RPC):

    python3 matador-gbt-proxy.py --listen 0.0.0.0 --port 4071 \
      --node-url http://127.0.0.1:19334/ --node-cookie ~/.btx/.cookie \
      --token "$FLEET_TOKEN"

No third-party deps (stdlib only; also runs under `uv run python matador-gbt-proxy.py`).
"""
import argparse
import base64
import hmac
import json
import logging
import os
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("gbt-proxy")

# The ONLY methods a mining worker needs - and the only ones we ever forward.
ALLOWED_METHODS = {"getblocktemplate", "submitblock"}


def read_node_auth(args):
    """Return the 'user:pass' the proxy uses to talk to the real btxd."""
    if args.node_cookie:
        with open(os.path.expanduser(args.node_cookie)) as f:
            return f.read().strip()           # btxd cookie is literally "__cookie__:<pw>"
    if args.node_rpcuser:
        return f"{args.node_rpcuser}:{args.node_rpcpassword or ''}"
    raise SystemExit("need --node-cookie or --node-rpcuser/--node-rpcpassword for btxd auth")


class Proxy:
    def __init__(self, args, token, node_auth):
        self.node_url = args.node_url
        self.node_auth_header = "Basic " + base64.b64encode(node_auth.encode()).decode()
        self.token = token
        self.timeout = args.timeout_s
        self._lock = threading.Lock()
        self.stats = {"gbt": 0, "submit": 0, "rejected_method": 0, "rejected_auth": 0, "node_errors": 0}

    def bump(self, k):
        with self._lock:
            self.stats[k] += 1

    def check_auth(self, header):
        """basic-auth password must equal the fleet token (constant-time). Returns label or None."""
        if not header or not header.startswith("Basic "):
            return None
        try:
            user, _, pw = base64.b64decode(header[6:]).decode().partition(":")
        except Exception:
            return None
        if not hmac.compare_digest(pw, self.token):
            return None
        return user or "worker"

    def forward(self, raw_body):
        """POST the (already method-checked) JSON-RPC body to the real btxd, return (status, bytes)."""
        req = urllib.request.Request(self.node_url, data=raw_body, method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Authorization": self.node_auth_header})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            # btxd returns JSON-RPC errors (e.g. height not ready) as non-2xx with a JSON body.
            return e.code, e.read()
        except Exception as e:
            self.bump("node_errors")
            log.error("[forward] btxd unreachable: %s", e)
            body = json.dumps({"result": None, "error": {"code": -1, "message": f"proxy: node unreachable: {e}"}, "id": None})
            return 502, body.encode()


def make_handler(proxy):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def _send(self, code, body, ctype="application/json"):
            if isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _rpc_error(self, code, http, rpc_code, msg, rpc_id=None):
            self._send(http, json.dumps({"result": None, "error": {"code": rpc_code, "message": msg}, "id": rpc_id}))

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/health":
                return self._send(200, '{"status":"ok"}')
            if path == "/stats":
                with proxy._lock:
                    return self._send(200, json.dumps(proxy.stats))
            return self._send(404, '{"error":"not_found"}')

        def do_POST(self):
            t0 = time.perf_counter()
            label = proxy.check_auth(self.headers.get("Authorization"))
            if label is None:
                proxy.bump("rejected_auth")
                log.warning("[auth] rejected from %s", self.client_address[0])
                # 401 with WWW-Authenticate so a basic-auth client knows creds are required.
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="matador-gbt-proxy"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b""
            try:
                rpc = json.loads(raw or b"{}")
                method = rpc.get("method", "")
                rpc_id = rpc.get("id")
            except Exception:
                return self._rpc_error("bad", 400, -32700, "parse error")
            if method not in ALLOWED_METHODS:
                proxy.bump("rejected_method")
                log.warning("[deny] worker=%s method=%s (only %s allowed)", label, method, sorted(ALLOWED_METHODS))
                return self._rpc_error("denied", 403, -32601,
                                       f"method '{method}' not permitted by gbt-proxy", rpc_id)
            proxy.bump("gbt" if method == "getblocktemplate" else "submit")
            status, body = proxy.forward(raw)
            self._send(status, body)
            log.debug("[ok] worker=%s method=%s status=%d in %.0fms",
                      label, method, status, (time.perf_counter() - t0) * 1000)
    return H


def main():
    ap = argparse.ArgumentParser(description="matador-gbt-proxy: least-privilege GBT/submitblock proxy")
    ap.add_argument("--listen", default="127.0.0.1", help="bind addr (LAN/VPN only; e.g. 0.0.0.0 behind a firewall)")
    ap.add_argument("--port", type=int, default=4071)
    ap.add_argument("--node-url", default="http://127.0.0.1:19334/", help="real btxd JSON-RPC URL")
    ap.add_argument("--node-cookie", help="path to btxd .cookie (preferred); e.g. ~/.btx/.cookie")
    ap.add_argument("--node-rpcuser")
    ap.add_argument("--node-rpcpassword")
    ap.add_argument("--token", help="fleet token workers present as the basic-auth password (or env MATADOR_FLEET_TOKEN)")
    ap.add_argument("--token-file", help="read the fleet token from this file")
    ap.add_argument("--timeout-s", type=float, default=20.0)
    args = ap.parse_args()

    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper(),
                        format="%(asctime)s %(levelname)s %(message)s")

    token = args.token or os.environ.get("MATADOR_FLEET_TOKEN", "")
    if args.token_file:
        with open(os.path.expanduser(args.token_file)) as f:
            token = f.read().strip()
    if not token:
        ap.error("no fleet token (use --token, --token-file, or env MATADOR_FLEET_TOKEN)")

    node_auth = read_node_auth(args)
    proxy = Proxy(args, token, node_auth)

    if args.listen in ("0.0.0.0", "::"):
        log.warning("[proxy] binding %s - ensure this is firewalled to your LAN/VPN; the token is the only gate", args.listen)
    srv = ThreadingHTTPServer((args.listen, args.port), make_handler(proxy))
    log.info("[proxy] listening http://%s:%d -> node %s  (allow=%s)  endpoints=POST / ,GET /health,/stats",
             args.listen, args.port, args.node_url, ",".join(sorted(ALLOWED_METHODS)))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
