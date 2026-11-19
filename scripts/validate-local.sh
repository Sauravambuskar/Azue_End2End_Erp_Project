#!/usr/bin/env bash
# ===========================================================================
# Run every check the CI pipeline runs, locally, with no Azure account.
#
# Use this before you commit. It is much faster than discovering a lint error
# after a six-minute pipeline run.
#
# Tools that are not installed are SKIPPED, not failed, so this is useful on
# day one and gets stricter as you install more of the toolchain.
#
# Usage:  ./scripts/validate-local.sh
# ===========================================================================
set -uo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
info()  { printf '\033[36m%s\033[0m\n' "$1"; }
skip()  { printf '\033[90m%s\033[0m\n' "$1"; }
head_() { printf '\033[36m----> %s\033[0m\n' "$1"; }

PASS=0
FAIL=0
SKIP=0
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

# run <label> <tool> [args...]
# The tool name is used both for the availability probe and as argv[0].
run() {
  local label="$1"; shift
  local tool="$1"; shift
  if ! command -v "$tool" >/dev/null 2>&1; then
    skip "SKIP  ${label}  (${tool} not installed)"
    SKIP=$((SKIP + 1))
    return
  fi
  head_ "$label"
  if "$tool" "$@" >"$OUT" 2>&1; then
    green "PASS  ${label}"
    PASS=$((PASS + 1))
  else
    red "FAIL  ${label}"
    tail -25 "$OUT" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
}

cd "$(dirname "$0")/.."

# If the project venv exists, put its tools (ruff, bandit, pytest, checkov,
# semgrep) on PATH so the checks run without a global install.
for venv_bin in src/erp-api/.venv/Scripts src/erp-api/.venv/bin; do
  [ -d "$venv_bin" ] && PATH="$(cd "$venv_bin" && pwd):$PATH"
done
export PATH

info "=============================================================="
info " ContosoERP local validation"
info "=============================================================="

# --------------------------------------------------------------- terraform
run "terraform fmt"             terraform fmt -check -recursive infra/terraform
run "terraform validate (dev)"  terraform -chdir=infra/terraform/envs/dev validate
run "terraform validate (prod)" terraform -chdir=infra/terraform/envs/prod validate

# -------------------------------------------------------------------- helm
run "helm lint (dev values)"    helm lint k8s/helm/erp -f k8s/helm/erp/values-dev.yaml
run "helm lint (prod values)"   helm lint k8s/helm/erp -f k8s/helm/erp/values-prod.yaml

if command -v helm >/dev/null 2>&1; then
  head_ "helm template renders"
  if helm template erp k8s/helm/erp -f k8s/helm/erp/values-prod.yaml \
      --set azure.workloadIdentity.api.clientId=00000000-0000-0000-0000-000000000000 \
      --set azure.tenantId=00000000-0000-0000-0000-000000000000 \
      --set config.keyVault.name=placeholder >"$OUT" 2>&1; then
    green "PASS  helm template renders ($(grep -c '^kind:' "$OUT") objects)"
    PASS=$((PASS + 1))
  else
    red "FAIL  helm template renders"
    tail -20 "$OUT" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
fi

# ------------------------------------------------------------------- bicep
if command -v bicep >/dev/null 2>&1; then
  head_ "bicep build (landing zone)"
  # Bicep writes warnings to stderr and still exits 0, so any stderr output
  # is treated as a failure - which is what the pipeline does too.
  if bicep build infra/bicep/landing-zone.bicep --stdout >/dev/null 2>"$OUT" \
     && [ ! -s "$OUT" ]; then
    green "PASS  bicep build (landing zone)"
    PASS=$((PASS + 1))
  else
    red "FAIL  bicep build (landing zone)"
    tail -20 "$OUT" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
else
  skip "SKIP  bicep build  (bicep not installed)"
  SKIP=$((SKIP + 1))
fi

# ------------------------------------------------------------ python tests
# Prefer the project venv so this works without a global pytest.
PY=""
for cand in src/erp-api/.venv/Scripts/python.exe src/erp-api/.venv/bin/python; do
  [ -x "$cand" ] && PY="$(pwd)/$cand" && break
done
if [ -z "$PY" ]; then
  for cand in python3 python py; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import sys' >/dev/null 2>&1; then
      PY="$cand"
      break
    fi
  done
fi

if [ -n "$PY" ]; then
  for svc in erp-api erp-worker; do
    head_ "pytest ($svc)"
    # PYTHONPATH so `from app import ...` resolves with no editable install.
    if (cd "src/$svc" && PYTHONPATH=. "$PY" -m pytest tests -q -o addopts="" \
          -p no:cacheprovider) >"$OUT" 2>&1; then
      green "PASS  pytest ($svc)  $(grep -oE '[0-9]+ passed' "$OUT" | tail -1)"
      PASS=$((PASS + 1))
    else
      red "FAIL  pytest ($svc)"
      tail -25 "$OUT" | sed 's/^/      /'
      FAIL=$((FAIL + 1))
    fi
  done
else
  skip "SKIP  pytest  (no python found)"
  SKIP=$((SKIP + 1))
fi

run "ruff (python)"             ruff check src/erp-api src/erp-worker
run "bandit (python)"           bandit -q -r src/erp-api/app src/erp-worker/app -lll

# -------------------------------------------------------------- node tests
if [ -d src/erp-web/node_modules ]; then
  head_ "eslint (erp-web)"
  if (cd src/erp-web && npx eslint src --max-warnings 0) >"$OUT" 2>&1; then
    green "PASS  eslint (erp-web)"
    PASS=$((PASS + 1))
  else
    red "FAIL  eslint (erp-web)"
    tail -20 "$OUT" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi

  head_ "node:test (erp-web)"
  if (cd src/erp-web && npm test) >"$OUT" 2>&1; then
    green "PASS  node:test (erp-web)  $(grep -oE 'pass [0-9]+' "$OUT" | tail -1)"
    PASS=$((PASS + 1))
  else
    red "FAIL  node:test (erp-web)"
    grep -E "AssertionError|not ok|failing tests" "$OUT" | head -12 | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
else
  skip "SKIP  eslint + node:test (erp-web)  (run: cd src/erp-web && npm install)"
  SKIP=$((SKIP + 2))
fi

# -------------------------------------------------------------------- SAST
# The custom Semgrep rules encode decisions specific to THIS codebase.
run "semgrep (custom ERP rules)" semgrep scan \
  --config security/sast/semgrep-erp.yml --error --metrics off --quiet src/

# ----------------------------------------------------------------- security
run "gitleaks (working tree)"  gitleaks dir . \
  --config security/secrets/gitleaks.toml --redact --no-banner
run "checkov (terraform)"      checkov -d infra/terraform \
  --framework terraform --compact --quiet \
  --skip-check CKV_AZURE_4,CKV_AZURE_6,CKV_TF_1

# --------------------------------------------------------------- json/yaml
head_ "policy JSON is valid"
JSON_OK=true
for f in policy/definitions/*.json policy/initiatives/*.json; do
  [ -f "$f" ] || continue
  if ! "${PY:-python}" -c "import json,sys;json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    red "      invalid JSON: $f"
    JSON_OK=false
  fi
done
if $JSON_OK; then
  green "PASS  policy JSON is valid"
  PASS=$((PASS + 1))
else
  red "FAIL  policy JSON is valid"
  FAIL=$((FAIL + 1))
fi

head_ "pipeline and manifest YAML is valid"
if [ -n "$PY" ] && "$PY" -c "import yaml" 2>/dev/null; then
  if "$PY" scripts/_check_yaml.py >"$OUT" 2>&1; then
    green "PASS  pipeline and manifest YAML is valid"
    PASS=$((PASS + 1))
  else
    red "FAIL  pipeline and manifest YAML is valid"
    tail -10 "$OUT" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
else
  skip "SKIP  YAML validation  (pyyaml not installed)"
  SKIP=$((SKIP + 1))
fi

# ------------------------------------------------------------ doc integrity
head_ "markdown links resolve"
if [ -n "$PY" ]; then
  if "$PY" scripts/_check_links.py >"$OUT" 2>&1; then
    green "PASS  markdown links resolve"
    PASS=$((PASS + 1))
  else
    red "FAIL  markdown links resolve"
    head -15 "$OUT" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
else
  skip "SKIP  markdown links  (no python found)"
  SKIP=$((SKIP + 1))
fi

# -------------------------------------------------------------------- shell
head_ "shell scripts parse"
SH_OK=true
for f in scripts/*.sh; do
  bash -n "$f" 2>>"$OUT" || { red "      syntax error: $f"; SH_OK=false; }
done
if $SH_OK; then
  green "PASS  shell scripts parse"
  PASS=$((PASS + 1))
else
  red "FAIL  shell scripts parse"
  FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------ summary
echo
info "=============================================================="
if [ "$FAIL" -eq 0 ]; then
  green " ALL CHECKS PASSED   (${PASS} passed, ${SKIP} skipped)"
  info "=============================================================="
  exit 0
fi
red " ${FAIL} CHECK(S) FAILED   (${PASS} passed, ${SKIP} skipped)"
info "=============================================================="
exit 1
