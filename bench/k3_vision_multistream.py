#!/usr/bin/env python3
"""K3 probe: synthetic vision OCR (5 positions x 10 images) + 6-stream animated-SVG parse test..

  python3 bench/k3_vision_multistream.py <label> [base_url]

Part 1 (vision): 10 synthetic PIL images, each with 5 random UPPERCASE tokens placed at the
four corners + centre. Ask the model to list every text token. Score = tokens found / 50.
Rationale: the 09-12 community fix targets image attention being partially causal, which
degrades tokens in later (bottom/right) regions; per-position hit rate is reported too.

Part 2 (multi-stream): 6 concurrent "animated SVG pelican on a bicycle" requests.
Score = how many responses contain a well-formed <svg> document (xml.etree parses).
Rationale: a community test (NVIDIA forum, Sept 2026) that exposed multi-stream MoE output corruption on one backend.

All requests: thinking off, temperature 0 (deterministic). Writes <label>-K3.json to the
eval dir. Seeded, so A and B see identical images and prompts.
"""
import base64, concurrent.futures as cf, io, json, os, random, re, sys, time, urllib.request
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFont

LABEL = sys.argv[1] if len(sys.argv) > 1 else "A"
BASE = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8000/v1"
OUT = os.path.expanduser(os.environ.get("BENCH_OUT", "./results"))
os.makedirs(OUT, exist_ok=True)
MODEL = os.environ.get("BENCH_MODEL", "deepseek-v4-flash-vision-exp")
SKIP_VISION = os.environ.get("K3_SKIP_VISION") == "1"   # text-only endpoints: record vision as N/A, run part 2 only
rng = random.Random(20260916)
WORDS = ["ZEBRA", "COPPER", "MARBLE", "SIGNAL", "FOREST", "VIOLET", "TUNNEL", "HARBOR", "ORBIT", "CACTUS",
         "PYTHON", "SILVER", "MEADOW", "ROCKET", "BASKET", "PLANET", "WINDOW", "GARDEN", "CANDLE", "BRIDGE"]


def chat(messages, max_tokens, timeout=600):
    body = json.dumps({"model": MODEL, "messages": messages, "max_tokens": max_tokens, "temperature": 0,
                       "chat_template_kwargs": {"thinking": False}}).encode()
    t0 = time.time()
    with urllib.request.urlopen(urllib.request.Request(f"{BASE}/chat/completions", body,
                                                       {"Content-Type": "application/json"}), timeout=timeout) as r:
        d = json.load(r)
    return d["choices"][0]["message"].get("content") or "", time.time() - t0, d["choices"][0].get("finish_reason")


def font(size):
    for p in ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def make_image(i):
    im = Image.new("RGB", (1024, 768), (245, 245, 240))
    d = ImageDraw.Draw(im)
    f = font(44)
    toks = [f"{rng.choice(WORDS)}{rng.randint(10, 99)}" for _ in range(5)]
    pos = {"TL": (40, 40), "TR": (700, 40), "C": (380, 350), "BL": (40, 680), "BR": (700, 680)}
    placed = {}
    for (k, xy), t in zip(pos.items(), toks):
        d.text(xy, t, fill=(20, 20, 20), font=f)
        placed[k] = t
    b = io.BytesIO(); im.save(b, "PNG")
    return placed, "data:image/png;base64," + base64.b64encode(b.getvalue()).decode()


def part1():
    res = []
    for i in range(10):
        placed, durl = make_image(i)
        txt, dt, _ = chat([{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": durl}},
            {"type": "text", "text": "List every piece of text visible in this image, exactly as written, one per line. Output only the text."}]}], 200)
        norm = re.sub(r"[^A-Z0-9]", "", txt.upper())
        hits = {k: (v in norm) for k, v in placed.items()}
        res.append({"img": i, "placed": placed, "hits": hits, "secs": round(dt, 2), "raw": txt[:300]})
        print(f"  img{i}: {sum(hits.values())}/5  {dt:.1f}s  miss={[k for k,v in hits.items() if not v]}")
    per_pos = {k: sum(r["hits"][k] for r in res) for k in ["TL", "TR", "C", "BL", "BR"]}
    total = sum(per_pos.values())
    return {"score": total, "of": 50, "per_position": per_pos, "detail": res}


def part2():
    prompt = ("Write a complete, valid, self-contained animated SVG (use <animate> or <animateTransform>) of a pelican "
              "riding a bicycle. Output ONLY the SVG markup starting with <svg and ending with </svg>. No prose, no code fences.")
    def one(j):
        try:
            txt, dt, fin = chat([{"role": "user", "content": prompt}], 8000)   # finish_reason returned per call: thread-safe
        except Exception as e:
            return {"j": j, "ok": False, "err": str(e)[:200], "secs": None}
        m = re.search(r"<svg.*?</svg>", txt, re.S)
        ok = False; err = None
        if m:
            try:
                ET.fromstring(m.group(0)); ok = True
            except ET.ParseError as e:
                err = str(e)[:120]
        else:
            err = "no <svg> block"
        return {"j": j, "ok": ok, "err": err, "secs": round(dt, 1), "chars": len(txt), "finish": fin,
                "truncated": fin == "length", "animated": bool(re.search(r"<animate", txt))}
    t0 = time.time()
    with cf.ThreadPoolExecutor(6) as ex:
        out = list(ex.map(one, range(6)))
    wall = time.time() - t0
    for o in out:
        print(f"  stream{o['j']}: {'OK ' if o['ok'] else 'BAD'} {o.get('secs')}s chars={o.get('chars')} animated={o.get('animated')} {o.get('err') or ''}")
    return {"ok": sum(o["ok"] for o in out), "of": 6, "wall_secs": round(wall, 1), "detail": out}


if __name__ == "__main__":
    prev = f"{OUT}/{LABEL}-K3.json"
    if SKIP_VISION:
        p1 = {"score": None, "of": 50, "na": True, "note": "text-only endpoint, vision N/A"}; print(f"[{LABEL}] part1 skipped (vision N/A)")
    elif os.environ.get("K3_PART2_ONLY") == "1" and os.path.exists(prev):
        p1 = json.load(open(prev))["vision"]; print(f"[{LABEL}] part1 reused from {prev}")
    else:
        print(f"[{LABEL}] K3 part1 vision OCR @ {BASE}")
        p1 = part1()
    print(f"[{LABEL}] vision score {p1.get('score')}/50  per_position={p1.get('per_position', 'N/A')}")
    print(f"[{LABEL}] K3 part2 6-stream SVG")
    p2 = part2()
    print(f"[{LABEL}] svg parse {p2['ok']}/6  wall {p2['wall_secs']}s")
    json.dump({"label": LABEL, "base": BASE, "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "vision": p1, "multistream": p2},
              open(f"{OUT}/{LABEL}-K3.json", "w"), indent=1)
    print("saved", f"{OUT}/{LABEL}-K3.json")
