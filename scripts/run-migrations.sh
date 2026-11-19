#!/usr/bin/env bash
# ===========================================================================
# Apply database migrations in order, using a passwordless Entra ID token.
#
# Runs as the erp-migrate pod inside AKS. Reads no secrets: the password it
# hands to psql is a short-lived AAD access token obtained through workload
# identity.
# ===========================================================================
set -euo pipefail

: "${ERP_DB_HOST:?ERP_DB_HOST is required}"
: "${ERP_DB_USER:?ERP_DB_USER is required}"
DB_NAME="${ERP_DB_NAME:-erp}"
DB_PORT="${ERP_DB_PORT:-5432}"
USE_MI="${ERP_DB_USE_MANAGED_IDENTITY:-true}"
RUN_SEED="${ERP_RUN_SEED:-false}"
MIGRATION_DIR="${ERP_MIGRATION_DIR:-./migrations}"

log() { printf '{"ts":"%s","level":"%s","msg":"%s"}\n' "$(date -uIs)" "$1" "$2"; }

# ------------------------------------------------------------------- auth
if [ "$USE_MI" = "true" ]; then
  log INFO "acquiring Entra ID token for PostgreSQL"
  PGPASSWORD=$(python - <<'PY'
from azure.identity import DefaultAzureCredential
cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
print(cred.get_token("https://ossrdbms-aad.database.windows.net/.default").token)
PY
  )
  export PGPASSWORD
  log INFO "token acquired (length ${#PGPASSWORD})"
else
  : "${ERP_DB_PASSWORD:?ERP_DB_PASSWORD is required when managed identity is off}"
  export PGPASSWORD="$ERP_DB_PASSWORD"
  log WARN "using password authentication - acceptable only for local development"
fi

export PGSSLMODE="${ERP_DB_SSLMODE:-require}"
PSQL=(psql --host "$ERP_DB_HOST" --port "$DB_PORT" --username "$ERP_DB_USER"
      --dbname "$DB_NAME" --no-password --set ON_ERROR_STOP=1 --quiet)

# ------------------------------------------------------------ connectivity
log INFO "testing connectivity to ${ERP_DB_HOST}/${DB_NAME}"
for attempt in $(seq 1 10); do
  if "${PSQL[@]}" -c 'SELECT 1' >/dev/null 2>&1; then
    log INFO "connected"
    break
  fi
  if [ "$attempt" -eq 10 ]; then
    log ERROR "could not connect after 10 attempts"
    exit 1
  fi
  log WARN "connection attempt ${attempt} failed, retrying in 5s"
  sleep 5
done

# ------------------------------------------------------- applied-set lookup
# schema_version may not exist yet on a brand-new database, so tolerate the
# error and treat the applied set as empty.
APPLIED=$("${PSQL[@]}" -tAc \
  "SELECT string_agg(version, ' ') FROM schema_version" 2>/dev/null || echo "")
log INFO "already applied: ${APPLIED:-none}"

# ---------------------------------------------------------------- apply
shopt -s nullglob
FILES=("$MIGRATION_DIR"/V*__*.sql)
if [ ${#FILES[@]} -eq 0 ]; then
  log ERROR "no migration files found in ${MIGRATION_DIR}"
  exit 1
fi

# Sort numerically so V10 comes after V9, not after V1.
IFS=$'\n' FILES=($(printf '%s\n' "${FILES[@]}" | sort -V)); unset IFS

APPLIED_COUNT=0
for file in "${FILES[@]}"; do
  base=$(basename "$file")
  version="${base%%__*}"

  if [[ " $APPLIED " == *" $version "* ]]; then
    log INFO "skipping ${version} (already applied)"
    continue
  fi

  log INFO "applying ${base}"
  start=$(date +%s)
  if ! "${PSQL[@]}" --file "$file"; then
    log ERROR "migration ${base} FAILED - the transaction was rolled back"
    exit 1
  fi
  log INFO "applied ${base} in $(( $(date +%s) - start ))s"
  APPLIED_COUNT=$((APPLIED_COUNT + 1))
done

log INFO "migrations complete: ${APPLIED_COUNT} newly applied"

# ----------------------------------------------------------------- seed
if [ "$RUN_SEED" = "true" ]; then
  log INFO "loading demo seed data"
  "${PSQL[@]}" --file ./seed/seed.sql
  log INFO "seed complete"
fi

# ------------------------------------------------------------- final check
log INFO "verifying schema"
TABLES=$("${PSQL[@]}" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
log INFO "public schema holds ${TABLES} tables/views"

LEDGER=$("${PSQL[@]}" -tAc \
  "SELECT COALESCE(SUM(debit)-SUM(credit),0) FROM gl_entry" 2>/dev/null || echo "0")
if [ "$LEDGER" != "0" ] && [ "$LEDGER" != "0.0000" ]; then
  log ERROR "general ledger is out of balance by ${LEDGER}"
  exit 2
fi
log INFO "ledger balanced; migration job finished successfully"
