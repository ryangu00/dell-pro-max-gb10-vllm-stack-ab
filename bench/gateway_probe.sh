#!/bin/bash
# gateway_probe.sh — during a switch window, prove your gateway kept answering: hit each route in turn
# (each request may wait up to 90 s), sleep 30 s, repeat; log HTTP code and which backend actually served
# it (LiteLLM sets x-litellm-model-name). The key is never written to the log.
#   GATEWAY=http://127.0.0.1:4000 GATEWAY_KEY=... ROUTES="main-a main-b" gateway_probe.sh
G=${GATEWAY:-http://127.0.0.1:4000}; K=${GATEWAY_KEY:?set GATEWAY_KEY}; R=${ROUTES:-main}; L=${PROBE_LOG:-./results/gateway_probe.log}
mkdir -p "$(dirname "$L")"
while true; do
  for m in $R; do
    r=$(curl -s -m 90 -D - -o /dev/null "$G/v1/chat/completions" -H "Authorization: Bearer $K" -H "Content-Type: application/json" \
        -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PONG\"}],\"max_tokens\":8}" 2>/dev/null)
    code=$(printf '%s' "$r" | head -1 | awk '{print $2}'); be=$(printf '%s' "$r" | grep -i '^x-litellm-model-name:' | awk '{print $2}' | tr -d '\r')
    echo "$(date '+%F %T') $m http=${code:-000} backend=${be:-?}" >> "$L"
  done
  sleep 30
done
