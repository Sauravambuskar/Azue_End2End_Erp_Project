#!/usr/bin/env bash
# ===========================================================================
# Make the managed identities real PostgreSQL principals (passwordless auth).
#
# THIS IS THE STEP EVERYONE FORGETS.
#
# Terraform creates the managed identity and the federated credential. That
# gets the pod an Entra ID *token*. But PostgreSQL still has no idea who that
# identity is - there is no role for it - so the connection fails with
# "password authentication failed for user id-erp-api-dev".
#
# pgaadauth_create_principal() is the bridge: it creates a PG role whose name
# matches the identity, flagged as an AAD principal. After that, the token IS
# the password.
#
# Prerequisites:
#   * you are the Entra admin on the Flexible Server (Terraform sets this via
#     db_aad_admin_object_id)
#   * your machine can reach the server. The dev server is VNet-injected, so
#     run this from a jump host, Bastion, Cloud Shell inside the VNet, or
#     temporarily add a firewall rule.
#
# Usage:  ./scripts/db-grant-identities.sh [dev|test|prod]
# ===========================================================================
set -euo pipefail

ENVIRONMENT="${1:-dev}"
TF_DIR="infra/terraform/envs/${ENVIRONMENT}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
info()  { printf '\033[36m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
die()   { printf '\033[31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

command -v az   >/dev/null || die "Azure CLI not found."
command -v psql >/dev/null || die "psql not found. Install the postgresql client."
[ -d "$TF_DIR" ] || die "No such environment directory: $TF_DIR"

# ------------------------------------------------- read Terraform outputs
info "Reading Terraform outputs from ${TF_DIR}..."
PG_FQDN=$(terraform -chdir="$TF_DIR" output -raw postgres_fqdn)
PG_DB=$(terraform   -chdir="$TF_DIR" output -raw postgres_database)
IDENTITIES_JSON=$(terraform -chdir="$TF_DIR" output -json workload_identity_names)

# ------------------------------------------------ get an admin AAD token
info "Acquiring an Entra ID access token for PostgreSQL..."
ADMIN_UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv)
PGPASSWORD=$(az account get-access-token \
  --resource-type oss-rdbms \
  --query accessToken -o tsv)
export PGPASSWORD
export PGSSLMODE=require

info "Server   : ${PG_FQDN}"
info "Database : ${PG_DB}"
info "Admin    : ${ADMIN_UPN}"
echo

PSQL=(psql --host "$PG_FQDN" --username "$ADMIN_UPN" --dbname "$PG_DB"
      --no-password --set ON_ERROR_STOP=1)

# ------------------------------------------------------- connectivity test
if ! "${PSQL[@]}" -c 'SELECT 1' >/dev/null 2>&1; then
  die "Cannot reach ${PG_FQDN}.
The server is VNet-injected and has no public endpoint. Options:
  1. Run this from a VM/jump host inside the spoke VNet
  2. Run it from an AKS pod:
       kubectl -n erp run psql-admin --rm -it --restart=Never \\
         --image=postgres:16-alpine -- sh
  3. Use Azure Cloud Shell with VNet integration
Also confirm you are the Entra admin:
  az postgres flexible-server ad-admin list -g <rg> -s <server>"
fi
green "Connected."
echo

# --------------------------------------------------- roles from V002
info "Ensuring the application roles exist (idempotent)..."
"${PSQL[@]}" -f db/migrations/V002__least_privilege_roles.sql >/dev/null
green "Roles erp_app / erp_readonly / erp_migrator present."
echo

# ------------------------------------------- create principals + grants
# Map each workload to the database role it is allowed to hold.
declare -A ROLE_FOR=(
  [api]=erp_app
  [worker]=erp_app
  [migrate]=erp_migrator
  [web]=""          # the web tier never touches the database
)

for workload in api worker migrate web; do
  identity=$(printf '%s' "$IDENTITIES_JSON" | \
    "$(command -v python3 || command -v python)" -c \
    "import json,sys;print(json.load(sys.stdin).get('$workload',''))")

  [ -n "$identity" ] || { warn "No identity found for '${workload}', skipping."; continue; }

  role="${ROLE_FOR[$workload]}"
  if [ -z "$role" ]; then
    info "Skipping ${identity} - the ${workload} tier has no database access by design."
    continue
  fi

  info "Processing ${identity} -> ${role}"

  # pgaadauth_create_principal(name, isAdmin, isMsGroup)
  # Wrapped in a DO block so re-running is harmless.
  "${PSQL[@]}" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${identity}') THEN
    PERFORM pgaadauth_create_principal('${identity}', false, false);
    RAISE NOTICE 'created AAD principal ${identity}';
  ELSE
    RAISE NOTICE 'principal ${identity} already exists';
  END IF;
END
\$\$;

GRANT ${role} TO "${identity}";
SQL

  green "  ${identity} granted ${role}"
done

echo
# -------------------------------------------------------------- verify
info "Verifying AAD principals and their role memberships:"
"${PSQL[@]}" -c "
SELECT r.rolname                                  AS principal,
       COALESCE(string_agg(m.rolname, ', '), '-') AS member_of,
       r.rolcanlogin                              AS can_login
FROM pg_roles r
LEFT JOIN pg_auth_members am ON am.member = r.oid
LEFT JOIN pg_roles m         ON m.oid = am.roleid
WHERE r.rolname LIKE 'id-erp-%'
GROUP BY r.rolname, r.rolcanlogin
ORDER BY r.rolname;"

echo
green "=============================================================="
green "Done. The pods can now authenticate with no password."
green "=============================================================="
cat <<EOF

Verify from inside the cluster:

  kubectl -n erp exec deploy/erp-api -- \\
    python -c "from app.core.db import get_engine; \\
      import sqlalchemy as sa; \\
      print(get_engine().connect().execute(sa.text('select current_user')).scalar())"

Expected output: id-erp-api-${ENVIRONMENT}

If you instead see "password authentication failed", check in this order:
  1. The ServiceAccount annotation matches the identity's CLIENT id
     kubectl -n erp get sa erp-api-sa -o yaml
  2. The federated credential subject matches namespace:serviceaccount exactly
     az identity federated-credential list --identity-name id-erp-api-${ENVIRONMENT} -g <platform-rg>
  3. The pod has the azure.workload.identity/use: "true" LABEL (not annotation)
  4. ERP_DB_USER equals the identity name, not "erpadmin"
EOF
