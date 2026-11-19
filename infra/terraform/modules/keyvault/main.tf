# ---------------------------------------------------------------------------
# Azure Key Vault - RBAC mode, purge protection, private endpoint.
#
# Interview-ready reasoning:
#  * rbac_authorization_enabled = true  -> Entra RBAC, not legacy access
#    policies. One permission model across the whole platform.
#  * purge_protection_enabled = true   -> a deleted secret cannot be
#    permanently destroyed inside the retention window. Required by most
#    compliance baselines and by Defender for Cloud recommendations.
#  * public_network_access disabled in prod; access via private endpoint.
#  * The app NEVER reads a password: Postgres uses Entra tokens. The vault
#    holds only things that genuinely must be secrets (API keys, certs).
# ---------------------------------------------------------------------------
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  # Checkov inline suppressions MUST be inside the resource block,
  # not above it. Each names the variable or control that makes the
  # finding acceptable, so a reviewer can verify it.
  # checkov:skip=CKV_AZURE_109:Network ACLs are controlled by var.public_network_access. envs/prod sets it false, which sets default_action to Deny and adds a private endpoint. Dev keeps an IP-restricted public endpoint so a learner can read secrets from a laptop without a VPN.
  # checkov:skip=CKV_AZURE_110:Purge protection is controlled by var.purge_protection. envs/prod sets true. It is deliberately false in dev because it is irreversible and would lock the vault name for up to 90 days after every teardown.
  # checkov:skip=CKV_AZURE_42:Recoverability is soft delete plus purge protection. Soft delete is always on; purge protection is var.purge_protection, true in prod.
  name                = var.name
  resource_group_name = var.rg_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = var.sku
  tags                = var.tags

  rbac_authorization_enabled    = true
  purge_protection_enabled      = var.purge_protection
  soft_delete_retention_days    = var.soft_delete_retention_days
  public_network_access_enabled = var.public_network_access

  network_acls {
    bypass         = "AzureServices"
    default_action = var.public_network_access ? "Allow" : "Deny"
    ip_rules       = var.allowed_ip_rules
  }
}

# -------------------------------------------------------------------- secrets
# Only secrets that must exist as secrets. Values come from pipeline variables
# marked secret, or are generated here and never printed.
resource "random_password" "generated" {
  for_each = var.generated_secrets

  length           = each.value.length
  special          = each.value.special
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "azurerm_key_vault_secret" "generated" {
  for_each = var.generated_secrets

  name            = each.key
  value           = random_password.generated[each.key].result
  key_vault_id    = azurerm_key_vault.this.id
  content_type    = "generated-by-terraform"
  expiration_date = timeadd(timestamp(), "8760h") # 1 year
  tags            = var.tags

  lifecycle {
    # Do not rotate on every apply just because timestamp() moved.
    ignore_changes = [expiration_date, value]
  }
}

# ---------------------------------------------------------------------- audit
resource "azurerm_monitor_diagnostic_setting" "kv" {
  count                      = var.log_analytics_workspace_id == null ? 0 : 1
  name                       = "diag-to-law"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "AuditEvent" }
  enabled_log { category = "AzurePolicyEvaluationDetails" }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ----------------------------------------------------------- private endpoint
resource "azurerm_private_endpoint" "kv" {
  count               = var.public_network_access ? 0 : 1
  name                = "pe-${var.name}"
  location            = var.location
  resource_group_name = var.rg_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-kv"
    private_dns_zone_ids = [var.keyvault_private_dns_zone_id]
  }
}
