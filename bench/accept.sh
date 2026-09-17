#!/bin/bash
# accept.sh — structural acceptance of a freshly started stack. Asserts behaviour, not "port open".
#   accept.sh <base_url> <served_name> [container_name]
# Checks: served name listed · thinking-off returns content without reasoning · thinking-on returns reasoning ·
# a tool call comes back as tool_calls · the default (no kwargs) behaviour is recorded · engine facts are captured
# from the container log (image digest, KV pool, MoE backend, loaded snapshot) when a container name is given.
B=${1:-http://127.0.0.1:8000/v1}; M=${2:-deepseek-v4-flash-vision-exp}; CT=${3:-}
E=${ACCEPT_EVIDENCE:-./results/evidence.txt}; mkdir -p "$(dirname "$E")"; : > "$E"
FAILS=0
ok(){ [ "$1" = 0 ] || FAILS=$((FAILS+1)); printf '%s %s\n' "$([ "$1" = 0 ] && echo PASS || echo FAIL)" "$2" | tee -a "$E"; }
J='"model":"'"$M"'"'
curl -s -m 8 "$B/models" | grep -q "\"$M\""; ok $? "/v1/models lists $M"
r=$(curl -s -m 120 "$B/chat/completions" -H 'Content-Type: application/json' -d "{$J,\"messages\":[{\"role\":\"user\",\"content\":\"Say PONG\"}],\"max_tokens\":20,\"chat_template_kwargs\":{\"thinking\":false}}")
echo "$r" | python3 -c 'import sys,json;m=json.load(sys.stdin)["choices"][0]["message"];assert m.get("content") and not (m.get("reasoning_content") or m.get("reasoning"))' 2>/dev/null; ok $? "thinking off: content, no reasoning"
r=$(curl -s -m 300 "$B/chat/completions" -H 'Content-Type: application/json' -d "{$J,\"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Answer briefly.\"}],\"max_tokens\":800,\"chat_template_kwargs\":{\"thinking\":true,\"reasoning_effort\":\"low\"}}")
echo "$r" | python3 -c 'import sys,json;m=json.load(sys.stdin)["choices"][0]["message"];assert (m.get("reasoning_content") or m.get("reasoning"))' 2>/dev/null; ok $? "thinking on: reasoning present"
r=$(curl -s -m 300 "$B/chat/completions" -H 'Content-Type: application/json' -d "{$J,\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Austin? Use the tool.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}],\"tool_choice\":\"auto\",\"max_tokens\":800,\"chat_template_kwargs\":{\"thinking\":false}}")
echo "$r" | python3 -c 'import sys,json;m=json.load(sys.stdin)["choices"][0]["message"];assert m.get("tool_calls") and m["tool_calls"][0]["function"]["name"]=="get_weather"' 2>/dev/null; ok $? "tool call returns tool_calls[get_weather]"
r=$(curl -s -m 300 "$B/chat/completions" -H 'Content-Type: application/json' -d "{$J,\"messages\":[{\"role\":\"user\",\"content\":\"Say PONG\"}],\"max_tokens\":300}")
echo "$r" | python3 -c 'import sys,json;m=json.load(sys.stdin)["choices"][0]["message"];print("INFO default (no kwargs): thinking=%s reasoning_len=%d" % (bool(m.get("reasoning_content") or m.get("reasoning")), len(m.get("reasoning_content") or m.get("reasoning") or "")))' | tee -a "$E"
if [ -n "$CT" ]; then
  { docker inspect "$CT" --format '{{.Image}} {{.Config.Image}}'; docker logs "$CT" 2>&1 | grep -a -m1 'non-default args' | cut -c1-2000
    docker logs "$CT" 2>&1 | grep -a -E 'Initializing a V1 LLM engine \(v|GPU KV cache size|MoE backend|snapshots/[0-9a-f]{40}|Hybrid draft loading|InstantTensor loader' | cut -c1-200 | head -8; } >> "$E" 2>&1
fi
echo "evidence -> $E  (FAIL=$FAILS)"
exit $(( FAILS > 0 ))
