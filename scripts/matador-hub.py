#!/usr/bin/env python3
"""matador-hub - fleet telemetry aggregator for matador-miner (phase 1).

Scrapes each worker's existing read-only /summary API and serves an aggregate fleet
view: total hashrate, per-rig status/util/power/temp/shares, online/offline, and the
auto-update state (which rigs are behind). Zero worker changes, zero protocol work -
each rig just needs `--api` enabled.

This is the coordinator-side "control plane" surface: the stateful, uptime-bearing
parts (archive node, chain) live on one box; every miner is a disposable solver that
exposes /summary, and the hub rolls them up.

Run on the coordinator host (bind LAN/VPN only - it aggregates rigs, do NOT expose it
publicly):

    python3 matador-hub.py --worker rig1=http://10.0.0.11:4060 \
                           --worker rig2=http://10.0.0.12:4060 --port 4070
    # or:  python3 matador-hub.py --config hub.json
    curl -s http://127.0.0.1:4070/fleet | python3 -m json.tool
    # dashboard: http://127.0.0.1:4070/

No third-party deps (stdlib only); also runs under `uv run python matador-hub.py`.
"""
import argparse
import json
import logging
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("hub")


def parse_worker(spec):
    """'label=url' or 'url' -> (label, url). Bare url derives a label from host:port."""
    if "=" in spec and not spec.split("=", 1)[0].startswith("http"):
        label, url = spec.split("=", 1)
    else:
        url, label = spec, ""
    url = url.rstrip("/")
    if not label:
        label = url.split("//", 1)[-1]  # host:port
    return label, url


class Fleet:
    """Polls each worker's /summary and keeps the latest snapshot + a computed rate."""

    def __init__(self, workers, poll_interval_s, timeout_s, offline_after_s):
        self.workers = workers                  # list of (label, url)
        self.poll_interval_s = poll_interval_s
        self.timeout_s = timeout_s
        self.offline_after_s = offline_after_s
        self._lock = threading.Lock()
        self._state = {label: {"label": label, "url": url, "online": False,
                               "last_ok_ms": 0, "summary": None, "nonce_per_s": 0.0,
                               "error": "not polled yet"}
                       for (label, url) in workers}
        self._prev = {}                          # label -> (batched_attempts, mono_ms)

    def _now_ms(self):
        return int(time.monotonic() * 1000)

    def _poll_one(self, label, url):
        t0 = time.perf_counter()
        try:
            req = urllib.request.Request(url + "/summary", headers={"User-Agent": "matador-hub"})
            with urllib.request.urlopen(req, timeout=self.timeout_s) as r:
                summary = json.loads(r.read().decode())
            ms = self._now_ms()
            # nonce/s from the delta of the live batched-attempt counter (same source
            # the miner's heartbeat uses); clamp resets/negatives to 0.
            attempts = int(summary.get("nonces", {}).get("batched_attempts", 0))
            rate = 0.0
            prev = self._prev.get(label)
            if prev is not None:
                d_att, d_ms = attempts - prev[0], ms - prev[1]
                if d_att > 0 and d_ms > 0:
                    rate = d_att * 1000.0 / d_ms
            self._prev[label] = (attempts, ms)
            with self._lock:
                self._state[label].update(online=True, last_ok_ms=ms, summary=summary,
                                           nonce_per_s=rate, error="")
            log.debug("[poll] %s ok ver=%s rate=%.0f n/s in %.0fms",
                      label, summary.get("version"), rate,
                      (time.perf_counter() - t0) * 1000)
        except Exception as e:  # unreachable rig, bad json, timeout - keep last summary
            with self._lock:
                st = self._state[label]
                age_ms = self._now_ms() - st["last_ok_ms"] if st["last_ok_ms"] else None
                if age_ms is None or age_ms > self.offline_after_s * 1000:
                    st["online"] = False
                st["error"] = str(e)
                st["nonce_per_s"] = 0.0
            log.warning("[poll] %s FAILED: %s", label, e)

    def poll_loop(self, stop):
        log.info("[hub] polling %d workers every %ss", len(self.workers), self.poll_interval_s)
        while not stop.is_set():
            for label, url in self.workers:
                if stop.is_set():
                    break
                self._poll_one(label, url)
            stop.wait(self.poll_interval_s)

    def snapshot(self):
        """Aggregate view: per-rig rows + fleet totals."""
        now = self._now_ms()
        rigs, totals = [], {
            "workers": len(self.workers), "online": 0, "offline": 0,
            "mining": 0, "gated": 0,
            "nonce_per_s": 0.0, "power_w": 0.0, "accepted": 0, "rejected": 0,
            "stale": 0, "behind": 0,
        }
        with self._lock:
            for label, _ in self.workers:
                st = self._state[label]
                s = st["summary"] or {}
                upd = s.get("update", {})
                gpu = s.get("gpu_runtime", []) or []
                power = sum(float(g.get("power_w", 0) or 0) for g in gpu)
                rate = st["nonce_per_s"] if st["online"] else 0.0
                shares = s.get("shares", {})
                current = upd.get("current", s.get("version", ""))
                latest = upd.get("latest_seen", "")
                behind = bool(latest and current and latest != current)
                mining_state = s.get("mining_state", "mining") if st["online"] else "offline"
                gated = st["online"] and mining_state == "gated"
                rigs.append({
                    "label": label, "url": st["url"], "online": st["online"],
                    "last_seen_age_s": (now - st["last_ok_ms"]) // 1000 if st["last_ok_ms"] else None,
                    "version": current, "latest_seen": latest, "behind": behind,
                    "channel": upd.get("channel", ""), "auto_update": upd.get("auto_update"),
                    "mode": s.get("mode", ""), "backend": s.get("backend", ""),
                    "mining_state": mining_state, "gate_reason": s.get("gate_reason", ""),
                    "uptime_sec": s.get("uptime_sec", 0), "nonce_per_s": round(rate),
                    "shares": shares, "thermal": (s.get("thermal", {}) or {}).get("status", ""),
                    "watchdog": (s.get("watchdog", {}) or {}).get("status", ""),
                    "power_w": round(power), "gpus": gpu, "error": st["error"],
                })
                if st["online"]:
                    totals["online"] += 1
                    totals["nonce_per_s"] += rate
                    totals["power_w"] += power
                    if gated:
                        totals["gated"] += 1
                    else:
                        totals["mining"] += 1
                else:
                    totals["offline"] += 1
                totals["accepted"] += int(shares.get("accepted", 0) or 0)
                totals["rejected"] += int(shares.get("rejected", 0) or 0)
                totals["stale"] += int(shares.get("stale", 0) or 0)
                if behind:
                    totals["behind"] += 1
        totals["nonce_per_s"] = round(totals["nonce_per_s"])
        totals["power_w"] = round(totals["power_w"])
        return {"totals": totals, "rigs": rigs}


def human_rate(n):
    n = float(n)
    for unit in ("", "K", "M", "G"):
        if abs(n) < 1000:
            return f"{n:.1f}{unit}N/s"
        n /= 1000
    return f"{n:.1f}TN/s"


def render_html(snap):
    t = snap["totals"]
    rows = []
    for r in snap["rigs"]:
        if not r["online"]:
            cls, state = "off", "DOWN"
        elif r["mining_state"] == "gated":
            cls, state = "gated", "GATED"
        elif r["behind"] or r["thermal"] in ("warning", "critical"):
            cls, state = "warn", "MINING"
        else:
            cls, state = "ok", "MINING"
        ver = r["version"] + (f' &rarr; {r["latest_seen"]}' if r["behind"] else "")
        # show the gate reason for gated rigs, else thermal status
        note = r["gate_reason"] if r["mining_state"] == "gated" and r["gate_reason"] else (r["thermal"] or "-")
        sh = r["shares"]
        rows.append(
            f'<tr class="{cls}"><td>{r["label"]}</td>'
            f'<td>{state}</td><td>{ver}</td>'
            f'<td>{r["mode"]}/{r["backend"]}</td>'
            f'<td class="num">{human_rate(r["nonce_per_s"])}</td>'
            f'<td class="num">{r["power_w"]}W</td>'
            f'<td class="num">{sh.get("accepted",0)}/{sh.get("rejected",0)}</td>'
            f'<td>{note}</td><td>{r["watchdog"] or "-"}</td>'
            f'<td class="num">{r["uptime_sec"]}s</td></tr>')
    return f"""<!doctype html><html><head><meta charset=utf-8>
<meta http-equiv=refresh content=5><title>matador fleet</title><style>
body{{font:14px ui-monospace,monospace;background:#0b0e14;color:#d6deeb;margin:1.2rem}}
h1{{font-size:1.1rem}} .sub{{color:#7a88a8}}
table{{border-collapse:collapse;width:100%;margin-top:.6rem}}
th,td{{padding:.35rem .6rem;border-bottom:1px solid #1c2433;text-align:left}}
th{{color:#7a88a8;font-weight:600}} .num{{text-align:right}}
tr.off td{{color:#6b7280}} tr.warn td:first-child{{color:#f0c674}}
tr.ok td:first-child{{color:#9ece6a}} tr.gated td:first-child{{color:#7aa2f7}}
.tot{{font-size:1.05rem;margin:.4rem 0}}
.tot b{{color:#9ece6a}} .behind b{{color:#f0c674}} .gate b{{color:#7aa2f7}}</style></head><body>
<h1>matador fleet <span class=sub>telemetry</span></h1>
<div class=tot>{t['online']}/{t['workers']} online &middot;
 <b>{t['mining']}</b> mining &middot; <span class=gate><b>{t['gated']}</b> gated</span> &middot;
 <b>{human_rate(t['nonce_per_s'])}</b> total &middot; {t['power_w']}W &middot;
 shares {t['accepted']}/{t['rejected']} (acc/rej)
 <span class=behind>&middot; <b>{t['behind']}</b> behind</span></div>
<table><tr><th>rig</th><th>state</th><th>version</th><th>mode/backend</th>
<th class=num>rate</th><th class=num>power</th><th class=num>acc/rej</th>
<th>thermal</th><th>watchdog</th><th class=num>uptime</th></tr>
{''.join(rows)}</table>
<p class=sub>auto-refresh 5s &middot; JSON: <a href=/fleet style=color:#7aa2f7>/fleet</a></p>
</body></html>"""


def make_handler(fleet):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def _send(self, code, body, ctype):
            if isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/health":
                return self._send(200, '{"status":"ok"}', "application/json")
            if path == "/fleet":
                return self._send(200, json.dumps(fleet.snapshot()), "application/json")
            if path in ("/", "/index.html"):
                return self._send(200, render_html(fleet.snapshot()), "text/html; charset=utf-8")
            return self._send(404, '{"error":"not_found"}', "application/json")
    return H


def load_config(path):
    with open(path) as f:
        cfg = json.load(f)
    workers = []
    for w in cfg.get("workers", []):
        if isinstance(w, str):
            workers.append(parse_worker(w))
        else:
            workers.append((w.get("label") or w["url"], w["url"].rstrip("/")))
    return cfg, workers


def main():
    ap = argparse.ArgumentParser(description="matador-hub fleet telemetry aggregator")
    ap.add_argument("--worker", action="append", default=[],
                    help="repeatable; 'label=http://host:port' or 'http://host:port'")
    ap.add_argument("--config", help="JSON config: {workers:[...], listen, port, poll_interval_s}")
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4070)
    ap.add_argument("--poll-interval-s", type=int, default=10)
    ap.add_argument("--timeout-s", type=float, default=4.0)
    ap.add_argument("--offline-after-s", type=int, default=30,
                    help="mark a rig offline after this long without a good poll")
    args = ap.parse_args()

    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper(),
                        format="%(asctime)s %(levelname)s %(message)s")

    cfg = {}
    workers = [parse_worker(w) for w in args.worker]
    if args.config:
        cfg, cfg_workers = load_config(args.config)
        workers = cfg_workers + workers
    listen = cfg.get("listen", args.listen)
    port = int(cfg.get("port", args.port))
    poll = int(cfg.get("poll_interval_s", args.poll_interval_s))
    if not workers:
        ap.error("no workers configured (use --worker or --config)")

    fleet = Fleet(workers, poll, args.timeout_s, args.offline_after_s)
    stop = threading.Event()
    poller = threading.Thread(target=fleet.poll_loop, args=(stop,), daemon=True)
    poller.start()

    srv = ThreadingHTTPServer((listen, port), make_handler(fleet))
    log.info("[hub] listening http://%s:%d  endpoints=/ /fleet /health  workers=%s",
             listen, port, ",".join(l for l, _ in workers))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        srv.shutdown()


if __name__ == "__main__":
    main()
