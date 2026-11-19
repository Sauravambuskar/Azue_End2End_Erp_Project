# 06 — PostgreSQL, passwordless auth, migrations, Cosmos DB

**Time:** 4 hours · **Cost:** ~₹2/hour (B1ms burstable)
**Prerequisite:** chapters 03–05 complete

The database is where the "sec" in DevSecOps gets real. An ERP database holds
financial records. This chapter makes it unreachable from the internet,
passwordless, audited, and migrated by a pipeline rather than by hand.

---

## 1. The design decisions

| Decision | Choice | Why |
|---|---|---|
| Engine | PostgreSQL Flexible Server 16 | the JD names it; Flexible is the current generation (Single Server is retired) |
| Network | **VNet injection** into a delegated subnet | there is no public endpoint to misconfigure |
| Authentication | **Entra ID tokens**, password auth kept only for bootstrap | no credential to store, rotate or leak |
| TLS | `require_secure_transport = ON`, TLS 1.2 minimum | in-flight encryption, non-negotiable for financial data |
| Audit | `pgaudit` logging WRITE, DDL, ROLE | answers "who changed this row" |
| Roles | `erp_app` (DML) / `erp_readonly` / `erp_migrator` (DDL) | the app cannot alter the schema even if compromised |
| GL protection | `REVOKE UPDATE, DELETE ON gl_entry FROM erp_app` | the ledger is append-only at the database level |
| Backups | 7 days dev, geo-redundant + 35 days prod | matches the recovery objective per environment |
| HA | off in dev, ZoneRedundant in prod | HA doubles the cost; dev does not need it |
| SKU | `B_Standard_B1ms` dev | burstable, ~₹2/hour, plenty for a lab |

### VNet injection vs private endpoint — the irreversible choice

Covered in chapter 03 §5. The one-sentence version: **injection puts the
server inside your subnet with no public endpoint at all, and you cannot
change your mind later without recreating the server.** We chose it because
"no public endpoint exists" beats "the public endpoint is disabled".

---

## 2. Look at what Terraform built

```bash
cd infra/terraform/envs/dev
PG_NAME=$(terraform output -raw postgres_name)
PG_FQDN=$(terraform output -raw postgres_fqdn)
DATA_RG=$(terraform output -json resource_groups | jq -r .data)

az postgres flexible-server show -g "$DATA_RG" -n "$PG_NAME" \
  --query '{
    version: version,
    sku: sku.name,
    state: state,
    publicAccess: network.publicNetworkAccess,
    subnet: network.delegatedSubnetResourceId,
    dnsZone: network.privateDnsZoneArmResourceId,
    aadAuth: authConfig.activeDirectoryAuth,
    pwdAuth: authConfig.passwordAuth,
    backupDays: backup.backupRetentionDays,
    geoBackup: backup.geoRedundantBackup
  }' -o json
```

`publicNetworkAccess` must read `Disabled`. If it says `Enabled`, the server
was created with public access and VNet injection did not take — that is a
recreate, not a fix.

```bash
# The server parameters we set
az postgres flexible-server parameter list -g "$DATA_RG" -s "$PG_NAME" \
  --query "[?name=='require_secure_transport' || name=='ssl_min_protocol_version' || name=='pgaudit.log' || name=='log_min_duration_statement' || name=='shared_preload_libraries'].{name:name, value:value, default:defaultValue}" \
  -o table
```

---

## 3. Reaching a server with no public endpoint

This is the practical problem VNet injection creates, and how you solve it is
a good interview topic in itself.

### Option A — a pod in the cluster (what we use)

```bash
kubectl -n erp run psql-admin --rm -it --restart=Never \
  --image=postgres:16-alpine \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"runAsGroup":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"psql-admin","image":"postgres:16-alpine","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},"command":["sh"],"stdin":true,"tty":true}]}}' \
  -- sh
```

Inside, you need a token. The pod has no Azure identity, so pass one in from
outside instead:

```bash
# On your machine
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)
export PGUSER=$(az ad signed-in-user show --query userPrincipalName -o tsv)
PG_FQDN=$(cd infra/terraform/envs/dev && terraform output -raw postgres_fqdn)

kubectl -n erp run psql-admin --rm -it --restart=Never \
  --image=postgres:16-alpine \
  --env="PGPASSWORD=$PGPASSWORD" \
  --env="PGSSLMODE=require" \
  --command -- psql "host=$PG_FQDN user=$PGUSER dbname=erp sslmode=require"
```

> The token is valid for about an hour. If you get a password failure after a
> while, that is just the token expiring — re-run `az account get-access-token`.

### Option B — temporarily allow your IP

Only possible if the server uses a private endpoint rather than injection.
With injection there is no public endpoint to allow. Worth knowing so you can
say why it does *not* apply here.

### Option C — Azure Bastion + a jump host

The enterprise answer: a small VM in `snet-shared-services`, no public IP,
reached through Bastion. Costs about ₹15/hour for Bastion, so not for a lab,
but it is the pattern you should describe.

### Option D — `az aks command invoke`

```bash
az aks command invoke -g "$AKS_RG" -n "$AKS_NAME" \
  --command "kubectl -n erp get pods"
```

Runs a command from inside the cluster without network access to it. Very
useful for a private cluster — and precisely why we set
`run_command_enabled = false` in prod: it is a legitimate backdoor around
your network controls. Naming both sides of that trade-off is a good answer.

---

## 4. Passwordless authentication — the full walkthrough

### What Terraform did

Created the managed identities and federated credentials (chapter 04), and set
you as the Entra administrator on the server.

### What Terraform could NOT do

Create the PostgreSQL **roles** for those identities. That needs a SQL
connection as the Entra admin, which Terraform cannot make from outside the
VNet. Hence the script.

### Run it

```bash
./scripts/db-grant-identities.sh dev
```

What it does, in order:
1. reads the identity names from Terraform outputs
2. gets an Entra token for you as the server's AAD admin
3. applies `V002__least_privilege_roles.sql` to create `erp_app`,
   `erp_readonly`, `erp_migrator`
4. calls `pgaadauth_create_principal(<identity-name>, false, false)` for each
   managed identity
5. grants each one the right role — `erp_app` for api and worker,
   `erp_migrator` for the migration job, **nothing for web**
6. prints a verification table

### Verify

```bash
# From the psql-admin pod, as the AAD admin
SELECT r.rolname AS principal,
       COALESCE(string_agg(m.rolname, ', '), '-') AS member_of
FROM pg_roles r
LEFT JOIN pg_auth_members am ON am.member = r.oid
LEFT JOIN pg_roles m ON m.oid = am.roleid
WHERE r.rolname LIKE 'id-erp-%'
GROUP BY r.rolname;
```

Expected:

| principal | member_of |
|---|---|
| id-erp-api-dev | erp_app |
| id-erp-migrate-dev | erp_migrator |
| id-erp-worker-dev | erp_app |

Then prove it works from the actual application pod:

```bash
kubectl -n erp exec deploy/erp-api -- python -c "
import sqlalchemy as sa
from app.core.db import get_engine
with get_engine().connect() as c:
    print('connected as:', c.execute(sa.text('SELECT current_user')).scalar())
    print('ssl in use  :', c.execute(sa.text(
        'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()')).scalar())
"
```

Expected: `connected as: id-erp-api-dev` and `ssl in use: True`.

**That output is the proof of the whole chapter.** No password exists anywhere
— not in a ConfigMap, not in a Kubernetes Secret, not in etcd, not in
Terraform state.

### How the application does it

[`src/erp-api/app/core/db.py`](../src/erp-api/app/core/db.py):

```python
@event.listens_for(engine, "do_connect")
def _provide_token(dialect, conn_rec, cargs, cparams):
    token = credential.get_token(PG_AAD_SCOPE).token
    cparams["password"] = token
```

The important subtlety: the hook runs **per connection**, not once at startup.
A token lasts about an hour; a pooled connection can live longer. If you
fetched the token once, connections would start failing an hour after the pod
started — intermittently, under load, which is a miserable bug. Fetching it at
connect time means every new pooled connection gets a fresh token.

`DefaultAzureCredential` also caches tokens internally, so this is not an HTTP
call per connection.

> **This is a genuinely good thing to volunteer in an interview:** "the
> non-obvious part of passwordless database auth is token lifetime versus
> connection pool lifetime."

---

## 5. Migrations

### The rules this project follows

1. **Forward-only.** No down scripts. A mistake is fixed by a new `Vnnn` file.
   Down migrations are a fiction in production: by the time you need one, data
   has changed shape and the down script does not account for it.
2. **Idempotent.** Every file can be re-run safely (`IF NOT EXISTS`,
   `ON CONFLICT DO NOTHING`).
3. **A separate, higher-privileged identity.** Only `id-erp-migrate-dev` holds
   `erp_migrator`. Runtime pods cannot alter the schema.
4. **Run from inside the VNet**, as a Helm pre-upgrade hook, because the server
   has no public endpoint.
5. **The pipeline checks the sequence** for gaps and duplicates, and blocks
   destructive DDL unless it carries an `ALLOW-DESTRUCTIVE` marker — see the
   `sql_review` job in
   [`pipelines/azure-pipelines.yml`](../pipelines/azure-pipelines.yml).

### How it runs

[`k8s/helm/erp/templates/migrate-job.yaml`](../k8s/helm/erp/templates/migrate-job.yaml)
is a Job with:

```yaml
annotations:
  "helm.sh/hook": pre-install,pre-upgrade
  "helm.sh/hook-weight": "-5"
  "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

So on every `helm upgrade`: the Job runs first, and **if it fails, the upgrade
does not proceed.** New application code never starts against an un-migrated
schema.

```bash
# Watch it happen
helm upgrade erp k8s/helm/erp -n erp -f k8s/helm/erp/values-dev.yaml --reuse-values &
kubectl -n erp get jobs -w

kubectl -n erp logs job/erp-migrate-2
```

### Add a migration and see it applied

```bash
cat > db/migrations/V004__add_product_barcode.sql <<'EOF'
-- Add barcode tracking to products.
-- Forward-only, idempotent, non-destructive.
BEGIN;

ALTER TABLE product ADD COLUMN IF NOT EXISTS barcode VARCHAR(32);

CREATE UNIQUE INDEX IF NOT EXISTS uq_product_barcode
  ON product(barcode) WHERE barcode IS NOT NULL;

COMMENT ON COLUMN product.barcode IS 'EAN-13 or UPC-A, nullable for legacy items';

INSERT INTO schema_version(version) VALUES ('V004') ON CONFLICT DO NOTHING;
COMMIT;
EOF

# Rebuild the migrate image so it contains the new file
./scripts/build-and-push.sh "$ACR" v0.1.1

helm upgrade erp k8s/helm/erp -n erp -f k8s/helm/erp/values-dev.yaml \
  --reuse-values --set image.tag=v0.1.1 --atomic --wait

kubectl -n erp logs -l app.kubernetes.io/component=migrate --tail=30
```

### The two migration traps worth knowing

**Trap 1 — a lock that takes the application down.**

```sql
-- This rewrites the whole table and holds an ACCESS EXCLUSIVE lock.
-- On a large table it blocks every read and write for minutes.
ALTER TABLE sales_order ADD COLUMN notes TEXT NOT NULL DEFAULT '';
```

The safe form is three separate migrations, deployed over time:

```sql
-- V00n   add as nullable - instant, metadata only
ALTER TABLE sales_order ADD COLUMN notes TEXT;
-- (application deploys, writes to the new column)
-- V00n+1 backfill in batches, outside a long transaction
-- V00n+2 add the NOT NULL constraint once no NULLs remain
```

**Trap 2 — `CREATE INDEX` without `CONCURRENTLY`.**

```sql
CREATE INDEX ix_big ON sales_order_line(product_id);              -- blocks writes
CREATE INDEX CONCURRENTLY ix_big ON sales_order_line(product_id); -- does not
```

`CONCURRENTLY` **cannot run inside a transaction block**, so it needs its own
migration file with no `BEGIN`/`COMMIT`. If you forget, PostgreSQL errors out
and the error message is not obvious.

> Both traps are excellent answers to *"tell me about a deployment that went
> wrong"* if you have actually caused one. Try trap 2 deliberately in dev.

---

## 6. Auditing — who changed the financial records

`pgaudit` is enabled with `pgaudit.log = 'WRITE,DDL,ROLE'`.

```bash
# What is audit logging actually capturing?
LAW_GUID=$(az monitor log-analytics workspace show \
  --ids "$(cd infra/terraform/envs/dev && terraform output -raw log_analytics_workspace_id)" \
  --query customerId -o tsv)

az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  AzureDiagnostics
  | where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
  | where Category == "PostgreSQLLogs"
  | where Message has "AUDIT"
  | project TimeGenerated, Message
  | order by TimeGenerated desc
  | take 20' -o table
```

Plus the application-level audit: every GL posting is written with a
`batch_id` and a `source_doc`, so a financial entry traces back to the sales
order or purchase order that created it. And the database enforces that the
ledger cannot be rewritten:

```sql
-- From V002. The app role can INSERT into gl_entry but not UPDATE or DELETE.
REVOKE UPDATE, DELETE ON gl_entry FROM erp_app;
```

Prove it:

```bash
kubectl -n erp exec deploy/erp-api -- python -c "
import sqlalchemy as sa
from app.core.db import get_engine
try:
    with get_engine().begin() as c:
        c.execute(sa.text('DELETE FROM gl_entry WHERE id = 1'))
    print('PROBLEM: the ledger is mutable')
except Exception as e:
    print('correctly refused:', type(e).__name__)
"
```

**That is a control an auditor can test.** Mentioning that you pushed an
integrity rule down into database permissions, rather than relying on
application code, is a strong signal.

---

## 7. Backup and restore — actually do it once

Claiming you have backups is worthless. Restoring is the skill.

```bash
DATA_RG=$(cd infra/terraform/envs/dev && terraform output -json resource_groups | jq -r .data)
PG_NAME=$(cd infra/terraform/envs/dev && terraform output -raw postgres_name)

# What is the restorable window?
az postgres flexible-server show -g "$DATA_RG" -n "$PG_NAME" \
  --query '{earliest:backup.earliestRestoreDate, retention:backup.backupRetentionDays}' -o json

# Point-in-time restore to a NEW server (PITR never overwrites the original)
RESTORE_POINT=$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
az postgres flexible-server restore \
  -g "$DATA_RG" \
  -n "${PG_NAME}-restored" \
  --source-server "$PG_NAME" \
  --restore-time "$RESTORE_POINT"
```

> Takes 10–20 minutes and creates a second server that costs money. **Delete
> it immediately afterwards:**
> ```bash
> az postgres flexible-server delete -g "$DATA_RG" -n "${PG_NAME}-restored" --yes
> ```

### The numbers to know

| Term | Meaning | Our dev value | Our prod value |
|---|---|---|---|
| **RPO** — recovery point objective | how much data you can lose | ~5 min (PITR granularity) | ~5 min |
| **RTO** — recovery time objective | how long to be back up | ~20 min (restore time) | ~20 min, or ~1 min with HA failover |
| Retention | how far back you can go | 7 days | 35 days |
| Geo-redundancy | survives a regional outage | no | yes |

**The distinction people fumble:** high availability is not backup. HA
protects against a node or zone failure with a ~60-second failover, but it
replicates your mistakes instantly — a `DELETE` without a `WHERE` is on the
standby immediately. Backup protects against logical corruption. You need
both, and they solve different problems.

---

## 8. Cosmos DB — the right tool for the wrong-shaped data

### The architectural argument

PostgreSQL is the system of record: relational, transactional, ACID, with a
double-entry ledger that must balance. That is exactly what a relational
engine is for.

Two datasets do **not** fit it well:

| Dataset | Volume | Shape | Why not PostgreSQL |
|---|---|---|---|
| `audit_trail` | every API mutation, millions of rows | schema-light JSON payloads | bloats the OLTP database, and the payload shape varies |
| `device_telemetry` | plant machinery readings, high write rate | time-series, write-once | write amplification and index bloat on the transactional server |

```bash
cd infra/terraform/envs/dev
terraform apply -var enable_cosmos=true -auto-approve
terraform output cosmos_endpoint
```

### The two decisions in that module worth defending

**Serverless capacity mode.** Provisioned throughput bills 400 RU/s
continuously whether you use it or not — roughly ₹1,900/month for an idle lab.
Serverless bills per request, so an idle Cosmos account costs essentially
nothing. The trade-off: serverless caps at 5,000 RU/s and 1 TB, and has no
SLA-backed provisioned capacity. For a lab and for bursty audit writes it is
correct; for a sustained high-throughput workload it is not.

**Partition key choice.** This is the Cosmos question that gets asked.

| Container | Partition key | Reasoning |
|---|---|---|
| `audit_trail` | `/partitionDate` | writes spread across days; queries are nearly always "what happened on date X" |
| `device_telemetry` | `/deviceId` | thousands of devices give high cardinality; queries are per-device time series |

**The rule:** high cardinality, even write distribution, and a key you can
include in your most common query. Get it wrong and you get a hot partition —
a 20 GB logical partition limit and throttling (429s) while the rest of the
account is idle. And **the partition key is immutable**; changing it means
creating a new container and migrating.

> A deliberately bad example to contrast with: partitioning `audit_trail` by
> `/entityType` would give you maybe eight distinct values, so eight
> partitions, and "SalesOrder" would receive 80% of writes. That is a hot
> partition by design.

### TTL instead of a cleanup job

```hcl
default_ttl = 60 * 60 * 24 * 400   # ~13 months
```

Cosmos deletes expired items itself, using spare throughput. No cron job, no
code, no cost spike. The alternative — a nightly `DELETE` job — is code you
have to write, monitor and pay for.

### Data-plane RBAC, not keys

```hcl
role_definition_id = ".../sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
# = Cosmos DB Built-in Data Contributor
```

Plus `local_authentication_disabled = true` for the exercise, which turns off
account keys entirely so Entra ID is the only way in. Same principle as
everywhere else in this project: **remove the credential, do not protect it.**

### Turn it off when done

```bash
terraform apply -var enable_cosmos=false -auto-approve
```

### The other "nice to have" items — how they would slot in

You will not deploy these (cost, and they add nothing to the interview beyond
being able to place them), but have an answer ready:

- **Azure Digital Twins** — a live graph model of the plant: lines, machines,
  sensors. The ERP holds the asset master data; Digital Twins holds the
  topology and live state. They integrate through Event Grid, with telemetry
  landing in Cosmos.
- **Azure OpenAI** — the natural fit here is reorder forecasting: feed the
  reorder-breach history and lead times in as context and let it suggest
  purchase quantities. It would be a separate service calling the ERP API
  read-only, with its own managed identity, so the model never touches the
  database.
- **Event-driven** — the worker already publishes to Service Bus. The next
  step is Event Grid for fan-out, and KEDA scaling the consumer on queue
  depth, which chapter 05 §6 covers.

---

## 9. Break it on purpose

**Exercise A — the error everybody gets**

```bash
# Remove the PostgreSQL role for the API identity
kubectl -n erp run psql-admin --rm -it --restart=Never --image=postgres:16-alpine \
  --env="PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)" \
  --command -- psql "host=$PG_FQDN user=$(az ad signed-in-user show --query userPrincipalName -o tsv) dbname=erp sslmode=require" \
  -c 'REVOKE erp_app FROM "id-erp-api-dev";'

kubectl -n erp rollout restart deploy/erp-api
kubectl -n erp logs -l app.kubernetes.io/component=api --tail=20
kubectl -n erp get endpoints erp-api
```

You get a **permission denied** error — the identity authenticates fine but
has no table rights. Compare that with deleting the principal entirely, which
gives **password authentication failed** even though the token is valid.

Two different errors, two different causes:
- `password authentication failed for user "id-erp-..."` → no principal exists
- `permission denied for table product` → principal exists, role not granted

Restore: `./scripts/db-grant-identities.sh dev`

**Exercise B — a migration that locks the table**

```bash
cat > db/migrations/V005__bad_lock.sql <<'EOF'
-- Deliberately bad: rewrites the table and holds ACCESS EXCLUSIVE.
BEGIN;
ALTER TABLE sales_order_line ADD COLUMN audit_note TEXT NOT NULL DEFAULT 'none';
INSERT INTO schema_version(version) VALUES ('V005') ON CONFLICT DO NOTHING;
COMMIT;
EOF
```

With only a few rows this is instant. Generate some volume first and watch the
lock:

```bash
# In the psql-admin pod
INSERT INTO sales_order_line (order_id, line_no, product_id, quantity, unit_price)
SELECT 1, generate_series(1000, 400000), 1, 1, 100;

-- Then in a second session, while the ALTER runs:
SELECT pid, wait_event_type, wait_event, left(query, 60) AS query
FROM pg_stat_activity WHERE state != 'idle';

SELECT locktype, relation::regclass, mode, granted
FROM pg_locks WHERE NOT granted;
```

Clean up: `DELETE FROM sales_order_line WHERE line_no >= 1000;` and
`rm db/migrations/V005__bad_lock.sql`.

**Exercise C — exhaust the connection pool**

```bash
# The B1ms SKU allows only ~50 connections total
kubectl -n erp scale deploy/erp-api --replicas=12
# Each pod opens pool_size=5 + max_overflow=10 = up to 15 connections
```

You will see `FATAL: too many connections for role` or
`remaining connection slots are reserved`. **The lesson:** connection limits
scale with the SKU, not with your replica count, so HPA can take the database
down. The real fixes, in order: PgBouncer (built into Flexible Server — enable
it), a smaller `pool_size` per pod, or a larger SKU.

```bash
kubectl -n erp scale deploy/erp-api --replicas=1

# Enable the built-in connection pooler
az postgres flexible-server parameter set -g "$DATA_RG" -s "$PG_NAME" \
  --name pgbouncer.enabled --value true
```

---

## 10. Interview answers this chapter gives you

**"How does your application connect to the database without a password?"**

> Entra ID token authentication over workload identity. The pod has a
> user-assigned managed identity federated to its Kubernetes service account,
> so the Azure SDK can obtain an access token scoped to
> `https://ossrdbms-aad.database.windows.net/.default`. That token *is* the
> password — PostgreSQL validates it against Entra ID. On the database side
> you still have to create a principal for the identity with
> `pgaadauth_create_principal`, which is the step people miss; without it you
> get a password authentication failure even though the token is perfectly
> valid. The implementation detail I would call out is that the token is
> fetched in a per-connection hook, not once at startup — a token lives about
> an hour, a pooled connection can live longer, so fetching once gives you
> intermittent failures an hour after every deployment.

**"How do you run database migrations safely?"**

> Forward-only, idempotent, and gated. Forward-only because down migrations
> are fiction in production — by the time you need one, the data has changed
> shape. A mistake is fixed by a new migration. They run as a Helm pre-upgrade
> hook, so the Job executes before the new pods start and the upgrade aborts
> if it fails — new code never runs against an un-migrated schema. The job
> uses a *separate* managed identity, the only one holding DDL rights, so the
> runtime pods cannot alter the schema even if compromised. It runs inside the
> cluster because the server has no public endpoint. And the pipeline reviews
> the SQL before it ever runs: it checks the version sequence for gaps and
> blocks destructive DDL unless it carries an explicit marker. For large
> tables I split anything that takes a heavy lock — add a column nullable,
> backfill in batches, then add the constraint — and index creation always
> uses CONCURRENTLY, which has to be in its own file because it cannot run
> inside a transaction.

**"PostgreSQL or Cosmos DB — how do you choose?"**

> By the shape of the data and the consistency requirement, not by preference.
> The ERP core is relational and transactional: a sales order has lines, the
> general ledger must balance, and I need real foreign keys and
> cross-table ACID transactions. That is PostgreSQL. Two datasets in the same
> system do not fit it — the audit trail, which is millions of schema-light
> JSON documents, and device telemetry, which is high-rate time series. Those
> would bloat the OLTP database and its indexes, so they go to Cosmos in
> serverless mode with TTL doing the retention. The partition key is the
> decision that matters there: audit trail by date because writes spread
> evenly and queries are date-ranged, telemetry by device id for cardinality.
> Get that wrong and you get a hot partition, 429s, and a 20 GB logical
> partition ceiling — and you cannot change a partition key without creating a
> new container.

**"What is your backup and recovery strategy?"**

> Point-in-time restore with a retention window sized per environment — 7 days
> in dev, 35 and geo-redundant in prod. That gives roughly a 5-minute RPO and
> a 20-minute RTO, because PITR always restores to a *new* server rather than
> overwriting the original. In prod there is also zone-redundant HA, with
> about a 60-second failover. The important thing is that those solve different
> problems: HA protects against infrastructure failure but replicates logical
> corruption instantly — a DELETE without a WHERE is on the standby
> immediately — whereas backup is the only protection against logical
> corruption. And I have actually performed a restore, because an untested
> backup is a hypothesis. For the ERP specifically there is a third layer: the
> general ledger is append-only at the permission level, so the app role can
> INSERT but cannot UPDATE or DELETE a posting.

---

## Checklist

- [ ] `publicNetworkAccess` confirmed `Disabled`
- [ ] You can explain VNet injection vs private endpoint and the irreversibility
- [ ] You can name four ways to reach a server with no public endpoint
- [ ] `db-grant-identities.sh` run; the verification table shows all three principals
- [ ] `SELECT current_user` from the API pod returns `id-erp-api-dev`
- [ ] `pg_stat_ssl` confirms TLS in use
- [ ] You can explain token lifetime vs connection pool lifetime
- [ ] You added `V004` and watched the Helm hook apply it
- [ ] You know both migration traps: the rewriting ALTER, and CONCURRENTLY
- [ ] You proved the GL is append-only for the app role
- [ ] **You performed a point-in-time restore and deleted the restored server**
- [ ] You can state RPO/RTO and explain HA ≠ backup
- [ ] Cosmos deployed, partition keys justified, then turned off
- [ ] You can explain hot partitions and the 20 GB logical limit
- [ ] All three "break it" exercises done; you know the two distinct auth errors
- [ ] `az aks stop` and `az postgres flexible-server stop` at session end

Next: [chapter 07 — Key Vault and secrets](07-keyvault-and-secrets.md)
