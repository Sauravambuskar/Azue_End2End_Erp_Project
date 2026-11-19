resource "azurerm_postgresql_flexible_server" "this" {
  # Checkov inline suppressions MUST be inside the resource block,
  # not above it. Each names the variable or control that makes the
  # finding acceptable, so a reviewer can verify it.
  # checkov:skip=CKV_AZURE_136:Geo-redundant backup is controlled by var.geo_redundant_backup. envs/prod sets true. It cannot be changed after creation, which is why it is an explicit input rather than a default.
  # checkov:skip=CKV2_AZURE_57:This server uses VNET INJECTION into a delegated subnet rather than a private endpoint, which is a stronger posture: public_network_access_enabled is false and there is no public endpoint to misconfigure at all. Checkov only recognises the private-endpoint pattern. The delegated subnet is additionally protected by nsg-postgres, which allows only 5432 from inside the VNet.
  name                = var.name
  resource_group_name = var.rg_name
  location            = var.location
  version             = var.pg_version
  tags                = var.tags

  sku_name     = var.sku_name
  storage_mb   = var.storage_mb
  storage_tier = var.storage_tier

  # VNet injection: the server lives inside your subnet, no public IP.
  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id
  public_network_access_enabled = false

  zone = var.zone

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup

  # Password auth stays on only because the local/dev workflow and the
  # bootstrap migration need it. Flip password_auth_enabled to false for the
  # "passwordless only" exercise in guidance/06.
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = var.password_auth_enabled
    tenant_id                     = var.tenant_id
  }

  administrator_login    = var.password_auth_enabled ? var.admin_username : null
  administrator_password = var.password_auth_enabled ? var.admin_password : null

  dynamic "high_availability" {
    for_each = var.high_availability_mode == null ? [] : [1]
    content {
      mode                      = var.high_availability_mode
      standby_availability_zone = var.standby_zone
    }
  }

  maintenance_window {
    day_of_week  = 0 # Sunday
    start_hour   = 2
    start_minute = 0
  }

  lifecycle {
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "erp" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = false # set true for prod; false keeps the lab teardown easy
  }
}

# ------------------------------------------------- Entra ID administrator
# Makes a group (or your own user) the AAD admin, so you can then run
# pgaadauth_create_principal for each managed identity.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "admin" {
  count = var.aad_admin_object_id == null ? 0 : 1

  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = var.rg_name
  tenant_id           = var.tenant_id
  object_id           = var.aad_admin_object_id
  principal_name      = var.aad_admin_principal_name
  principal_type      = var.aad_admin_principal_type
}

# ------------------------------------------------------- server parameters
locals {
  server_parameters = {
    # Force TLS
    require_secure_transport = "ON"
    ssl_min_protocol_version = "TLSv1.2"

    # Audit logging - this is what the "database activity" KQL queries read.
    "pgaudit.log"            = "WRITE,DDL,ROLE"
    "pgaudit.log_catalog"    = "off"
    shared_preload_libraries = "pgaudit,pg_stat_statements"

    # Slow query visibility
    log_min_duration_statement = "1000"
    "pg_stat_statements.track" = "all"

    # Connection hygiene for a pooled app
    idle_in_transaction_session_timeout = "300000" # 5 min
    log_connections                     = "on"
    log_disconnections                  = "on"
    log_checkpoints                     = "on"
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "params" {
  for_each = local.server_parameters

  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = each.value
}

# ------------------------------------------------------------------- audit
resource "azurerm_monitor_diagnostic_setting" "pg" {
  count                      = var.log_analytics_workspace_id == null ? 0 : 1
  name                       = "diag-to-law"
  target_resource_id         = azurerm_postgresql_flexible_server.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "PostgreSQLLogs" }
  enabled_log { category = "PostgreSQLFlexSessions" }
  enabled_log { category = "PostgreSQLFlexQueryStoreRuntime" }

  enabled_metric {
    category = "AllMetrics"
  }
}

# --------------------------------------------------------- cost-saving alert
resource "azurerm_monitor_metric_alert" "storage_full" {
  count = var.log_analytics_workspace_id == null ? 0 : 1

  name                = "alert-${var.name}-storage-pressure"
  resource_group_name = var.rg_name
  scopes              = [azurerm_postgresql_flexible_server.this.id]
  description         = "PostgreSQL storage above 85% - grow it before it stops accepting writes."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  dynamic "action" {
    for_each = var.action_group_id == null ? [] : [1]
    content {
      action_group_id = var.action_group_id
    }
  }
}
