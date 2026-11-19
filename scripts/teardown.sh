#!/usr/bin/env bash
# ===========================================================================
# Destroy an environment. Deliberately noisy and hard to run by accident.
#
# Usage:  ./scripts/teardown.sh dev
# ===========================================================================
set -euo pipefail

ENVIRONMENT="${1:-}"
TF_DIR="infra/terraform/envs/${ENVIRONMENT}"

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
info()  { printf '\033[36m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

[ -n "$ENVIRONMENT" ] || { red "Usage: $0 <dev|test|prod>"; exit 1; }
[ -d "$TF_DIR" ] || { red "No such environment: $TF_DIR"; exit 1; }

if [ "$ENVIRONMENT" = "prod" ]; then
  red "=============================================================="
  red " REFUSING to tear down 'prod' from a script."
  red " If you genuinely mean it, run terraform destroy by hand after"
  red " taking a backup and raising a change ticket."
  red "=============================================================="
  exit 1
fi

SUB_NAME=$(az account show --query name -o tsv)
red "=============================================================="
red " DESTRUCTIVE OPERATION"
red "=============================================================="
warn " Subscription : ${SUB_NAME}"
warn " Environment  : ${ENVIRONMENT}"
echo
warn " This permanently deletes:"
warn "   - the AKS cluster and every workload on it"
warn "   - the PostgreSQL server AND ITS DATA"
warn "   - the container registry and all images"
warn "   - the Key Vault (soft-deleted, then purged)"
warn "   - all Log Analytics data"
echo

info "Resources Terraform currently manages:"
terraform -chdir="$TF_DIR" state list 2>/dev/null | head -40 || warn "  (no state found)"
COUNT=$(terraform -chdir="$TF_DIR" state list 2>/dev/null | wc -l | tr -d ' ')
info "  ... ${COUNT} resources total"
echo

read -r -p "Type the environment name to confirm: " confirm
[ "$confirm" = "$ENVIRONMENT" ] || { green "Aborted - nothing was deleted."; exit 0; }
read -r -p "Last chance. Type DESTROY to proceed: " confirm2
[ "$confirm2" = "DESTROY" ] || { green "Aborted - nothing was deleted."; exit 0; }

# ---------------------------------------------- helm first, then terraform
info "Removing Helm releases so finalizers do not block the VNet delete..."
if kubectl config current-context >/dev/null 2>&1; then
  helm uninstall erp -n erp --wait --timeout 5m 2>/dev/null || info "  (no release found)"
  kubectl delete namespace erp --timeout=5m 2>/dev/null || info "  (no namespace found)"
else
  info "  (no kubectl context; skipping)"
fi

# A LoadBalancer Service leaves behind an Azure LB and public IP that are NOT
# in Terraform state. Those orphans then block the resource-group delete. This
# is the single most common teardown failure.
info "Checking for orphaned Kubernetes load balancers..."
NODE_RG=$(terraform -chdir="$TF_DIR" output -raw aks_name 2>/dev/null | sed 's/^aks-/rg-/;s/$/-nodes/' || echo "")
if [ -n "$NODE_RG" ] && az group exists -n "$NODE_RG" 2>/dev/null | grep -q true; then
  warn "  node resource group ${NODE_RG} still exists; Terraform will remove it with the cluster"
fi

info "Running terraform destroy..."
terraform -chdir="$TF_DIR" destroy -auto-approve -lock-timeout=5m

# ------------------------------------------------------------ purge vault
info "Purging any soft-deleted Key Vault so the name can be reused..."
for kv in $(az keyvault list-deleted --query "[?contains(name,'kv-erp')].name" -o tsv 2>/dev/null); do
  az keyvault purge --name "$kv" --no-wait 2>/dev/null \
    && info "  purged ${kv}" \
    || warn "  could not purge ${kv} (purge protection may be on)"
done

echo
green "=============================================================="
green " Teardown of '${ENVIRONMENT}' complete."
green "=============================================================="
info "Verify nothing is left:"
info "  az resource list --query \"[?contains(resourceGroup,'erp-${ENVIRONMENT}')].{n:name,t:type}\" -o table"
info "  ./scripts/cost-check.sh"
