#!/usr/bin/env bash
# ===========================================================================
# Configure kubectl for an ERP cluster, correctly, in one command.
#
# Why this exists rather than just `az aks get-credentials`: on an
# Entra-integrated cluster there are two steps, and forgetting the second one
# is the cause of the single most confusing AKS symptom - kubectl hanging, or
# opening a device-code prompt, instead of working.
#
#   1. az aks get-credentials   fetches the kubeconfig
#   2. kubelogin convert-kubeconfig   switches it to a non-interactive
#                               Entra ID flow using your az login session
#
# Usage:  ./scripts/configure-kubectl.sh [dev|test|prod]
# ===========================================================================
set -euo pipefail

ENVIRONMENT="${1:-dev}"
TF_DIR="infra/terraform/envs/${ENVIRONMENT}"
NAMESPACE="${ERP_NAMESPACE:-erp}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
info()  { printf '\033[36m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
die()   { printf '\033[31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

command -v az      >/dev/null || die "Azure CLI not found."
command -v kubectl >/dev/null || die "kubectl not found. Run: az aks install-cli"
[ -d "$TF_DIR" ]              || die "No such environment: $TF_DIR"
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"

# ------------------------------------------------- read the Terraform outputs
info "Reading Terraform outputs from ${TF_DIR}..."
AKS_NAME=$(terraform -chdir="$TF_DIR" output -raw aks_name 2>/dev/null) \
  || die "Could not read aks_name. Has 'terraform apply' run for ${ENVIRONMENT}?"
AKS_RG=$(terraform -chdir="$TF_DIR" output -raw aks_resource_group)

info "Cluster        : ${AKS_NAME}"
info "Resource group : ${AKS_RG}"
echo

# --------------------------------------------------------------- credentials
info "Fetching credentials..."
az aks get-credentials \
  --resource-group "$AKS_RG" \
  --name "$AKS_NAME" \
  --overwrite-existing \
  --only-show-errors

# ------------------------------------------------------------------ kubelogin
# Without this, an Entra-integrated cluster prompts for a device code. In a
# pipeline that means the task hangs until it times out.
if command -v kubelogin >/dev/null 2>&1; then
  info "Converting kubeconfig to non-interactive Entra ID auth..."
  kubelogin convert-kubeconfig -l azurecli
  green "  converted"
else
  warn "kubelogin not found. Install it with:  az aks install-cli"
  warn "Without it, kubectl will prompt for a device code on every command."
fi

# ------------------------------------------------- default to the namespace
kubectl config set-context --current --namespace="$NAMESPACE" >/dev/null
info "Default namespace set to '${NAMESPACE}' - you can drop the -n flag."

# ------------------------------------------------------------------ verify
echo
info "Verifying access..."
if ! kubectl cluster-info >/dev/null 2>&1; then
  die "Cannot reach the cluster.
If this is a PRIVATE cluster, the API server has no public IP and you need to
be inside the VNet - a jump host via Bastion, a self-hosted agent, or:
  az aks command invoke -g ${AKS_RG} -n ${AKS_NAME} --command 'kubectl get pods -n ${NAMESPACE}'

If this is a PUBLIC cluster, check your IP is in the authorized ranges:
  curl -s https://api.ipify.org
  az aks show -g ${AKS_RG} -n ${AKS_NAME} --query apiServerAccessProfile.authorizedIpRanges"
fi

green "Connected."
echo
kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,POOL:.metadata.labels.nodepool-type,VERSION:.status.nodeInfo.kubeletVersion'

echo
info "Your effective permissions in the '${NAMESPACE}' namespace:"
# These four answers tell you immediately which role you have.
for verb_res in "get pods" "create deployments" "get secrets" "create pods/exec"; do
  # shellcheck disable=SC2086
  answer=$(kubectl auth can-i $verb_res -n "$NAMESPACE" 2>/dev/null || echo "no")
  printf "  %-24s %s\n" "$verb_res" "$answer"
done

echo
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" get pods,svc 2>/dev/null || true
else
  warn "Namespace '${NAMESPACE}' does not exist yet. Create it with:"
  warn "  kubectl apply -f k8s/base/namespace.yaml"
fi

echo
green "=============================================================="
green " kubectl configured for ${ENVIRONMENT}"
green "=============================================================="
cat <<EOF

Next:
  kubectl get pods                       # namespace already defaulted
  ./scripts/smoke-test.sh http://localhost:8000
  kubectl port-forward svc/erp-web 3000:3000

If kubectl asks for a device code, kubelogin did not run. Fix with:
  az aks install-cli && kubelogin convert-kubeconfig -l azurecli

If kubectl returns "Forbidden" on everything, you have the Azure control-plane
role but no Kubernetes RBAC binding. Those are two separate systems - see
guidance/04-identity.md section 7.
EOF
