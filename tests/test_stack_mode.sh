#!/bin/bash
# Offline switch checks. Every external service is stubbed; only the fake proxy is a real process.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
STACK_TEST_ROOT="$(mktemp -d "$HERE/tests/.stack-mode.XXXXXX")"
export STACK_TEST_DIR="$STACK_TEST_ROOT/state"
mkdir -p "$STACK_TEST_ROOT/bin" "$STACK_TEST_DIR"
REAL_SLEEP="$(command -v sleep)"; export REAL_SLEEP
cleanup() {
  local pid
  if [ -f "$STACK_TEST_ROOT/pids" ]; then
    while read -r pid; do kill "$pid" 2>/dev/null || :; done < "$STACK_TEST_ROOT/pids"
  fi
  rm -rf "$STACK_TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export STACK_TEST_ROOT

cat > "$STACK_TEST_ROOT/bin/stub" <<'STUB'
#!/bin/bash
set -u
proxy_running() {
  [ -s "$STACK_TEST_DIR/proxy.pid" ] || return 1
  local pid; pid="$(cat "$STACK_TEST_DIR/proxy.pid")"
  kill -0 "$pid" 2>/dev/null
}
case "${0##*/}" in
  ssh)
    while [ "${1:-}" = -o ]; do shift 2; done
    export STACK_TEST_NODE="$1"; shift
    case "$*" in
      *'setsid nohup'*) [ ! -f "$STACK_TEST_DIR/proxy_start_fail" ] || exit 1;;
      *'nohup bash'*) [ ! -f "$STACK_TEST_DIR/engine_start_fail" ] || exit 1;;
    esac
    cd "$STACK_TEST_DIR" || exit 1
    exec bash -c "$*";;
  docker)
    case "$1" in
      ps)
        [ ! -f "$STACK_TEST_DIR/query_fail-${STACK_TEST_NODE}" ] || exit 1
        cat "$STACK_TEST_DIR/containers-${STACK_TEST_NODE}";;
      rm)
        [ ! -f "$STACK_TEST_DIR/rm_fail" ] || exit 1
        [ ! -f "$STACK_TEST_DIR/rm_residue" ] || exit 0
        : > "$STACK_TEST_DIR/containers-${STACK_TEST_NODE}"
        rm -f "$STACK_TEST_DIR/engine.started";;
      run)
        echo engine >> "$STACK_TEST_DIR/events"
        echo ct-a > "$STACK_TEST_DIR/containers-H"
        echo ct-a > "$STACK_TEST_DIR/containers-W"
        touch "$STACK_TEST_DIR/engine.started";;
      logs)
        if [ -f "$STACK_TEST_DIR/fatal" ]; then echo 'ValueError: failed to boot'; else echo loading; fi;;
      *) exit 2;;
    esac;;
  curl)
    case "$*" in
      *chat/completions*)
        if [ -f "$STACK_TEST_DIR/dead_generation" ]; then
          echo '{"choices":[{"message":{"content":""}}]}'
        else echo '{"choices":[{"message":{"content":"pong"}}]}'; fi;;
      *:8901/*|*:8902/*)
        case "$*" in
          *:8902/*)
            [ ! -f "$STACK_TEST_DIR/proxy_http_fail" ] || { echo 503; exit 0; }
            [ ! -f "$STACK_TEST_DIR/proxy_curl_fail" ] || { echo 200; exit 7; };;
        esac
        proxy_running && echo 200 || echo 000;;
      *)
        if [ -f "$STACK_TEST_DIR/engine.started" ] && [ ! -f "$STACK_TEST_DIR/fatal" ] && [ ! -f "$STACK_TEST_DIR/timeout" ]; then
          echo 200
        else echo 000; fi;;
    esac;;
  ss)
    [ ! -f "$STACK_TEST_DIR/ss_fail-${STACK_TEST_NODE}" ] || exit 1
    if [ -f "$STACK_TEST_DIR/hidden_listener-${STACK_TEST_NODE}" ]; then
      echo 'LISTEN 0 128 *:8902 *:*'
    fi
    [ "$STACK_TEST_NODE" = H ] || exit 0
    proxy_running || exit 0
    pid="$(cat "$STACK_TEST_DIR/proxy.pid")"
    for p in 8901 8902; do
      owner="$pid"
      if [ "$p" = 8902 ]; then
        [ ! -f "$STACK_TEST_DIR/foreign.pid" ] || owner="$(cat "$STACK_TEST_DIR/foreign.pid")"
        [ ! -f "$STACK_TEST_DIR/missing_port" ] || continue
        [ ! -f "$STACK_TEST_DIR/wrong_port" ] || p=18902
      fi
      echo "LISTEN 0 128 *:$p *:* users:((\"proxy\",pid=$owner,fd=3))"
    done;;
  setsid)
    echo $$ > "$STACK_TEST_DIR/proxy.pid"
    echo $$ >> "$STACK_TEST_ROOT/pids"
    echo proxy >> "$STACK_TEST_DIR/events"
    exec "$@";;
  stop-proxy)
    [ ! -f "$STACK_TEST_DIR/proxy_stop_fail" ] || exit 1
    if proxy_running; then
      kill "$(cat "$STACK_TEST_DIR/proxy.pid")" || exit 1
      for n in {1..50}; do proxy_running || exit 0; "$REAL_SLEEP" 0.01; done
      exit 1
    fi;;
  mode-stop) [ ! -f "$STACK_TEST_DIR/stop_fail" ];;
  sleep)
    tick="$1"; [ ! -f "$STACK_TEST_DIR/timeout" ] || tick=900
    echo "$(( $(cat "$STACK_TEST_DIR/clock") + tick ))" > "$STACK_TEST_DIR/clock"
    "$REAL_SLEEP" 0.02;;
  date) [ "$1" = +%s ] || exit 2; cat "$STACK_TEST_DIR/clock";;
  sudo|sync) exit 0;;
  *) exit 2;;
esac
STUB
chmod +x "$STACK_TEST_ROOT/bin/stub"
for name in ssh docker curl ss sudo setsid sleep date sync stop-proxy mode-stop; do
  ln -s stub "$STACK_TEST_ROOT/bin/$name"
done
export PATH="$STACK_TEST_ROOT/bin:$PATH"
export STACK_MODES="$STACK_TEST_DIR/modes.yaml"
export STACK_LOG_DIR="$STACK_TEST_DIR/logs"

reset_case() {
  stop-proxy || :
  rm -rf "$STACK_TEST_DIR"
  mkdir -p "$STACK_TEST_DIR"
  : > "$STACK_TEST_DIR/containers-H"; : > "$STACK_TEST_DIR/containers-W"
  : > "$STACK_TEST_DIR/events"; echo 0 > "$STACK_TEST_DIR/clock"
  cat > "$STACK_MODES" <<'YAML'
head: H
worker: W
api: <api>
port: 8899
served_name: model
prod: a
proxy_start: "tail -f /dev/null"
proxy_kill: "stop-proxy"
proxy_ports: "8901 8902"
modes:
  a:
    container: ct-a
    start: "docker run -d ct-a"
    stop: "mode-stop"
YAML
}
passed=0; failed=0
check() {
  local label="$1"; shift
  if "$@"; then echo "PASS $label"; passed=$((passed+1))
  else echo "FAIL $label"; failed=$((failed+1)); cat "$STACK_TEST_DIR/output"; fi
}
run_mode() { bash "$HERE/switch/stack-mode.sh" "$1" > "$STACK_TEST_DIR/output" 2>&1; rc=$?; }
engine_count() { awk '$0 == "engine" {n++} END {print n+0}' "$STACK_TEST_DIR/events"; }
no_proxy() {
  local pid
  while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then return 1; fi
  done < "$STACK_TEST_ROOT/pids"
}

reset_case; run_mode a
check 'normal switch exits 0' test "$rc" -eq 0
check 'engine launched exactly once' test "$(engine_count)" -eq 1
check 'proxy launch precedes engine launch' test "$(sed -n '1p' "$STACK_TEST_DIR/events")" = proxy
run_mode a
check 'healthy same-mode switch does not relaunch' test "$(engine_count)" -eq 1
run_mode standby
check 'normal standby exits 0' test "$rc" -eq 0
check 'normal standby cleans the proxy' no_proxy

reset_case
tail -f /dev/null & foreign_pid=$!
echo "$foreign_pid" >> "$STACK_TEST_ROOT/pids"
echo "$foreign_pid" > "$STACK_TEST_DIR/foreign.pid"
run_mode a
check 'foreign PID on a proxy port exits non-zero' test "$rc" -ne 0
check 'foreign PID prevents every engine launch' test "$(engine_count)" -eq 0
check 'foreign process survives proxy cleanup' kill -0 "$foreign_pid"
kill "$foreign_pid"; wait "$foreign_pid" 2>/dev/null || :
check 'ownership timeout cleans every launched proxy' no_proxy

for fault in proxy_http_fail proxy_curl_fail; do
  reset_case; touch "$STACK_TEST_DIR/$fault"; run_mode a
  check "$fault exits non-zero" test "$rc" -ne 0
  check "$fault is checked after engine launch" test "$(engine_count)" -eq 2
  check "$fault cleans the proxy" no_proxy
done

for fault in rm_fail rm_residue; do
  reset_case; echo ct-a > "$STACK_TEST_DIR/containers-W"; touch "$STACK_TEST_DIR/$fault"; run_mode standby
  check "$fault makes standby exit non-zero" test "$rc" -ne 0
  check "$fault suppresses all-stopped success" test "$(grep -c 'all stopped' "$STACK_TEST_DIR/output")" -eq 0
  run_mode a
  check "$fault blocks the next engine launch" test "$(engine_count)" -eq 0
done

for fault in stop_fail proxy_stop_fail query_fail-H query_fail-W ss_fail-H ss_fail-W hidden_listener-H hidden_listener-W; do
  reset_case; touch "$STACK_TEST_DIR/$fault"; run_mode standby
  check "$fault makes standby exit non-zero" test "$rc" -ne 0
done

for fault in proxy_start_fail missing_port wrong_port engine_start_fail fatal timeout dead_generation; do
  reset_case; touch "$STACK_TEST_DIR/$fault"; run_mode a
  check "$fault makes switch exit non-zero" test "$rc" -ne 0
  case "$fault" in
    fatal|timeout|dead_generation) expected=2;;
    *) expected=0;;
  esac
  check "$fault reaches the expected launch stage" test "$(engine_count)" -eq "$expected"
  if [ "$fault" = fatal ] || [ "$fault" = timeout ]; then
    check "$fault saves head logs" test -s "$STACK_LOG_DIR/stack-mode-a-head.log"
    check "$fault saves worker logs" test -s "$STACK_LOG_DIR/stack-mode-a-worker.log"
  fi
  check "$fault cleans every launched proxy" no_proxy
done

# An up container with dead generation must not take the same-mode shortcut.
reset_case; echo ct-a > "$STACK_TEST_DIR/containers-H"
touch "$STACK_TEST_DIR/engine.started" "$STACK_TEST_DIR/dead_generation"; run_mode a
check 'dead same-mode generation attempts a restart' test "$(engine_count)" -ge 1
check 'dead same-mode generation exits non-zero' test "$rc" -ne 0

reset_case
sed '/^proxy_/d' "$STACK_MODES" > "$STACK_TEST_DIR/no-proxy.yaml"
export STACK_MODES="$STACK_TEST_DIR/no-proxy.yaml"
run_mode a
check 'optional proxy can be omitted' test "$rc" -eq 0

echo "Results: $passed passed, $failed failed"
test "$failed" -eq 0
