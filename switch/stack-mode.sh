#!/bin/bash
# stack-mode.sh — one command to switch a two-node vLLM cluster between serving stacks, idempotently.
#
#   stack-mode.sh status            # which stack is live (by container name), port health
#   stack-mode.sh standby           # stop every stack on both nodes
#   stack-mode.sh <mode>            # stop everything, start <mode>, wait for the port, verify a real generation
#   stack-mode.sh prod              # alias: whatever `prod:` points at in stack-modes.yaml
#
# Modes live in stack-modes.yaml next to this script (see stack-modes.example.yaml):
#   head/worker SSH targets, the API port, and per mode: container name, start command, stop command.
# The script never edits a recipe; it only calls each stack's own launcher.
#
# Semantics we learned the hard way (docs/pitfalls.md):
#   * liveness = a real generation with non-empty content, not /health;
#   * a boot with no new log line for 8 min, or 15 min wall-clock total, is dead: capture logs, roll back
#     to whatever was running before (or to `prod:` if nothing was);
#   * stop_all must know every container name every stack ever used, or a half-switched cluster
#     keeps the port and the memory.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${STACK_MODES:-$HERE/stack-modes.yaml}"
[ -f "$CFG" ] || { echo "no $CFG (copy stack-modes.example.yaml)"; exit 2; }

# Minimal YAML reader: top-level scalars and one level of mode maps. Keep the file simple:
# `key: value`, optional double quotes, optional trailing `# comment`, modes indented by two spaces.
_strip() { sed -E 's/[ \t]+#.*$//; s/^[ \t]+//; s/[ \t]+$//; s/^"(.*)"$/\1/'; }
y()  { awk -v k="$1" '$1==k":"{sub(/^[^:]*:[ \t]*/,""); print; exit}' "$CFG" | _strip; }
ym() { awk -v m="$1" -v k="$2" '
        /^modes:/{inm=1; next}
        inm && $0 ~ "^  "m":"{cur=1; next}
        inm && /^  [A-Za-z0-9_-]+:/{cur=0}
        cur && $1==k":"{sub(/^[ \t]*[^:]*:[ \t]*/,""); print; exit}' "$CFG" | _strip; }
modes() { awk '/^modes:/{inm=1; next} inm && /^  [A-Za-z0-9_-]+:/{sub(/^  /,""); sub(/:.*/,""); print}' "$CFG"; }

HEAD="$(y head)"; WORKER="$(y worker)"; API="$(y api)"; PORT="$(y port)"; PROD="$(y prod)"
SERVED="$(y served_name)"; PROXY="$(y proxy_start)"; PROXY_KILL="$(y proxy_kill)"
say() { printf '%s\n' "$*"; }
sshq() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$@" 2>/dev/null; }
port_ok() { curl -s -o /dev/null -w "%{http_code}" --max-time 6 "http://$API:$PORT/v1/models" 2>/dev/null | grep -q 200; }
alive() {  # a real generation with non-empty content; /health and even /v1/models can be green on a dead engine
  curl -s -m 60 "http://$API:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"'"$SERVED"'","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); c=d["choices"][0]["message"].get("content"); sys.exit(0 if c else 1)' 2>/dev/null
}

detect() {
  local names m
  names="$(sshq "$HEAD" "docker ps --format '{{.Names}}'")"
  for m in $(modes); do
    case "$names" in *"$(ym "$m" container)"*) echo "$m"; return;; esac
  done
  echo standby
}

stop_all() {
  local m ct stop
  say ">> stop_all"
  for m in $(modes); do
    ct="$(ym "$m" container)"; stop="$(ym "$m" stop)"
    [ -n "$stop" ] && sshq "$HEAD" "$stop" >/dev/null
    sshq "$HEAD" "docker rm -f $ct" >/dev/null; sshq "$WORKER" "docker rm -f $ct" >/dev/null
  done
  [ -n "$PROXY_KILL" ] && sshq "$HEAD" "$PROXY_KILL" >/dev/null
  say "   all stopped"
  return 0
}

start_mode() {  # $1 = mode; returns 1 on dead boot or failed liveness (caller decides what to roll back to)
  local m="$1" start ct t0 t last="" cur fatal last_progress
  start="$(ym "$m" start)"; ct="$(ym "$m" container)"
  [ -n "$start" ] || { say "mode $m has no start command"; return 1; }
  say ">> start $m"
  sshq "$HEAD" 'sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null'; :
  sshq "$WORKER" 'sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null'; :
  sshq "$HEAD" "nohup bash -lc '$start' > ~/stack-mode-$m.log 2>&1 &"
  t0=$(date +%s); last_progress=$t0
  until port_ok; do
    sleep 30
    t=$(( $(date +%s) - t0 ))                       # wall clock, including ssh/curl time
    cur="$(sshq "$HEAD" "docker logs $ct 2>&1 | grep -v 'Loading safetensors' | tail -1 | cut -c1-100")"
    # a dead engine never opens the port; catch the fatal line instead of waiting for the timer
    fatal="$(sshq "$HEAD" "docker logs $ct 2>&1 | grep -a -E 'ValueError|AssertionError|died unexpectedly|initialization failed|OutOfMemory' | grep -a -v 'File ' | tail -1 | cut -c1-160")"
    if [ -n "$fatal" ]; then
      say "  ❌ $m engine fatal (${t}s wall): $fatal"
      sshq "$HEAD" "docker logs $ct 2>&1" > ~/stack-mode-$m-head.log; sshq "$WORKER" "docker logs $ct 2>&1" > ~/stack-mode-$m-worker.log
      return 1
    fi
    [ "$cur" = "$last" ] || { last="$cur"; last_progress=$(date +%s); }
    if [ $(( $(date +%s) - last_progress )) -ge 480 ] || [ $t -ge 900 ]; then   # 8 min without a new log line (wall clock), or 15 min total
      say "  ❌ $m dead (no new log line for $(( $(date +%s) - last_progress ))s, ${t}s wall): $last"
      sshq "$HEAD" "docker logs $ct 2>&1" > ~/stack-mode-$m-head.log; sshq "$WORKER" "docker logs $ct 2>&1" > ~/stack-mode-$m-worker.log
      return 1
    fi
  done
  alive || { say "  ⚠️ port up but no real generation"; return 1; }
  say "  :$PORT ✓ ($m, real generation ok, $(( $(date +%s) - t0 ))s)"
  if [ -n "$PROXY" ]; then
    sshq "$HEAD" "setsid nohup $PROXY > ~/tier-proxy.log 2>&1 < /dev/null & disown" && say "  tier proxy started" || say "  ⚠️ tier proxy start failed (mode is up; check ~/tier-proxy.log)"
  fi
  return 0
}

case "${1:-status}" in
  status) say "live: $(detect)"; port_ok && say "  :$PORT UP" || say "  :$PORT -";;
  standby) stop_all;;
  prod) exec "$0" "$PROD";;
  *)
    target="$1"; modes | grep -qx "$target" || { say "unknown mode $target; modes: $(modes | tr '\n' ' ')"; exit 1; }
    prev="$(detect)"
    if [ "$prev" = "$target" ]; then alive && { say "already $target (generation ok)"; exit 0; } || say "already $target but not answering — restarting"; fi
    stop_all
    if ! start_mode "$target"; then
      back="$prev"; [ "$back" = standby ] || [ "$back" = "$target" ] && back="$PROD"
      say "  rolling back to $back"; stop_all; start_mode "$back"; exit 1
    fi
    ;;
esac
