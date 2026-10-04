# Pitfalls (firsthand, 2026-09-16/17 unless dated otherwise, two GB10 nodes, TP2 over RoCE)

Each one cost us at least one production window. Ordered by how much time it burned.

## 1. `mmap` weight loading on GB10 is non-deterministic and can take 30 minutes

The default vLLM safetensors loader memory-maps the checkpoint. On GB10 unified memory the page-fault path is slow (NVIDIA forum thread 349886, acknowledged by NVIDIA). With a 156 GB checkpoint we saw **rank 1 finish in 3 minutes and rank 0 sit at 100 % CPU in `routed_experts._load_w13` for 28 minutes** with zero disk reads and 150–360 MB/s swap-out. Same image, same weights, same hardware.

- Symptom: `py-spy dump` shows `load_weights → _load_w13`; RSS flat; `vmstat` shows `so` > 0.
- Fix: do not mmap. Use `--load-format instanttensor` (156 GB in 22 s on the same node) **together with** the hybrid draft loader below.
- Do not infer from one node to the other. Both must pass.

## 2. InstantTensor is not one thing — the build inside your image decides whether 156 GB fits

DeepSeek V4 Flash ships its speculative draft layers in the same checkpoint. eugr's recipe pairs InstantTensor with an `instanttensor-hybrid-draft-loader` mod (target → InstantTensor, draft → lazy safetensors) so the draft is not loaded a second time. On eugr's image the target loads in 22 s.

On a different community image we tried the same flag, then the same flag **plus** that mod (dry-run showed the patch applied and imported cleanly). Both times the nodes hit **123 GB used at 18 % of the target load**, before the draft stage — the mod's log line (`Hybrid draft loading: using lazy safetensors`) counted zero. That image's InstantTensor build keeps the whole checkpoint resident in host memory; ours is 156 GB on a 128 GB node.

- What to check before assuming a loader flag is portable: watch `free` on both nodes during the first two minutes of load; if `used` tracks the checkpoint size rather than the shard size, stop.
- Grep counts of stage-specific log lines (`Hybrid draft loading`, `Loading weights took`) tell you *which* stage blew up. We mis-attributed a round to the draft because we did not count.

## 3. `--safetensors-load-strategy eager` dies on `F8_E8M0`

The eager path goes through the Python `safetensors` library, which (in the image we used) does not know the MXFP8 scale dtype: `KeyError: 'F8_E8M0'` two minutes in. The mmap path uses the Rust `safe_open`, which does.

## 4. `--load-format fastsafetensors` OOMs the node

It DMAs whole shards into device memory. On a 128 GB node with a 156 GB checkpoint we went to `mem 0.41 %, swap 100 %` and earlyoom fired. Not viable for this model size.

## 5. Host `earlyoom` at 6 % free kills vLLM during weight loading

Our worker node had `earlyoom -m 6` (≈7.4 GB free) from an earlier setup. Loading 80 GB of weights into unified memory crosses that line for a few seconds; it SIGTERMed the vLLM worker two minutes into a load (and had done so five times in the weeks before). Community recipes we read run either no earlyoom or `-M 524288,102400` (512 MB). We moved to the latter. Verified: it did **not** fire during three later loads that peaked above the old line, and it **did** fire on the one genuine OOM (pitfall 4: `mem 0.41 %, swap 100 %`).

- `/etc/default/earlyoom` is a systemd `EnvironmentFile`: a trailing `# comment` on the `EARLYOOM_ARGS=` line is passed to the binary as arguments and the unit fails. Put comments on their own line.

## 6. `--max-model-len auto` (1 M) trips a CUDA-graph capture assertion on newer vLLM builds

`sparse_mla.py: assert active_topk_width >= cm.max_seq_len // compress_ratio` on both ranks during capture (eugr issue #400). The community workaround is `--enforce-eager` (slow). **`--max-model-len 1048320`** (one block below 1 M) avoided the assertion for us and kept CUDA graphs: the same image that failed at `auto` booted in 3 minutes with this value and served two full `tool-eval-bench` runs plus every probe in this repo. Our reading of the code is that capture builds metadata at `max_model_len + block_size`, which at exactly 1 M overflows the buffer the loader sized; we did not confirm that with the maintainers.

## 7. No `--served-model-name` means the served id is the full HF repo name

Clients configured with a short alias get 404. Pass both: `--served-model-name <alias> <org/repo>`. Recipe runners like eugr's `run-recipe.py` accept extra vLLM args after `--`, so this needs no recipe edit. Verified: `/v1/models` listed both ids and `accept.sh` passed against each.

## 8. `/health` returns 200 while the engine is dead

After an NCCL collective timeout rank 0 hangs; `/health` stays green; every request times out. We watched this for ten minutes on a live production endpoint before restarting it. Liveness must be a real generation (`max_tokens: 8`, non-empty content), not `/health` — `switch/stack-mode.sh` does exactly that.

We saw it a second time, on the winning stack, during a tensor-parallel hang with no error in the log at the onset (2026-09-25; see the [Update (2026-10) section](../README.md#update-2026-10)): the engine had stopped producing tokens and the health endpoint still said 200. That health behavior is recorded in incident notes; no per-minute health samples were saved.

## 9. `vllm serve --help` prints nothing inside `docker run` without a GPU

We concluded a flag did not exist. It did. To check a flag in an image, grep the source (`vllm/config/load.py`, `vllm/engine/arg_utils.py`) instead.

## 10. Recipe images are moving targets

`eugr/spark-vllm-b12x:latest` moved between the day the recipe was tested and the day we pulled it; the recipe had five open issues that week. Pin the digest you benchmarked and re-check it on every launch.

## 11. Containers running as root leave your HF cache root-owned

A recipe's in-container `hf-download` wrote the model directory as root. The next tool that wanted to write there (`hf download` as the user) failed with `PermissionError`. `chown -R` back; content untouched.

## 12. After a night of container churn, the same recipe can fail its KV-cache check

The eugr recipe at `--gpu-memory-utilization 0.85` booted fine three times, then twice in a row died with `ValueError: To serve at least one request with the model's max seq len (1048320), 10.06 GiB KV cache is needed, which is larger than the available KV cache memory (9.6 GiB)`. `free` showed 4 GB used on the node. The CUDA-side free figure vLLM profiles against had shrunk by ~2 GiB after seven container start/stop cycles — the same allocator-not-returning behaviour a forum post describes for this platform.

- Fix that worked immediately: `--gpu-memory-utilization 0.87` (the value the other community stacks use; the platform ceiling is about 0.877). Side effect: the KV pool went from 1,184,211 to 1,499,086 tokens. We used 0.87 from 2026-09-17; this stack has been a rollback tier since 2026-09-26.
- Your switch script must read the container log for `ValueError` / `died unexpectedly`, not just wait for the port; ours waited 25 minutes for a port that was never coming, twice.

## 13. Your own probe can look like a stack bug

Our 6-stream SVG test reported 4/6 "no `<svg>` block". The responses were ~8.5 K characters, cut by `max_tokens: 3000`. Check `finish_reason` before calling output "corrupted".
