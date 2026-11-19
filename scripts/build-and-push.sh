#!/usr/bin/env bash
# ===========================================================================
# Build, scan and push all four ERP images.
#
# Mirrors exactly what the pipeline does, so you can reproduce a CI failure
# locally instead of debugging by pushing commits.
#
# Usage:  ./scripts/build-and-push.sh <acr-login-server> <tag> [--no-scan]
# Example: ./scripts/build-and-push.sh acrerpdevab12cd.azurecr.io v0.1.0
# ===========================================================================
set -euo pipefail

REGISTRY="${1:-}"
TAG="${2:-dev-$(date +%Y%m%d%H%M)}"
SCAN=true
[ "${3:-}" = "--no-scan" ] && SCAN=false

green() { printf '\033[32m%s\033[0m\n' "$1"; }
info()  { printf '\033[36m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
die()   { printf '\033[31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

[ -n "$REGISTRY" ] || die "Usage: $0 <acr-login-server> <tag> [--no-scan]"
command -v docker >/dev/null || die "docker not found"

GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")

# repo:dockerfile:context
IMAGES=(
  "erp-api:src/erp-api/Dockerfile:src/erp-api"
  "erp-web:src/erp-web/Dockerfile:src/erp-web"
  "erp-worker:src/erp-worker/Dockerfile:src/erp-worker"
  "erp-migrate:db/Dockerfile:."
)

info "=============================================================="
info "Registry : ${REGISTRY}"
info "Tag      : ${TAG}"
info "Git SHA  : ${GIT_SHA}"
info "Scanning : ${SCAN}"
info "=============================================================="

# ACR login uses your Entra ID identity - no admin user, no password.
if [[ "$REGISTRY" == *.azurecr.io ]]; then
  ACR_NAME="${REGISTRY%%.*}"
  info "Logging in to ACR ${ACR_NAME}..."
  az acr login --name "$ACR_NAME" >/dev/null || die "az acr login failed"
fi

FAILED=()
for entry in "${IMAGES[@]}"; do
  IFS=':' read -r repo dockerfile context <<< "$entry"
  full="${REGISTRY}/${repo}:${TAG}"

  echo
  info "---------- ${repo} ----------"
  info "Building ${full}"
  docker build \
    --file "$dockerfile" \
    --tag "$full" \
    --tag "${REGISTRY}/${repo}:latest" \
    --build-arg "BUILD_VERSION=${TAG}" \
    --build-arg "GIT_SHA=${GIT_SHA}" \
    "$context" \
    || { FAILED+=("$repo (build)"); continue; }

  SIZE=$(docker image inspect "$full" --format '{{.Size}}' | awk '{printf "%.1f MB", $1/1024/1024}')
  green "  built: ${SIZE}"

  # Verify the image does NOT run as root. Cheap check, catches a very
  # common regression that the Gatekeeper policy would reject at deploy time.
  USER_ID=$(docker image inspect "$full" --format '{{.Config.User}}')
  if [ -z "$USER_ID" ] || [ "$USER_ID" = "0" ] || [ "$USER_ID" = "root" ]; then
    warn "  image runs as ROOT - the AKS policy will reject it"
    FAILED+=("$repo (runs as root)")
    continue
  fi
  green "  runs as uid: ${USER_ID}"

  if [ "$SCAN" = true ] && command -v trivy >/dev/null; then
    info "  scanning (fail on CRITICAL with a fix available)..."
    trivy image "$full" --severity HIGH,CRITICAL --format table --exit-code 0
    if ! trivy image "$full" --severity CRITICAL --ignore-unfixed --exit-code 1 -q; then
      FAILED+=("$repo (critical CVE)")
      continue
    fi
    green "  scan clean"
  elif [ "$SCAN" = true ]; then
    warn "  trivy not installed - skipping the scan gate"
    warn "  install:  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh"
  fi

  info "  pushing..."
  docker push "$full" >/dev/null || { FAILED+=("$repo (push)"); continue; }
  green "  pushed ${full}"
done

echo
if [ ${#FAILED[@]} -gt 0 ]; then
  printf '\033[31mFAILED: %s\033[0m\n' "${FAILED[*]}"
  exit 1
fi

green "=============================================================="
green "All images built, verified and pushed with tag ${TAG}"
green "=============================================================="
cat <<EOF

Deploy them:

  helm upgrade --install erp k8s/helm/erp \
    --namespace erp --create-namespace \
    -f k8s/helm/erp/values-dev.yaml \
    --set image.registry=${REGISTRY} \
    --set image.tag=${TAG} \
    --atomic --wait

Confirm what is in the registry:

  az acr repository show-tags --name ${ACR_NAME:-<acr>} --repository erp-api -o table
EOF
