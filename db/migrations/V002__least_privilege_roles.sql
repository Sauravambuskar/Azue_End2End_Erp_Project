-- =====================================================================
-- ContosoERP  V002  database-level least privilege + Entra ID principals
--
-- INTERVIEW POINT: application identities get table-level DML only. No
-- DDL, no superuser. The migration job runs as a *different*, higher
-- privileged identity which the runtime pods never have.
-- =====================================================================
BEGIN;

-- Application roles (NOLOGIN; real principals are granted INTO these)
DO $$ BEGIN CREATE ROLE erp_app      NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE erp_readonly NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE erp_migrator NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT  USAGE ON SCHEMA public TO erp_app, erp_readonly, erp_migrator;

-- Runtime: DML only, never DDL
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO erp_app;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO erp_app;

-- Reporting / Power BI
GRANT SELECT ON ALL TABLES IN SCHEMA public TO erp_readonly;

-- Migration identity
GRANT CREATE ON SCHEMA public TO erp_migrator;
GRANT ALL ON ALL TABLES    IN SCHEMA public TO erp_migrator;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO erp_migrator;

-- Future objects inherit the same grants
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO erp_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO erp_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO erp_readonly;

-- Protect the ledger: GL rows are append-only, even for the app role.
REVOKE UPDATE, DELETE ON gl_entry FROM erp_app;

-- ------------------------------------------------------------------
-- Bind Entra ID (AAD) principals. Run scripts/db-grant-identities.sh,
-- which substitutes the real managed-identity names created by Terraform.
-- Left as documentation here because the names are environment-specific:
--
--   SELECT * FROM pgaadauth_create_principal('id-erp-api-dev',    false, false);
--   SELECT * FROM pgaadauth_create_principal('id-erp-worker-dev', false, false);
--   SELECT * FROM pgaadauth_create_principal('id-erp-migrate-dev',false, false);
--   GRANT erp_app      TO "id-erp-api-dev";
--   GRANT erp_app      TO "id-erp-worker-dev";
--   GRANT erp_migrator TO "id-erp-migrate-dev";
-- ------------------------------------------------------------------

INSERT INTO schema_version(version) VALUES ('V002') ON CONFLICT DO NOTHING;
COMMIT;
