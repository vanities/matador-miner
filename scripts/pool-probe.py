#!/usr/bin/env python3
# pool-probe.py - passively inspect a BTX stratum pool's job format WITHOUT mining.
# Connects, subscribes, authorizes, and prints the subscribe/authorize responses plus
# the first mining.notify: the job-object keys and whether parent_mtp / seed_a / seed_b
# are present. Use it to judge whether a pool conveys what a v3 solver needs (esp. the
# parent_mtp minebtx omits). Touches no GPU, submits nothing, so it never disturbs a
# running solo miner.
#   python3 scripts/pool-probe.py <host> <port> <btx-address>
import socket, json, time, sys

host = sys.argv[1] if len(sys.argv) > 1 else "stratum.bitminerpool.xyz"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 3333
addr = sys.argv[3] if len(sys.argv) > 3 else "btx1probe"

try:
    s = socket.create_connection((host, port), timeout=12)
except Exception as e:
    print("CONNECT FAILED:", e)
    sys.exit(1)
print("connected to %s:%d" % (host, port))

def send(d):
    s.sendall((json.dumps(d) + "\n").encode())

send({"id": 1, "method": "mining.subscribe", "params": ["pool-probe/1.0"]})
send({"id": 2, "method": "mining.authorize", "params": [addr + ".PROBE", "x"]})

buf = b""
t = time.time()
s.settimeout(3)
while time.time() - t < 18:
    try:
        data = s.recv(8192)
    except socket.timeout:
        continue
    except Exception:
        break
    if not data:
        break
    buf += data
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        try:
            j = json.loads(line)
        except Exception:
            print("RAW:", line.decode(errors="replace")[:200])
            continue
        m = j.get("method")
        if m == "mining.notify":
            p = j["params"]
            print("NOTIFY param-count =", len(p))
            obj = p[-1] if (p and isinstance(p[-1], dict)) else None
            if obj is not None:
                print("  job-object keys:", list(obj.keys()))
                for k in ["parent_mtp", "parent_median_time_past", "median_time_past",
                          "mtp", "seed_version", "seed_a", "seed_b"]:
                    if k in obj:
                        print("    %s = %s" % (k, obj[k]))
            else:
                print("  FLAT params (v2-style?):", [str(x)[:24] for x in p])
            s.close()
            sys.exit(0)
        elif m and m.startswith("mining.set"):
            print(m, "->", j.get("params"))
        elif "result" in j:
            print("id=%s result=%s error=%s" % (j.get("id"), str(j.get("result"))[:160], j.get("error")))
print("(no mining.notify within window)")
s.close()
