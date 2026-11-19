# Database layer

| Path | Purpose |
|---|---|
| `migrations/V001__initial_schema.sql` | Tables, enums, indexes, constraints |
| `migrations/V002__least_privilege_roles.sql` | DB roles + Entra ID principal binding |
| `migrations/V003__reporting_views.sql` | Views for dashboards and the worker |
| `seed/seed.sql` | Demo master data (idempotent) |

## Rules this project follows

1. **Forward-only migrations.** No `DOWN` scripts. A mistake is fixed by a new
   `Vnnn` file. This is what the pipeline's change-approval gate assumes.
2. **Idempotent.** Every file can be re-run; the pipeline does not track state
   beyond the `schema_version` table.
3. **Separate identity for schema changes.** Runtime pods hold `erp_app`
   (DML only). Only the migration job's managed identity holds `erp_migrator`.
4. **No passwords anywhere.** Connections use Entra ID tokens. See
   `../guidance/07-keyvault-and-secrets.md`.

## Apply locally

```bash
docker compose up -d postgres
psql "postgres://erpadmin:localpw@localhost:5432/erp" -f migrations/V001__initial_schema.sql
psql "postgres://erpadmin:localpw@localhost:5432/erp" -f migrations/V003__reporting_views.sql
psql "postgres://erpadmin:localpw@localhost:5432/erp" -f seed/seed.sql
```

> V002 creates roles that only matter in Azure; it is safe to skip locally.

## Apply in Azure

Migrations run as a **Helm `pre-upgrade` hook** - see
[`k8s/helm/erp/templates/migrate-job.yaml`](../k8s/helm/erp/templates/migrate-job.yaml).
The Job executes inside the cluster, because the Flexible Server is
VNet-injected and has **no public endpoint** at all. If the Job fails, the
Helm upgrade aborts and the old pods keep serving - so application code never
runs against a half-migrated schema.
