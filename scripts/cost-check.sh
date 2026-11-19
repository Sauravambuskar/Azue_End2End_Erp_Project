#!/usr/bin/env bash
# ===========================================================================
# Cost guard. Run this EVERY TIME you finish a practice session.
#
# The most common way people lose money learning Azure is not an expensive
# mistake - it is forgetting that something cheap was left running for three
# weeks. This script tells you what is currently costing money and what the
# single biggest lever is.
#
# Usage:  ./scripts/cost-check.sh
# ===========================================================================
set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
info()  { printf '\033[36m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }

az account show >/dev/null 2>&1 || { red "Run: az login"; exit 1; }
SUB_ID=$(az account show --query id -o tsv)
info "Subscription: $(az account show --query name -o tsv)"
echo

# --------------------------------------------------- month-to-date spend
info "=== Month-to-date cost ==="
START=$(date -u +%Y-%m-01)
END=$(date -u +%Y-%m-%d)
az consumption usage list \
  --start-date "$START" --end-date "$END" \
  --query "[].{svc:meterDetails.meterCategory, cost:pretaxCost, cur:currency}" \
  -o tsv 2>/dev/null \
  | awk -F'\t' '{ s[$1]+=$2; cur=$3 } END {
      printf "%-42s %12s\n", "SERVICE", "COST";
      total=0;
      for (k in s) { printf "%-42s %12.2f\n", k, s[k]; total+=s[k] }
      printf "%-42s %12.2f %s\n", "TOTAL", total, cur
    }' \
  | sort -k2 -rn \
  || warn "Consumption API unavailable (normal on a brand-new or free-trial subscription)."
echo

# ------------------------------------------------ the expensive resources
info "=== Resources that bill by the hour whether you use them or not ==="
printf "%-16s %-42s %s\n" "TYPE" "NAME" "STATE/SKU"
printf '%.0s-' {1..80}; echo

# AKS clusters: the nodes cost money, the control plane is free on the Free tier
az aks list --query "[].{n:name, rg:resourceGroup, c:agentPoolProfiles[0].count, s:agentPoolProfiles[0].vmSize, tier:sku.tier}" -o tsv 2>/dev/null |
  while IFS=$'\t' read -r n rg c s tier; do
    printf "%-16s %-42s %s nodes x %s (%s)\n" "AKS" "$n" "$c" "$s" "$tier"
  done

# Azure Firewall: by far the most expensive thing in this project
FW_COUNT=$(az network firewall list --query "length(@)" -o tsv 2>/dev/null || echo 0)
if [ "$FW_COUNT" -gt 0 ]; then
  az network firewall list --query "[].{n:name, t:sku.tier}" -o tsv |
    while IFS=$'\t' read -r n t; do
      red "$(printf '%-16s %-42s %s  <-- ~USD 1.25/hr = USD 900/month' 'FIREWALL' "$n" "$t")"
    done
fi

# Application Gateway
az network application-gateway list --query "[].{n:name, t:sku.tier, c:sku.capacity}" -o tsv 2>/dev/null |
  while IFS=$'\t' read -r n t c; do
    warn "$(printf '%-16s %-42s %s cap=%s  <-- ~USD 0.25/hr' 'APPGATEWAY' "$n" "$t" "$c")"
  done

# PostgreSQL
az postgres flexible-server list --query "[].{n:name, s:sku.name, st:state}" -o tsv 2>/dev/null |
  while IFS=$'\t' read -r n s st; do
    printf "%-16s %-42s %s (%s)\n" "POSTGRES" "$n" "$s" "$st"
  done

# Public IPs: a static IP with nothing attached is pure waste
az network public-ip list \
  --query "[?ipConfiguration==null].{n:name, rg:resourceGroup, sku:sku.name}" -o tsv 2>/dev/null |
  while IFS=$'\t' read -r n rg sku; do
    warn "$(printf '%-16s %-42s %s  <-- UNATTACHED, delete it' 'PUBLIC-IP' "$n" "$sku")"
  done

# Orphaned managed disks
az disk list --query "[?diskState=='Unattached'].{n:name, g:diskSizeGb}" -o tsv 2>/dev/null |
  while IFS=$'\t' read -r n g; do
    warn "$(printf '%-16s %-42s %s GB  <-- UNATTACHED, delete it' 'DISK' "$n" "$g")"
  done
echo

# ---------------------------------------------- log analytics ingestion
info "=== Log Analytics ingestion (the sneaky one) ==="
az monitor log-analytics workspace list \
  --query "[].{n:name, rg:resourceGroup, quota:workspaceCapping.dailyQuotaGb, ret:retentionInDays}" -o tsv 2>/dev/null |
  while IFS=$'\t' read -r n rg quota ret; do
    if [ "$quota" = "-1.0" ] || [ "$quota" = "None" ] || [ -z "$quota" ]; then
      red "  ${n}: NO DAILY CAP, retention ${ret}d  <-- set a cap now"
    else
      green "  ${n}: capped at ${quota} GB/day, retention ${ret}d"
    fi
  done
echo

# ------------------------------------------------------------- the levers
info "=== How to stop the meter ==="
cat <<'EOF'
  Cheapest-first, least destructive first:

  1. Stop AKS entirely (keeps the cluster config, stops node billing):
       az aks stop -g rg-erp-dev-cin-aks -n aks-erp-dev-cin-01
       az aks start -g rg-erp-dev-cin-aks -n aks-erp-dev-cin-01

  2. Stop PostgreSQL (can be stopped for up to 7 days):
       az postgres flexible-server stop -g rg-erp-dev-cin-data -n psql-erp-dev-cin-01

  3. Turn off the firewall / app gateway via Terraform:
       terraform apply -var enable_firewall=false -var enable_appgw=false

  4. Scale the user node pool to zero but keep the cluster alive:
       az aks nodepool scale -g <rg> --cluster-name <aks> -n user --node-count 0

  5. Full teardown (destroys everything):
       ./scripts/teardown.sh dev

  Set a budget alert so Azure tells you before you notice:
    az consumption budget create --budget-name erp-learning-budget \
      --amount 30 --time-grain Monthly --category Cost \
      --start-date $(date -u +%Y-%m-01) --end-date $(date -u -d '+1 year' +%Y-%m-01)
EOF
