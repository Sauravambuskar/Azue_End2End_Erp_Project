#!/usr/bin/env bash
# ===========================================================================
# Create the ContosoERP management group hierarchy.
#
#   Tenant Root Group
#   └── mg-contoso
#       ├── mg-contoso-platform
#       │   ├── mg-contoso-platform-identity
#       │   ├── mg-contoso-platform-management
#       │   └── mg-contoso-platform-connectivity
#       ├── mg-contoso-landingzones
#       │   ├── mg-contoso-lz-corp
#       │   └── mg-contoso-lz-online
#       ├── mg-contoso-sandbox
#       └── mg-contoso-decommissioned
#
# Requires Owner or Management Group Contributor at the TENANT ROOT group.
# See guidance/01-azure-account-setup.md section 6 if you get AuthorizationFailed.
#
# Idempotent: re-running is safe.
# ===========================================================================
set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
info()  { printf '\033[36m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
die()   { printf '\033[31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

command -v az >/dev/null || die "Azure CLI not found."
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"

TENANT_ID=$(az account show --query tenantId -o tsv)
SUB_ID=$(az account show --query id -o tsv)
PLACE_SUB_UNDER="${PLACE_SUB_UNDER:-mg-contoso-sandbox}"

info "Tenant       : ${TENANT_ID}"
info "Subscription : ${SUB_ID}"
info "Will place the subscription under: ${PLACE_SUB_UNDER}"
echo

# ---------------------------------------------------- permission pre-check
if ! az account management-group list -o none 2>/dev/null; then
  die "Cannot list management groups.
You need Owner or Management Group Contributor at the tenant root group:

  az rest --method post --url \\
    'https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01'

  az role assignment create \\
    --assignee-object-id \$(az ad signed-in-user show --query id -o tsv) \\
    --assignee-principal-type User --role Owner \\
    --scope '/providers/Microsoft.Management/managementGroups/${TENANT_ID}'

Then wait 5 minutes and re-run this script."
fi

# ------------------------------------------------------------------ helper
mg_create() {  # mg_create <name> <display> <parent>
  local name="$1" display="$2" parent="$3"
  if az account management-group show --name "$name" -o none 2>/dev/null; then
    info "  exists: ${name}"
    return 0
  fi
  az account management-group create \
    --name "$name" --display-name "$display" --parent "$parent" \
    --only-show-errors -o none
  green "  created: ${name}  (parent ${parent})"
  # Management group creation is eventually consistent; give children a
  # moment or the next create can fail with ParentNotFound.
  sleep 5
}

# --------------------------------------------------------------- hierarchy
info "Tier 0 - organisation root"
mg_create "mg-contoso" "Contoso" "$TENANT_ID"

info "Tier 1"
mg_create "mg-contoso-platform"        "Platform"         "mg-contoso"
mg_create "mg-contoso-landingzones"    "Landing zones"    "mg-contoso"
mg_create "mg-contoso-sandbox"         "Sandbox"          "mg-contoso"
mg_create "mg-contoso-decommissioned"  "Decommissioned"   "mg-contoso"

info "Tier 2 - platform"
mg_create "mg-contoso-platform-identity"     "Platform / identity"     "mg-contoso-platform"
mg_create "mg-contoso-platform-management"   "Platform / management"   "mg-contoso-platform"
mg_create "mg-contoso-platform-connectivity" "Platform / connectivity" "mg-contoso-platform"

info "Tier 2 - landing zones"
mg_create "mg-contoso-lz-corp"   "Corp landing zones"   "mg-contoso-landingzones"
mg_create "mg-contoso-lz-online" "Online landing zones" "mg-contoso-landingzones"

# ------------------------------------------------------- place subscription
echo
info "Placing the subscription under ${PLACE_SUB_UNDER}..."
CURRENT_PARENT=$(az account management-group subscription show-sub-under-mg \
  --name "$PLACE_SUB_UNDER" --subscription "$SUB_ID" \
  --query name -o tsv 2>/dev/null || echo "")

if [ -n "$CURRENT_PARENT" ]; then
  info "  already there"
else
  az account management-group subscription add \
    --name "$PLACE_SUB_UNDER" --subscription "$SUB_ID" --only-show-errors -o none
  green "  moved"
fi

# -------------------------------------------------------------- the result
echo
info "=============================================================="
info " Hierarchy"
info "=============================================================="
az account management-group list \
  --query "sort_by([].{name:name, display:displayName, parent:parent.name}, &name)" \
  -o table

echo
green "=============================================================="
green " Done."
green "=============================================================="
cat <<EOF

Note: management group changes are eventually consistent. If the tree above
looks incomplete, wait 5-10 minutes and re-run:

  az account management-group list -o table

Next: assign the governance baseline at mg-contoso.

  cd /d/Azure
  for f in policy/definitions/*.json; do
    name=\$(basename "\$f" .json)
    az policy definition create \\
      --name "erp-\${name}" --management-group mg-contoso \\
      --rules  "\$(jq -c .properties.policyRule "\$f")" \\
      --params "\$(jq -c .properties.parameters "\$f")" \\
      --mode   "\$(jq -r .properties.mode "\$f")" \\
      --display-name "\$(jq -r .properties.displayName "\$f")"
  done

See guidance/12-governance.md for the full assignment walkthrough.

To undo everything this script did (children must be empty first):
  az account management-group subscription remove --name ${PLACE_SUB_UNDER} --subscription ${SUB_ID}
  for mg in mg-contoso-platform-identity mg-contoso-platform-management \\
            mg-contoso-platform-connectivity mg-contoso-lz-corp mg-contoso-lz-online \\
            mg-contoso-platform mg-contoso-landingzones mg-contoso-sandbox \\
            mg-contoso-decommissioned mg-contoso; do
    az account management-group delete --name "\$mg"
  done
EOF
