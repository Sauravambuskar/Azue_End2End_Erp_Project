resource "azurerm_cosmosdb_account" "this" {
  # Checkov inline suppressions MUST be inside the resource block,
  # not above it. Each names the variable or control that makes the
  # finding acceptable, so a reviewer can verify it.
  # checkov:skip=CKV_AZURE_99:Access restriction is controlled by var.public_network_access; prod sets it false and reaches Cosmos over a private endpoint.
  # checkov:skip=CKV_AZURE_101:Same as above: var.public_network_access.
  # checkov:skip=CKV_AZURE_140:Local (key) authentication is controlled by var.disable_key_auth, which prod sets true so Entra ID data-plane RBAC is the only way in. It is false by default so the first exploration from a laptop works.
  # checkov:skip=CKV_AZURE_132:Management-plane changes are restricted by Azure RBAC on the account scope, not by the disable_key_based_metadata_write_access flag, because the pipeline legitimately needs to create containers.
  # checkov:skip=CKV_AZURE_100:Customer-managed keys are not used. Cosmos holds the audit trail and device telemetry, both classified internal; CMK would add a Key Vault dependency to the data path and a key-rotation process for no change to the threat model. The system of record, PostgreSQL, is the asset that would justify CMK.
  count = var.enabled ? 1 : 0

  name                = var.name
  resource_group_name = var.rg_name
  location            = var.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  tags                = var.tags

  # Serverless: no minimum spend.
  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }

  # Security posture
  public_network_access_enabled         = var.public_network_access
  local_authentication_disabled         = var.disable_key_auth
  automatic_failover_enabled            = false
  analytical_storage_enabled            = false
  minimal_tls_version                   = "Tls12"
  network_acl_bypass_for_azure_services = true

  backup {
    type                = "Periodic"
    interval_in_minutes = 1440
    retention_in_hours  = 48
    storage_redundancy  = "Local"
  }
}

resource "azurerm_cosmosdb_sql_database" "erp" {
  count = var.enabled ? 1 : 0

  name                = "erp"
  resource_group_name = var.rg_name
  account_name        = azurerm_cosmosdb_account.this[0].name
}

# Audit trail: partitioned by day so hot partitions cannot form, and TTL
# expires rows automatically instead of you writing a cleanup job.
resource "azurerm_cosmosdb_sql_container" "audit_trail" {
  count = var.enabled ? 1 : 0

  name                  = "audit_trail"
  resource_group_name   = var.rg_name
  account_name          = azurerm_cosmosdb_account.this[0].name
  database_name         = azurerm_cosmosdb_sql_database.erp[0].name
  partition_key_paths   = ["/partitionDate"]
  partition_key_version = 2
  default_ttl           = 60 * 60 * 24 * 400 # ~13 months

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/entity/?"
    }
    included_path {
      path = "/actor/?"
    }
    excluded_path {
      path = "/payload/*"
    }
  }
}

resource "azurerm_cosmosdb_sql_container" "device_telemetry" {
  count = var.enabled ? 1 : 0

  name                  = "device_telemetry"
  resource_group_name   = var.rg_name
  account_name          = azurerm_cosmosdb_account.this[0].name
  database_name         = azurerm_cosmosdb_sql_database.erp[0].name
  partition_key_paths   = ["/deviceId"]
  partition_key_version = 2
  default_ttl           = 60 * 60 * 24 * 90
}

# Data-plane RBAC: the API's managed identity gets the built-in
# "Cosmos DB Built-in Data Contributor" role. No account keys anywhere.
resource "azurerm_cosmosdb_sql_role_assignment" "api_data_contributor" {
  count = var.enabled && var.api_principal_id != null ? 1 : 0

  resource_group_name = var.rg_name
  account_name        = azurerm_cosmosdb_account.this[0].name
  role_definition_id  = "${azurerm_cosmosdb_account.this[0].id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = var.api_principal_id
  scope               = azurerm_cosmosdb_account.this[0].id
}

resource "azurerm_monitor_diagnostic_setting" "cosmos" {
  count = var.enabled && var.log_analytics_workspace_id != null ? 1 : 0

  name                       = "diag-to-law"
  target_resource_id         = azurerm_cosmosdb_account.this[0].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "DataPlaneRequests" }
  enabled_log { category = "ControlPlaneRequests" }

  enabled_metric {
    category = "Requests"
  }
}
