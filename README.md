<p align="center"><img src="docs/assets/banner.png" alt="vLLM stack A/B" width="100%"></p>

# vLLM serving-stack A/B on 2× Dell Pro Max with GB10

How we decided, with numbers, which community vLLM stack serves **DeepSeek-V4-Flash-Vision-Exp** (284B MoE, native vision, DSpark speculative decoding) on a two-node GB10 cluster (TP2 over RoCE) — and the thirteen things that went wrong on the way. Everything here was run in one night, 2026-09-16/17, on the boxes listed below. Nothing is a projection.

**If you only read one thing:** the same model on the same two machines gave us *engine hangs on the first image* on one stack, *KV pool halved* on another, and *five consecutive failed boots* on a third. The stack is not a detail. Measure it like you would measure the model.

## What is in this repo

| Path | What it is |
|---|---|
| `bench/k1_speed.py` | single-stream decode, **cold** prefill (unique salt per run so prefix caching cannot warm-hit), 6-stream aggregate |
| `bench/k3_vision_multistream.py` | synthetic OCR (10 images × 5 positions — catches the "half-causal image attention" bug) + 6 concurrent animated-SVG generations parsed as XML (catches multi-stream MoE corruption) |
| `bench/accept.sh` | structural acceptance: thinking off/on, tool call, default behaviour, engine facts from the container log |
| `bench/gateway_probe.sh` | proves the gateway in front of the cluster kept answering during the switch window |
| `switch/stack-mode.sh` + `stack-modes.example.yaml` | one command to switch between stacks idempotently, with a real-generation liveness check, an 8-min/15-min dead-boot rule and automatic rollback |
| `docs/decision-rule.md` | the rule we froze **before** running anything, and what an independent review made us change |
| `docs/pitfalls.md` | thirteen firsthand incidents, each with the symptom, the cause and the fix |
| `docs/results.md` | the four-column before/after table |

Tool-calling quality is measured with [`tool-eval-bench`](https://github.com/SeraphimSerapis/tool-eval-bench) (hardmode, 88 scenarios) — not ours. We ran `2.6.1.dev72+gd84fce442`; install that exact commit (see Quick start) if you want comparable scores.

## Prerequisites

- Two nodes with passwordless SSH from the machine running these scripts; Docker on both; `sudo -n` allowed for `drop_caches` (or delete those two lines in `switch/stack-mode.sh`).
- Python 3.10+ with `Pillow` for `bench/k3_vision_multistream.py` (`pip install pillow`); `bench/k1_speed.py` is stdlib-only.
- `bash`, `awk`, `sed`, `curl`, `python3` on the machine running the scripts.
- [`uv`](https://docs.astral.sh/uv/) for `tool-eval-bench`.
- `bench/accept.sh` reads engine facts with `docker logs`/`docker inspect` on the machine it runs on: run it **on the head node** (or omit the container argument and take the engine facts from the node by hand).
- A thinking-tier proxy is optional; `proxy_start`/`proxy_kill` in the yaml may be left empty.

Environment knobs: `BENCH_MODEL` (served name, default `deepseek-v4-flash-vision-exp`), `BENCH_OUT` (results dir, default `./results`), `K3_SKIP_VISION=1` (text-only endpoint: record vision as N/A), `K3_PART2_ONLY=1` (re-run only the 6-stream part, reuse the saved vision result), `ACCEPT_EVIDENCE` (path for `accept.sh` output), `STACK_MODES` (yaml path for `stack-mode.sh`) — all optional. For `gateway_probe.sh`: `GATEWAY_KEY` is **required**; `GATEWAY`, `ROUTES`, `PROBE_LOG` are optional.

## Hardware and what we compared

| | |
|---|---|
| Nodes | 2× Dell Pro Max with GB10 (128 GB unified memory each), direct RoCE link, TP2 |
| Model | `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp`, snapshot `6821d6ad`, 48 shards, 156 GB |
| Baseline "before" | the first two-node layout we ran: Qwen3.8-27B NVFP4 (single node, thinking-tier proxy) + DeepSeek-V4-Flash-0731 EXL3 single-seat on the other node — two independent models, no TP |
| Stack A | Anemll `dspark-vllm-gx10:0.1.1` (vLLM 0.25 fork, B12X MoE, DSpark k=6) — our production from 2026-09-01 |
| Stack B | eugr `spark-vllm-docker` recipe `deepseek-v4-flash-vision-exp.yaml` (vLLM ~0.29 build, B12X MoE with MXFP8 activations, InstantTensor loader + hybrid draft mod) |
| Stack C | the `ollie-gb10-serving-stacks` repo's `vision-exp-stack` (a community vLLM 0.28.1 image, marlin MoE, DSpark k=5, vision + prefix-cache fixes) — first as shipped, then with eugr's hybrid draft loader mod added |

## Results

See [`docs/results.md`](docs/results.md) for the full four-column table and the per-round narrative. Headline numbers are reproduced there, not here, so that this README never disagrees with the table.

## Quick start (reproduce the harness on your own cluster)

```bash
git clone https://github.com/ryangu00/dell-pro-max-gb10-vllm-stack-ab.git
cd dell-pro-max-gb10-vllm-stack-ab
cp switch/stack-modes.example.yaml switch/stack-modes.yaml   # edit nodes, port, served name, one block per stack
switch/stack-mode.sh status

# Baseline on the incumbent, in the order the decision rule prescribes: accept → K3 → K1 ×2 → K2 ×2
uv tool install "git+https://github.com/SeraphimSerapis/tool-eval-bench.git@d84fce442aee49ffe433108901fd4216a784eefb"
bench/accept.sh http://<api>:<port>/v1 <served> <container>   # run on the head node; exits non-zero if any check fails
python3 bench/k3_vision_multistream.py A http://<api>:<port>/v1
python3 bench/k1_speed.py A http://<api>:<port>/v1 && python3 bench/k1_speed.py A http://<api>:<port>/v1
for t in 1 2; do tool-eval-bench --backend vllm --base-url http://<api>:<port> --model <served> --hardmode --seed 42 --parallel 4 \
  --backend-kwargs '{"chat_template_kwargs":{"thinking":true,"reasoning_effort":"high"},"temperature":0.5,"top_p":0.95}' \
  --json-file results/A-K2-trial$t.json; done

# Challenger: keep the gateway probe running through the window, switch, then repeat the exact same sequence with label B
GATEWAY_KEY=... ROUTES="main" bench/gateway_probe.sh &
switch/stack-mode.sh <mode>                                  # a mode name from your stack-modes.yaml, e.g. eugr
bench/accept.sh http://<api>:<port>/v1 <served> <container>
```

Then apply `docs/decision-rule.md`. Write the rule down before the challenger boots.

## What we would tell someone starting this on a GB10 pair

1. **`/health` lies.** Liveness is a real generation.
2. **Do not mmap the checkpoint** on GB10. Use InstantTensor *with* the hybrid draft mod for models that embed their draft layers.
3. **Pin the image digest** you benchmarked; `latest` moved under us within a week.
4. **Freeze baseline scalars and the rule first.** A single `tool-eval-bench` trial at temperature 0.5 moves ±2 points; run two, add a third only when the mean lands on the line.
5. **Declare a boot dead on a timer.** Eight minutes without a new log line, or fifteen minutes total, then capture logs and roll back. Our first failed boot cost 28 minutes of staring.
6. **Host `earlyoom` at 6 % free will kill you** during weight load; the community runs ~512 MB.

## License

Apache-2.0 — see [LICENSE](LICENSE). Copyright 2026 Ryan Gu (ryangu00).
