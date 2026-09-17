#!/usr/bin/env python3
"""K1 speed probe: single-stream decode, cold prefill, 6-stream aggregate against any OpenAI-compatible endpoint..

  python3 bench/k1_speed.py <label> [base_url]

Single-stream decode (prose 400 tok x3), prefill (~2.3K-token prompt x3), and a 6-stream
concurrent decode aggregate. Thinking off, temperature 0, explicit chat_template_kwargs so the
server's default reasoning_effort does not leak into the comparison. Writes <label>-K1.json.
"""
import concurrent.futures as cf, json, os, statistics, sys, time, urllib.request

LABEL = sys.argv[1] if len(sys.argv) > 1 else "A"
BASE = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8000/v1"
OUT = os.path.expanduser(os.environ.get("BENCH_OUT", "./results"))
os.makedirs(OUT, exist_ok=True)
URL = f"{BASE}/chat/completions"
MODEL = os.environ.get("BENCH_MODEL", "deepseek-v4-flash-vision-exp")


def run(prompt, max_tokens):
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": max_tokens, "temperature": 0, "stream": True,
                       "stream_options": {"include_usage": True},
                       "chat_template_kwargs": {"thinking": False}}).encode()
    t0 = time.time(); first = None; n = 0; p = 0
    with urllib.request.urlopen(urllib.request.Request(URL, body, {"Content-Type": "application/json"}), timeout=900) as r:
        for line in r:
            if not line.startswith(b"data: ") or b"[DONE]" in line:
                continue
            d = json.loads(line[6:]); ch = (d.get("choices") or [{}])[0].get("delta", {})
            if ch.get("content") or ch.get("reasoning_content") or ch.get("reasoning"):
                if first is None:
                    first = time.time()
            if d.get("usage"):
                n = d["usage"]["completion_tokens"]; p = d["usage"]["prompt_tokens"]
    t1 = time.time()
    return {"prompt_tokens": p, "gen_tokens": n, "ttft": round(first - t0, 3) if first else None,
            "decode_tps": round(n / (t1 - first), 1) if (n and first) else 0, "wall": round(t1 - t0, 2)}


PROSE = "Write a 600-word essay about the history of the bicycle. No headings."
BIG = "Summarize the following text in one sentence.\n\n" + ("The quick brown fox jumps over the lazy dog. " * 230)

print(f"[{LABEL}] K1 @ {BASE}")
dec = [run(PROSE, 400) for _ in range(3)]
print("  decode  :", [d["decode_tps"] for d in dec], "tok/s  TTFT", [d["ttft"] for d in dec])
# Unique salt per run so prefix caching cannot serve a warm hit (cold-prefill only).
pre = [run(f"[run {i} {time.time_ns()}] " + BIG, 16) for i in range(3)]
pre_tps = [round(x["prompt_tokens"] / x["ttft"]) for x in pre]
print(f"  prefill : {pre[0]['prompt_tokens']} tok  TTFT {[x['ttft'] for x in pre]} -> {pre_tps} tok/s")
t0 = time.time()
with cf.ThreadPoolExecutor(6) as ex:
    conc = list(ex.map(lambda i: run(PROSE + f" (variant {i})", 400), range(6)))
wall = time.time() - t0
agg = round(sum(c["gen_tokens"] for c in conc) / wall, 1)
print(f"  6-stream: aggregate {agg} tok/s  per-stream {[c['decode_tps'] for c in conc]}  wall {wall:.1f}s")
res = {"label": LABEL, "base": BASE, "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
       "decode_tps_median": statistics.median(d["decode_tps"] for d in dec),
       "prefill_tps_median": statistics.median(pre_tps),
       "concurrent6_aggregate_tps": agg, "decode": dec, "prefill": pre, "concurrent": conc}
json.dump(res, open(f"{OUT}/{LABEL}-K1.json", "w"), indent=1)
print("saved", f"{OUT}/{LABEL}-K1.json")
