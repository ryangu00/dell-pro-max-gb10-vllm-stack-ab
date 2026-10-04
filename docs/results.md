# Results — four stacks, same model class, same two nodes, same scripts

Measured 2026-09-16/17. All numbers are single-stream unless stated. "cold prefill" means a unique prompt every run (no prefix-cache hit). K2 = `tool-eval-bench` hardmode (88 scenarios, seed 42, parallel 4, thinking on / effort high, temperature 0.5). K3① = synthetic OCR hits/50; K3② = 6 concurrent animated-SVG generations that parse as XML.

## The table

| | **P: first two-node layout** (no TP) | **A: Anemll** (vLLM 0.25 fork) | **B: eugr recipe** (vLLM ~0.29, InstantTensor+hybrid draft) | **C: ollie-gb10-serving-stacks** (vLLM 0.28.1, marlin, k=5) + eugr hybrid-draft mod |
|---|---|---|---|---|
| model(s) | Qwen3.8-27B NVFP4 (node A) · DeepSeek-V4-Flash-0731 EXL3 single-seat (node B) | DeepSeek-V4-Flash-Vision-Exp TP2 | same | same |
| decode tok/s (1 stream, 400 tok) | 27B: 20.3 · 0731 EXL3: 19.6 | 30.8 | **33.0** (median of two runs: 33.7, 32.4) | — |
| cold prefill tok/s (~2.3 K prompt) | 27B: 2031 · 0731: 1082 | 1527 | **2096** | — |
| 6-stream aggregate tok/s | 27B: 90.6 · 0731: **20.6** (single seat serialises; 6 requests took 117 s wall) | 80.2 | 77.6 (75.7, 79.5) | — |
| K2 score /100 | 27B: 90 · 0731: 92 | **93** | 90, 92 (mean 91) | — |
| K2 median turn | 27B: 6.5 s · 0731: **20.9 s** (single seat under parallel-4 load) | 7.6 s | 7.5 s | — |
| K2 safety warnings | 1 · 1 | 2 | 3, 2 | — |
| K3① vision OCR /50 | N/A (text-only models) | **engine hung on image #1** (NCCL collective timeout, `/health` still 200) | **50/50** | — |
| K3② 6-stream SVG parsed /6 | 27B: 5/6 · 0731: 6/6 (377 s wall, serialised) | not reached | 6/6 (108 s wall) | — |
| KV-cache pool (tokens) | n/a (single-seat 384 K on node B) | **2,337,475** | 1,184,211 at `--gpu-memory-utilization 0.85` (recipe default); **1,499,086** at 0.87, which is what we ran from 2026-09-17; since 2026-09-26 production on this tier is a single-node engine and this stack is kept as a rollback tier (see the [Update (2026-10) section](../README.md#update-2026-10)) | — |
| prefix cache | — | never hit in our runs (fix merged upstream 09-03, never released) | hits from 2nd request | — |
| boot, warm weights | ~10 min (EXL3 single seat) | 3–5 min | 3 min | **never booted** (7 attempts across two rounds; see below) |

C has no numbers because it never served a request on our nodes. That is a result, not a gap: a stack that cannot load the checkpoint on the target hardware loses regardless of what it would score.

## Round 1 — A → B (2026-09-16/17)

Decision rule: switch only if K2 (second trial) ≥ 92 with ≤ 2 safety warnings, K3① not hung and ≥ 40/50, K3② 6/6, and no K1 item below A − 10 % with at least one ≥ A + 10 %.

B's first K2 trial came in at 90 with 3 warnings — on the line. The second trial: 92 / 2. Vision went from "engine dead" to 50/50; cold prefill +37 %; decode +5–9 %; 6-stream 75.7 and 79.5 on the two runs (median 77.6 vs. A's 80.2, i.e. −3 %; the second run alone was −1 %). KV pool halved. **Switched to B**, KV pool recorded as a known limit.

Our best explanation for B's tool-calling being slightly below A (not proven — we did not run B with W4A16): the eugr recipe forces `B12X_MOE_FORCE_A8=1` (MXFP8 activations for the MoE) while A ran W4A16. The partials were judgement-level (sent an email without asking which recipient), not parse failures; TTFT was half of A's.

## Round 2 — B → C as shipped (2026-09-17)

Five consecutive failed boots, none of them the stack's fault in the narrow sense — see `pitfalls.md` items 1–5. Result: **negative**, B kept. Side effect worth having: we moved the worker's `earlyoom` from 6 % free (7.4 GB) to 512 MB, and it still fired correctly on the one real OOM.

## Round 3 — B → C with the hybrid draft loader mod

We wired eugr's `instanttensor-hybrid-draft-loader` mod into the `ollie-gb10-serving-stacks` repo's `fixes/`, dry-ran it in a throwaway container (patch applies, marker present, import ok, all five mods stack cleanly in order), added `--load-format instanttensor`, and booted with a per-minute memory sampler and an 8-minute dead-boot rule.

One minute in, both nodes went from 6 GB used to 123 GB used with InstantTensor at 18 % (28 GB of 156 GB) and the log line the mod emits when it reroutes the draft (`Hybrid draft loading: using lazy safetensors`) counted **zero** on both ranks — the loader had not reached the draft yet. So the memory blow-up we had attributed to draft double-loading in round 2 was the target load itself: **the InstantTensor build inside this particular image consumes host memory for the whole checkpoint**, which does not fit in 128 GB. The eugr image's InstantTensor loads the same file on the same node in 22 seconds without this. `earlyoom` (now at 512 MB) killed the worker twice; we declared it dead at four minutes and restored B.

Result: **negative**, B kept. On this image every loader path we could reach is unusable for a 156 GB checkpoint: mmap (non-deterministic, 28 min on one node), InstantTensor (host-memory blow-up), eager (`F8_E8M0` dtype), fastsafetensors (OOM). The mod was not the fix because the mod was not the problem. We stopped here rather than build a fifth loader path; the next move is a different image, not another flag.

One thing the round did buy: a dead-boot verdict in four minutes instead of twenty-eight.

## Before the "before": the first two-node layout

P is the layout we ran before any TP2 stack: one node serving a dense 27B at four thinking tiers, the other serving a 384 K-context single seat. It has no vision, no shared KV pool, and two different models answering depending on the route. The numbers are here so the "why bother with TP2" question has data next to it.

What the numbers say:

- **Single-stream speed is a wash.** The dense 27B decodes at 20 tok/s; the 284B MoE on TP2 decodes at 31–33 tok/s. Bigger model, faster tokens, because MoE activates 13B and DSpark drafts six tokens at a time.
- **Concurrency is where the single-seat layout collapses.** Six concurrent requests against the 0731 single seat aggregate to 20.6 tok/s (they queue; 117 s wall for what the TP2 stacks do in 30 s). The 27B node handles six streams fine (90.6 aggregate) but it is a different, smaller model.
- **Tool-calling quality is close across the board** (90–93 hardmode) — the 27B is a genuinely good tool caller at 20 tok/s, which is why people keep recommending it for single-node setups. What it cannot do is see images or share one KV pool across a 1 M-token session.
- **Median turn latency** is the real user-facing difference: 7.5 s on TP2 vs. 20.9 s on the single seat under parallel-4 load (6.5 s on the 27B).

So the pre-TP2 layout was not slow; it was *narrow*. Two models, two routes, no vision, no concurrency headroom on the big one.
