#!/usr/bin/env bash
# ===========================================================================
# Post-deployment smoke test.
#
# Exercises a complete ERP business transaction against a live deployment:
#   create master data -> purchase -> receive -> sell -> ship -> invoice
#   -> assert the general ledger balances
#
# This is the test that proves the deployment actually WORKS, as opposed to
# "the pods are Running". Worth calling out in the interview: readiness
# probes tell you a process is listening; only a business-level smoke test
# tells you the system is correct.
#
# Usage:  ./scripts/smoke-test.sh http://localhost:8000
# ===========================================================================
set -euo pipefail

BASE="${1:-http://localhost:8000}"
API="${BASE}/api/v1"
STAMP=$(date +%s)
PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
info()  { printf '\033[36m%s\033[0m\n' "$1"; }

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    green "  PASS  ${label}"
    PASS=$((PASS + 1))
  else
    red   "  FAIL  ${label} (expected ${expected}, got ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

# Returns the HTTP status; writes the body to $BODY_FILE.
# Deliberately NOT mktemp: on Windows/Git Bash, mktemp returns a POSIX path
# like /tmp/xxx that the native python interpreter cannot open. A file beside
# the script works on every platform.
BODY_FILE="./.smoke-body.$$.json"
trap 'rm -f "$BODY_FILE"' EXIT

# Find a WORKING python. On Windows a "python3" shim often exists on PATH but
# only prints a Microsoft Store advert, so each candidate is actually executed
# before it is accepted.
PY=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1      && "$candidate" -c 'import json' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  red "No working python interpreter found - needed to parse JSON responses."
  exit 1
fi

req() {
  local method="$1" url="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -o "$BODY_FILE" -w '%{http_code}' \
      -X "$method" -H 'Content-Type: application/json' -d "$data" "$url"
  else
    curl -sS -o "$BODY_FILE" -w '%{http_code}' -X "$method" "$url"
  fi
}

jsonval() { "$PY" -c "import json;print(json.load(open('$BODY_FILE'))$1)"; }

info "=== ContosoERP smoke test against ${BASE} ==="

# ------------------------------------------------------------------ health
info "[1/8] Health probes"
check "liveness returns 200"  200 "$(req GET "${BASE}/healthz/live")"
check "readiness returns 200" 200 "$(req GET "${BASE}/healthz/ready")"
DB_STATE=$(jsonval "['database']")
check "database reports up" "up" "$DB_STATE"

info "[2/8] Security headers"
HEADERS=$(curl -sSI "${BASE}/healthz/live")
echo "$HEADERS" | grep -qi 'x-content-type-options: nosniff' \
  && { green "  PASS  X-Content-Type-Options"; PASS=$((PASS+1)); } \
  || { red "  FAIL  X-Content-Type-Options missing"; FAIL=$((FAIL+1)); }
echo "$HEADERS" | grep -qi 'x-frame-options: DENY' \
  && { green "  PASS  X-Frame-Options"; PASS=$((PASS+1)); } \
  || { red "  FAIL  X-Frame-Options missing"; FAIL=$((FAIL+1)); }

# ------------------------------------------------------------ master data
info "[3/8] Master data"
STATUS=$(req POST "${API}/warehouses" \
  "{\"code\":\"SMK${STAMP: -4}\",\"name\":\"Smoke test DC\"}")
check "create warehouse" 201 "$STATUS"
WH_ID=$(jsonval "['id']")

STATUS=$(req POST "${API}/suppliers" \
  "{\"code\":\"SMKS${STAMP: -4}\",\"name\":\"Smoke Supplier\"}")
check "create supplier" 201 "$STATUS"
SUP_ID=$(jsonval "['id']")

STATUS=$(req POST "${API}/customers" \
  "{\"code\":\"SMKC${STAMP: -4}\",\"name\":\"Smoke Customer\",\"credit_limit\":\"100000\"}")
check "create customer" 201 "$STATUS"
CUST_ID=$(jsonval "['id']")

STATUS=$(req POST "${API}/products" \
  "{\"sku\":\"SMOKE-${STAMP: -6}\",\"name\":\"Smoke widget\",\"category\":\"components\",\"unit_price\":\"500\",\"standard_cost\":\"300\",\"reorder_point\":\"10\"}")
check "create product" 201 "$STATUS"
PROD_ID=$(jsonval "['id']")

# ------------------------------------------------------- input validation
info "[4/8] Input validation (negative tests)"
check "reject malformed SKU" 422 \
  "$(req POST "${API}/products" '{"sku":"bad sku!","name":"x","unit_price":"1"}')"
check "reject negative price" 422 \
  "$(req POST "${API}/products" '{"sku":"NEG-1","name":"x","unit_price":"-5"}')"
check "reject unknown product in order" 400 \
  "$(req POST "${API}/sales-orders" \
     "{\"customer_id\":${CUST_ID},\"warehouse_id\":${WH_ID},\"lines\":[{\"product_id\":999999,\"quantity\":\"1\"}]}")"

# ------------------------------------------------------------- purchasing
info "[5/8] Purchase and goods receipt"
STATUS=$(req POST "${API}/purchase-orders" \
  "{\"supplier_id\":${SUP_ID},\"warehouse_id\":${WH_ID},\"lines\":[{\"product_id\":${PROD_ID},\"quantity\":\"100\",\"unit_cost\":\"300\"}]}")
check "create purchase order" 201 "$STATUS"
PO_ID=$(jsonval "['id']")
check "PO total is 30000" "30000.0000" "$(jsonval "['total_amount']")"

check "receive goods" 200 "$(req POST "${API}/purchase-orders/${PO_ID}/receive")"

STATUS=$(req GET "${API}/inventory/stock/${PROD_ID}?warehouse_id=${WH_ID}")
check "stock query returns 200" 200 "$STATUS"
check "stock on hand is 100" "100.0000" "$(jsonval "['on_hand']")"

# ------------------------------------------------------------------ sales
info "[6/8] Sales order lifecycle"
STATUS=$(req POST "${API}/sales-orders" \
  "{\"customer_id\":${CUST_ID},\"warehouse_id\":${WH_ID},\"lines\":[{\"product_id\":${PROD_ID},\"quantity\":\"10\",\"unit_price\":\"500\",\"discount_pct\":\"10\"}]}")
check "create sales order" 201 "$STATUS"
SO_ID=$(jsonval "['id']")
check "order total is 4500 (10 x 500 less 10%)" "4500.0000" "$(jsonval "['total_amount']")"

for next in confirmed picked shipped invoiced; do
  check "transition to ${next}" 200 \
    "$(req POST "${API}/sales-orders/${SO_ID}/status" "{\"status\":\"${next}\"}")"
done

info "[7/8] Business rule enforcement"
STATUS=$(req POST "${API}/sales-orders" \
  "{\"customer_id\":${CUST_ID},\"warehouse_id\":${WH_ID},\"lines\":[{\"product_id\":${PROD_ID},\"quantity\":\"999999\"}]}")
BIG_SO=$(jsonval "['id']")
req POST "${API}/sales-orders/${BIG_SO}/status" '{"status":"confirmed"}' >/dev/null
req POST "${API}/sales-orders/${BIG_SO}/status" '{"status":"picked"}'    >/dev/null
check "oversell is blocked with 409" 409 \
  "$(req POST "${API}/sales-orders/${BIG_SO}/status" '{"status":"shipped"}')"
check "illegal transition is blocked" 409 \
  "$(req POST "${API}/sales-orders/${SO_ID}/status" '{"status":"draft"}')"

# ---------------------------------------------------------------- finance
info "[8/8] Financial integrity"
STATUS=$(req GET "${API}/finance/trial-balance")
check "trial balance returns 200" 200 "$STATUS"
NET=$("$PY" - <<PY
import json
rows = json.load(open("$BODY_FILE"))
print(f"{sum(float(r['balance']) for r in rows):.4f}")
PY
)
check "ledger is balanced (debits = credits)" "0.0000" "$NET"

# ----------------------------------------------------------------- result
echo
info "==============================================="
if [ "$FAIL" -eq 0 ]; then
  green "ALL SMOKE TESTS PASSED  (${PASS} checks)"
  info "==============================================="
  exit 0
fi
red "SMOKE TESTS FAILED  (${PASS} passed, ${FAIL} failed)"
info "==============================================="
exit 1
