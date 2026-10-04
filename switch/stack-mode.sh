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
set -u -o pipefail
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
SERVED="$(y served_name)"; PROXY="$(y proxy_start)"; PROXY_KILL="$(y proxy_kill)"; PPORTS="$(y proxy_ports)"
LOG_DIR="${STACK_LOG_DIR:-$HERE/../results}"
PROXY_PID=""
if [ -n "$PROXY" ] && [ -z "$PPORTS" ]; then
  echo "proxy_start requires proxy_ports"; exit 2
fi
for p in $PPORTS; do
  case "$p" in ''|*[!0-9]*) echo "invalid proxy port"; exit 2;; esac
done
say() { printf '%s\n' "$*"; }
sshq() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$@" 2>/dev/null; }
http_ok() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://$API:$1/v1/models" 2>/dev/null)" || return 1
  [ "$code" = 200 ]
}
port_ok() { http_ok "$PORT"; }
proxy_http_ok() {
  local p
  for p in $PPORTS; do
    http_ok "$p" || { say "  proxy port :$p not answering HTTP 200"; return 1; }
  done
}
alive() {  # a real generation with non-empty content; /health and even /v1/models can be green on a dead engine
  curl -s -m 60 "http://$API:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"'"$SERVED"'","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); c=d["choices"][0]["message"].get("content"); sys.exit(0 if c else 1)' 2>/dev/null
}

# Read the socket table before filtering so a failed query cannot look like an empty port.
port_rows() { awk -v p="$1" '$4 ~ (":" p "$")'; }
proxy_cleanup() {
  [ -n "$PROXY_PID" ] || return 0
  sshq "$HEAD" "if kill -0 $PROXY_PID 2>/dev/null; then kill $PROXY_PID; fi" >/dev/null || return 1
  PROXY_PID=""
}
start_proxy() {
  local pid sockets p ready deadline
  [ -n "$PROXY" ] || return 0
  pid="$(sshq "$HEAD" "setsid nohup $PROXY > tier-proxy.log 2>&1 < /dev/null & echo \$!")" || return 1
  case "$pid" in ''|*[!0-9]*) say "  proxy start gave no PID"; return 1;; esac
  PROXY_PID="$pid"; deadline=$(( $(date +%s) + 15 ))
  while :; do
    sockets="$(sshq "$HEAD" 'ss -ltnp')" || { proxy_cleanup; return 1; }
    ready=1
    for p in $PPORTS; do
      printf '%s\n' "$sockets" | port_rows "$p" | grep -Eq "pid=$pid([,)]|$)" || ready=0
    done
    if [ "$ready" = 1 ]; then
      say "  tier proxy pid $pid owns: $PPORTS"; return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "  proxy pid $pid does not own every proxy port after 15 s"
      proxy_cleanup; return 1
    fi
    sleep 1
  done
}

detect() {
  local names m
  names="$(sshq "$HEAD" "docker ps --format '{{.Names}}'")" || return 1
  for m in $(modes); do
    if printf '%s\n' "$names" | grep -Fxq "$(ym "$m" container)"; then echo "$m"; return; fi
  done
  echo standby
}

stop_all() {
  local m ct stop node names sockets p failed=0
  say ">> stop_all"
  for m in $(modes); do
    ct="$(ym "$m" container)"; stop="$(ym "$m" stop)"
    if [ -n "$stop" ]; then sshq "$HEAD" "$stop" >/dev/null || failed=1; fi
    for node in "$HEAD" "$WORKER"; do
      names="$(sshq "$node" "docker ps -a --format '{{.Names}}'")" || { failed=1; continue; }
      if printf '%s\n' "$names" | grep -Fxq "$ct"; then
        sshq "$node" "docker rm -f $ct" >/dev/null || failed=1
      fi
    done
  done
  if [ -n "$PROXY_KILL" ]; then sshq "$HEAD" "$PROXY_KILL" >/dev/null || failed=1; fi
  for node in "$HEAD" "$WORKER"; do
    names="$(sshq "$node" "docker ps -a --format '{{.Names}}'")" || { failed=1; continue; }
    for m in $(modes); do
      ct="$(ym "$m" container)"
      if printf '%s\n' "$names" | grep -Fxq "$ct"; then
        say "   container $ct remains"; failed=1
      fi
    done
    if [ -n "$PPORTS" ]; then
      sockets="$(sshq "$node" 'ss -ltnp')" || { failed=1; continue; }
      for p in $PPORTS; do
        if [ -n "$(printf '%s\n' "$sockets" | port_rows "$p")" ]; then
          say "   :$p still listening"; failed=1
        fi
      done
    fi
  done
  [ "$failed" = 0 ] || { say "   stop failed or residue could not be ruled out"; return 1; }
  say "   all stopped"
  return 0
}

start_mode() {  # $1 = mode; returns 1 on dead boot or failed liveness (caller decides what to roll back to)
  local m="$1" start ct t0 t last="" cur fatal last_progress quoted_start
  start="$(ym "$m" start)"; ct="$(ym "$m" container)"
  [ -n "$start" ] || { say "mode $m has no start command"; return 1; }
  say ">> start $m"
  PROXY_PID=""; start_proxy || return 1
  sshq "$HEAD" 'sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null'; :
  sshq "$WORKER" 'sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null'; :
  printf -v quoted_start '%q' "$start"
  sshq "$HEAD" "nohup bash -c $quoted_start > stack-mode-$m.log 2>&1 < /dev/null &" || { proxy_cleanup; return 1; }
  t0=$(date +%s); last_progress=$t0
  until port_ok; do
    sleep 30
    t=$(( $(date +%s) - t0 ))                       # wall clock, including ssh/curl time
    cur="$(sshq "$HEAD" "docker logs $ct 2>&1 | grep -v 'Loading safetensors' | tail -1 | cut -c1-100")"
    # a dead engine never opens the port; catch the fatal line instead of waiting for the timer
    fatal="$(sshq "$HEAD" "docker logs $ct 2>&1 | grep -a -E 'ValueError|AssertionError|died unexpectedly|initialization failed|OutOfMemory' | grep -a -v 'File ' | tail -1 | cut -c1-160")"
    if [ -n "$fatal" ]; then
      say "  ❌ $m engine fatal (${t}s wall): $fatal"
      mkdir -p "$LOG_DIR"
      sshq "$HEAD" "docker logs $ct 2>&1" > "$LOG_DIR/stack-mode-$m-head.log"; sshq "$WORKER" "docker logs $ct 2>&1" > "$LOG_DIR/stack-mode-$m-worker.log"
      proxy_cleanup; return 1
    fi
    [ "$cur" = "$last" ] || { last="$cur"; last_progress=$(date +%s); }
    if [ $(( $(date +%s) - last_progress )) -ge 480 ] || [ $t -ge 900 ]; then   # 8 min without a new log line (wall clock), or 15 min total
      say "  ❌ $m dead (no new log line for $(( $(date +%s) - last_progress ))s, ${t}s wall): $last"
      mkdir -p "$LOG_DIR"
      sshq "$HEAD" "docker logs $ct 2>&1" > "$LOG_DIR/stack-mode-$m-head.log"; sshq "$WORKER" "docker logs $ct 2>&1" > "$LOG_DIR/stack-mode-$m-worker.log"
      proxy_cleanup; return 1
    fi
  done
  alive || { say "  port up but no real generation"; proxy_cleanup; return 1; }
  say "  :$PORT ✓ ($m, real generation ok, $(( $(date +%s) - t0 ))s)"
  proxy_http_ok || { proxy_cleanup; return 1; }
  return 0
}

case "${1:-status}" in
  status) say "live: $(detect)"; port_ok && say "  :$PORT UP" || say "  :$PORT -";;
  standby) stop_all || exit 1;;
  prod) exec "$0" "$PROD";;
  *)
    target="$1"; modes | grep -qx "$target" || { say "unknown mode $target; modes: $(modes | tr '\n' ' ')"; exit 1; }
    prev="$(detect)" || { say "cannot detect the running mode"; exit 1; }
    if [ "$prev" = "$target" ]; then alive && proxy_http_ok && { say "already $target (generation and proxy ok)"; exit 0; } || say "already $target but not answering — restarting"; fi
    stop_all || exit 1
    if ! start_mode "$target"; then
      back="$prev"; [ "$back" = standby ] || [ "$back" = "$target" ] && back="$PROD"
      say "  rolling back to $back"; stop_all || exit 1; start_mode "$back"; exit 1
    fi
    ;;
esac
