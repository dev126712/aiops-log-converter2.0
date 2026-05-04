#!/usr/bin/env bash
# ============================================================
# inject_logs.sh — push test logs directly into Loki
#
# Uses curl from the HOST to localhost:3100 (port is exposed).
# This avoids all docker exec / shell-escaping issues.
#
# Usage:
#   chmod +x inject_logs.sh
#   ./inject_logs.sh              # all scenarios
#   ./inject_logs.sh normal
#   ./inject_logs.sh anomaly
#   ./inject_logs.sh fatal
#   ./inject_logs.sh file sample_logs/mixed.log
# ============================================================

set -euo pipefail

LOKI_PUSH_URL="http://localhost:3100/loki/api/v1/push"
SCENARIO="${1:-all}"

# ── Colour helpers ────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Timestamp helpers ─────────────────────────────────────────
offset_ns() { echo $(( $(date +%s%N) - ($1 * 1000000000) )); }

# ── Core push — writes payload to a tmp file, avoids all escaping issues ──
push_log() {
  local job="$1" level="$2" message="$3" ts="$4"
  local tmp
  tmp=$(mktemp /tmp/loki_payload_XXXXXX.json)

  # Use python to build the JSON safely — no manual escaping needed
  python3 - <<PYEOF > "$tmp"
import json, sys
payload = {
    "streams": [{
        "stream": {
            "job":         "${job}",
            "level":       "${level}",
            "environment": "test",
            "host":        "aiops-inject"
        },
        "values": [["${ts}", ${message}]]
    }]
}
# If message is already a JSON string wrap it as a plain string value
try:
    json.loads(${message})
    # it parsed — it's valid JSON, but Loki wants a string value
    payload["streams"][0]["values"][0][1] = ${message}
except:
    pass
print(json.dumps(payload))
PYEOF

  # Rebuild cleanly — always treat message as a plain string
  python3 -c "
import json
payload = {
    'streams': [{
        'stream': {
            'job':         '$job',
            'level':       '$level',
            'environment': 'test',
            'host':        'aiops-inject'
        },
        'values': [['$ts', '''$message''']]
    }]
}
print(json.dumps(payload))
" > "$tmp"

  curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST \
    --data-binary "@${tmp}" \
    "${LOKI_PUSH_URL}" | grep -qE "^2" || warn "Push returned non-2xx for: $message"

  rm -f "$tmp"
}

# ── Batch push from array ─────────────────────────────────────
push_batch() {
  local job="$1" level="$2" ts_offset="$3"
  shift 3
  local messages=("$@")
  local tmp
  tmp=$(mktemp /tmp/loki_batch_XXXXXX.json)

  python3 - "$job" "$level" "$ts_offset" "${messages[@]}" <<'PYEOF' > "$tmp"
import json, sys, time

job       = sys.argv[1]
level     = sys.argv[2]
offset    = int(sys.argv[3])
messages  = sys.argv[4:]

base_ns = int(time.time() * 1e9) - (offset * 1_000_000_000)
values  = [
    [str(base_ns + i * 2_000_000), msg]   # 2ms apart
    for i, msg in enumerate(messages)
]

payload = {
    "streams": [{
        "stream": {"job": job, "level": level, "environment": "test", "host": "aiops-inject"},
        "values": values
    }]
}
print(json.dumps(payload))
PYEOF

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST \
    --data-binary "@${tmp}" \
    "${LOKI_PUSH_URL}")

  if [[ "$http_code" =~ ^2 ]]; then
    info "  ✓ Pushed ${#messages[@]} lines (HTTP $http_code)"
  else
    warn "  ✗ Push failed (HTTP $http_code)"
  fi

  rm -f "$tmp"
}

# ── File push ─────────────────────────────────────────────────
push_file() {
  local file="$1" job="${2:-fluent-bit}"
  [[ ! -f "$file" ]] && { warn "File not found: $file"; return; }
  info "Pushing file: $file → job=$job"

  local tmp
  tmp=$(mktemp /tmp/loki_file_XXXXXX.json)

  python3 - "$file" "$job" <<'PYEOF' > "$tmp"
import json, sys, time

file = sys.argv[1]
job  = sys.argv[2]

values = []
base_ns = int(time.time() * 1e9) - (300 * 1_000_000_000)   # start 5min ago

with open(file) as f:
    for i, line in enumerate(f):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        ts = str(base_ns + i * 1_000_000)   # 1ms per line
        values.append([ts, line])

# Loki max batch: 4MB — chunk into 50-line batches
chunk_size = 50
streams = []
for i in range(0, len(values), chunk_size):
    chunk = values[i:i+chunk_size]
    # Derive level from content
    sample = chunk[0][1].lower()
    if "fatal" in sample or "critical" in sample or "panic" in sample:
        level = "FATAL"
    elif "error" in sample or "exception" in sample:
        level = "ERROR"
    elif "warn" in sample:
        level = "WARN"
    else:
        level = "INFO"
    streams.append({
        "stream": {"job": job, "level": level, "environment": "test", "host": "aiops-inject"},
        "values": chunk
    })

print(json.dumps({"streams": streams}))
PYEOF

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST \
    --data-binary "@${tmp}" \
    "${LOKI_PUSH_URL}")

  if [[ "$http_code" =~ ^2 ]]; then
    info "  ✓ File pushed (HTTP $http_code)"
  else
    error "  ✗ File push failed (HTTP $http_code)"
    cat "$tmp" | python3 -m json.tool > /dev/null || error "    Payload was invalid JSON"
  fi

  rm -f "$tmp"
}


# ============================================================
# SCENARIOS
# ============================================================

scenario_normal() {
  info "=== SCENARIO: Normal baseline traffic ==="
  local msgs=(
    '{"level":"INFO","service":"api-gateway","msg":"GET /api/v1/health 200 OK","latency_ms":12}'
    '{"level":"INFO","service":"auth-service","msg":"JWT validated successfully","user_id":"u-9981"}'
    '{"level":"INFO","service":"order-service","msg":"Order created","order_id":"ord-4421","amount":149.99}'
    '{"level":"INFO","service":"payment-service","msg":"Payment processed","provider":"stripe","status":"success"}'
    '{"level":"WARN","service":"cache-layer","msg":"Cache miss — falling back to DB","key":"product:8812"}'
    '{"level":"INFO","service":"inventory","msg":"Stock level check passed","sku":"SKU-007","stock":142}'
    '{"level":"WARN","service":"api-gateway","msg":"Rate limit approaching threshold","current":870,"limit":1000}'
    '{"level":"INFO","service":"notification","msg":"Email dispatched","template":"order_confirm"}'
    '{"level":"INFO","service":"api-gateway","msg":"GET /api/v1/products 200 OK","latency_ms":18}'
    '{"level":"INFO","service":"search-service","msg":"Search executed","results":42,"latency_ms":67}'
  )
  push_batch "fluent-bit" "INFO" 60 "${msgs[@]}"
}

scenario_anomaly() {
  info "=== SCENARIO: Anomaly burst — ERROR spike ==="
  local msgs=(
    '{"level":"ERROR","service":"payment-service","msg":"Stripe API timeout after 5000ms","retry":1}'
    '{"level":"ERROR","service":"payment-service","msg":"Stripe API timeout after 5000ms","retry":2}'
    '{"level":"ERROR","service":"payment-service","msg":"Stripe API timeout after 5000ms","retry":3}'
    '{"level":"ERROR","service":"payment-service","msg":"Payment failed — max retries exceeded","order_id":"ord-5591"}'
    '{"level":"ERROR","service":"db-pool","msg":"Connection pool exhausted","pool_size":20,"waiting":47}'
    '{"level":"ERROR","service":"order-service","msg":"Downstream payment-service unreachable","circuit_state":"OPEN"}'
    '{"level":"ERROR","service":"api-gateway","msg":"POST /api/v1/orders 503 Service Unavailable","latency_ms":5012}'
    '{"level":"WARN","service":"alert-manager","msg":"CPU load 91% — above warning threshold","cpu_pct":91.4}'
    '{"level":"ERROR","service":"cache-layer","msg":"Redis READONLY — failover in progress"}'
    '{"level":"ERROR","service":"session-store","msg":"Failed to persist session","error":"connection refused"}'
  )
  push_batch "fluent-bit" "ERROR" 30 "${msgs[@]}"
}

scenario_fatal() {
  info "=== SCENARIO: Fatal meltdown ==="
  local msgs=(
    '{"level":"FATAL","service":"order-service","msg":"Unhandled panic: nil pointer dereference","goroutine":42}'
    '{"level":"FATAL","service":"auth-service","msg":"JWT signing key missing — all auth will fail"}'
    '{"level":"ERROR","service":"db-primary","msg":"Disk usage at 99.1% — writes may fail","used_gb":499}'
    '{"level":"FATAL","service":"api-gateway","msg":"Process OOM-killed by kernel","pid":1204,"rss_mb":3800}'
    '{"level":"ERROR","service":"k8s-node","msg":"Node NotReady","node":"worker-02","condition":"MemoryPressure"}'
    '{"level":"FATAL","service":"message-broker","msg":"Kafka partition leader election failed"}'
    '{"level":"ERROR","service":"api-gateway","msg":"All upstream health checks failing","healthy_upstreams":0}'
    '{"level":"FATAL","service":"config-service","msg":"etcd cluster quorum lost"}'
  )
  push_batch "fluent-bit" "FATAL" 10 "${msgs[@]}"
}


# ── Verify Loki reachable ─────────────────────────────────────
verify_loki() {
  info "Checking Loki is ready..."
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3100/ready")
  if [[ "$http_code" != "200" ]]; then
    error "Loki not ready (HTTP $http_code). Is the stack running?"
    error "Run: docker compose up -d"
    exit 1
  fi
  info "  ✓ Loki is ready"
}

# ── Check curl is available ───────────────────────────────────
command -v curl >/dev/null 2>&1 || { error "curl is required: sudo apt install curl"; exit 1; }
command -v python3 >/dev/null 2>&1 || { error "python3 is required"; exit 1; }

verify_loki

case "$SCENARIO" in
  normal)   scenario_normal ;;
  anomaly)  scenario_anomaly ;;
  fatal)    scenario_fatal ;;
  file)     push_file "${2:-sample_logs/mixed.log}" ;;
  all)
    scenario_normal;  sleep 1
    scenario_anomaly; sleep 1
    scenario_fatal;   sleep 1
    push_file "sample_logs/mixed.log"
    ;;
  *)
    error "Unknown scenario: $SCENARIO"
    echo "Usage: $0 [normal|anomaly|fatal|file|all]"
    exit 1
    ;;
esac

echo ""
info "=== Done! ==="
info "    Grafana → Explore → Loki"
info "    LogQL:  {job=\"fluent-bit\", environment=\"test\"}"
info "    Or trigger pipeline: docker compose restart aiops-pipeline"
