#!/usr/bin/env bash
# Smoke test the OpenAI-compatible endpoint end-to-end.
# Uses kubectl port-forward when no public hostname is reachable (default for
# the internal LB), otherwise hits the hostname directly.
set -euo pipefail

: "${API_KEY:?Set API_KEY to one of the keys you stored in Secret Manager}"
: "${INFERENCE_HOSTNAME:=llm.internal.example.com}"

BASE_URL=""
if curl -sk --max-time 3 "https://${INFERENCE_HOSTNAME}/healthz" >/dev/null 2>&1; then
  BASE_URL="https://${INFERENCE_HOSTNAME}"
else
  echo "==> Hostname not reachable; using port-forward to gateway service"
  kubectl -n gateway port-forward svc/apikey-gateway 8080:80 >/dev/null 2>&1 &
  PF=$!
  trap 'kill $PF 2>/dev/null || true' EXIT
  sleep 2
  BASE_URL="http://localhost:8080"
fi

echo "==> Target: ${BASE_URL}"

echo "==> [1/3] /healthz (unauthenticated)"
curl -sf "${BASE_URL}/healthz" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='ok'; print('   ok')"

echo "==> [2/3] /v1/models with bad key (expect 401)"
code=$(curl -sk -o /dev/null -w '%{http_code}' -H 'X-API-Key: bogus' "${BASE_URL}/v1/models")
if [[ "$code" != "401" ]]; then echo "   FAIL: got $code, expected 401"; exit 1; fi
echo "   ok (401)"

echo "==> [3/3] /v1/chat/completions with valid key"
curl -sk -X POST "${BASE_URL}/v1/chat/completions" \
  -H "X-API-Key: ${API_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "google/gemma-2-9b-it",
    "messages": [
      {"role": "user", "content": "Reply with exactly the word: pong"}
    ],
    "max_tokens": 8,
    "temperature": 0
  }' | python3 -c "
import sys, json
d = json.load(sys.stdin)
content = d['choices'][0]['message']['content']
print(f'   model said: {content!r}')
assert 'pong' in content.lower(), 'expected pong in reply'
"

echo "==> All smoke tests passed."
