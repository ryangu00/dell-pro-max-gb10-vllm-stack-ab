# Decision rule for a serving-stack A/B

Written before the challenger boots, reviewed by an independent model, then frozen for that round. Changing the rule after seeing numbers is the failure mode this document exists to prevent — so we also record how the rule *changed between rounds*, because it did.

## How the rule evolved (honest history)

| Round | Rule as frozen before the challenger booted | What actually happened |
|---|---|---|
| 1 (A → B) | K2 ≥ A − 2 with safety ≤ A's count; K3 vision not hung and ≥ 40/50; K3 6/6; no K1 item < A − 10 % and at least one ≥ A + 10 %. No KV-pool criterion (we had not yet seen a stack halve it). | B trial 1: 90 / 3 warnings → fails "safety ≤ A". Trial 2: 92 / 2. We accepted B on the *second* trial under a rule the operator restated as "≥ 92 and ≤ 2 warnings" before it ran. The KV pool halving was recorded as a known limit, not scored. |
| 2 and 3 (B → C) | The rule below, written with round 1's lessons: KV ≥ 2.0 M added as an explicit target; two K2 trials from the start; tie band; per-trial safety cap; new safety ids judged by a human; vision 50/50 hard. | C never booted; the rule was never exercised. |

If you reuse this, the point is not our thresholds; it is that the thresholds were written down before the numbers existed, and that a second trial was added *as a rule* rather than as a rescue.

## Three benchmarks, same scripts, same parameters, same order on both stacks

| # | What | Script | Output |
|---|---|---|---|
| K1 | single-stream decode (400 tok ×3), cold prefill (~2.3 K-token prompt ×3, unique salt per run so prefix caching cannot serve a warm hit), 6-stream aggregate | `bench/k1_speed.py` | tok/s ×3 |
| K2 | tool-calling quality | `tool-eval-bench --hardmode --seed 42 --parallel 4 --trials 1 --timeout 360 --max-turns 32 --backend-kwargs '{"chat_template_kwargs":{"thinking":true,"reasoning_effort":"high"},"temperature":0.5,"top_p":0.95}'` | score/100, median turn s, safety-warning list |
| K3 | vision OCR (10 synthetic images × 5 positions) + 6 concurrent animated-SVG generations parsed as XML | `bench/k3_vision_multistream.py` | hits/50, parsed/6 |

Run order on every stack: accept → K3 → K1 ×2 → K2 ×2. Run K2 twice from the start; at temperature 0.5 a single trial moves ±2 points and ±1 safety warning.

## Freeze the baseline scalars before the challenger boots

Write the incumbent's numbers into the plan as single values (median of two runs). "32.4–33.7" is not a baseline; it lets you pick the comparison that flatters the result.

## The rule (challenger replaces incumbent only if **all** hold)

1. KV-cache pool ≥ the target you set (for us: ≥ 2.0 M tokens).
2. K2 mean of two trials ≥ incumbent mean − 0. If the mean lands in the ±1 band around the threshold, run a third trial and use the median of three.
3. Every K2 trial: safety warnings ≤ 3; mean ≤ 2.5; **any warning id not in the incumbent's set is judged by a human**, never netted against a good trial.
4. K2 median turn ≤ incumbent × 1.3.
5. K3 vision = 50/50 when the incumbent scored 50/50 (accept a regression only explicitly).
6. K3 multi-stream = 6/6 (a stack that corrupts one of six streams is not a candidate).
7. No K1 item (decode, cold prefill, 6-stream) below incumbent − 10 %.

Any failure → keep the incumbent. Record the negative result with the same care as a positive one.

## Things that are not part of the rule but must be true before you look at numbers

- Both stacks loaded the **same weight snapshot** (grep `snapshots/<sha>` in both ranks' logs).
- Every mod/patch you claimed to apply shows an "applied" line in **both** ranks' launcher logs. A missing directory is skipped silently by most launchers.
- Image digest on both nodes equals the digest you wrote down.
- Liveness is a real generation, not `/health`.
- The gateway in front of the cluster kept answering during the switch window (we hit four routes in turn, sleep 30 s, repeat — roughly one probe per route per minute — and require zero non-200).
- A hard boot deadline: no new log line for 8 minutes, or 15 minutes total → declare dead, capture logs, restore the incumbent. Do not watch it for half an hour.

## Round trip before you call it production

Challenger → incumbent → challenger, through the same switch script operators will use, with the acceptance script at every station. The alias operators type (`stack-mode prod`) must resolve to the winner; the loser must still be startable by its explicit name.
