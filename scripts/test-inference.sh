#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:-dev}"
NAMESPACE="ml-inference-${ENVIRONMENT}"

echo "==> Running smoke tests against ${ENVIRONMENT}..."

# Get the service URL
if kubectl get ingress -n "${NAMESPACE}" &>/dev/null; then
  HOST=$(kubectl get ingress -n "${NAMESPACE}" -o jsonpath='{.items[0].spec.rules[0].host}')
  BASE_URL="https://${HOST}"
else
  kubectl port-forward svc/ml-inference 8080:80 -n "${NAMESPACE}" &
  PF_PID=$!
  trap "kill ${PF_PID} 2>/dev/null || true" EXIT
  sleep 2
  BASE_URL="http://localhost:8080"
fi

echo "==> Testing ${BASE_URL}..."

# Liveness
STATUS=$(curl -sf "${BASE_URL}/healthz" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d['status']=='ok' else 1)")
echo "  [OK] /healthz"

# Model list
curl -sf "${BASE_URL}/v1/models" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'models' in d, 'Missing models key'
print(f'  [OK] /v1/models: {len(d[\"models\"])} model(s) loaded')
"

# Inference
curl -sf -X POST "${BASE_URL}/v1/infer" \
  -H "Content-Type: application/json" \
  -d '{"model_name":"echo","model_version":"latest","inputs":[{"name":"x","data":[1,2,3]}]}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['model_name'] == 'echo'
assert d['outputs'][0]['data'] == [1, 2, 3]
print('  [OK] /v1/infer: echo roundtrip passed')
"

echo "==> All smoke tests passed!"
