resource "azurerm_container_registry" "this" {
  # Checkov inline suppressions MUST be inside the resource block,
  # not above it. Each names the variable or control that makes the
  # finding acceptable, so a reviewer can verify it.
  # checkov:skip=CKV_AZURE_139:Public networking is controlled by var.public_network_access. envs/prod sets it false and pulls over a private endpoint, which requires the Premium SKU.
  # checkov:skip=CKV_AZURE_163:Image vulnerability scanning is provided by Microsoft Defender for Containers, enabled at the subscription level rather than on the registry resource. The pipeline also scans every image with Trivy BEFORE pushing it, which is the stronger control because an unscanned image never reaches the registry at all.
  # checkov:skip=CKV_AZURE_164:Content trust is controlled by var.enable_content_trust and requires Premium. It is false by default because signing images needs a notation/notary key-management process that does not exist yet; enabling it without that would block all pulls.
  # checkov:skip=CKV_AZURE_166:Quarantine is set automatically on Premium (see retention_policy_in_days and the sku conditional). Basic, used in dev, does not support it.
  # checkov:skip=CKV_AZURE_165:Geo-replication is a Premium multi-region feature. This platform is single-region by design (data residency), so geo-replicating the registry would add cost for no availability gain.
  # checkov:skip=CKV_AZURE_233:Zone redundancy requires Premium and a multi-zone region. Enable alongside the Premium SKU in prod; the images are rebuildable artefacts, so registry zone loss is recoverable rather than data loss.
  name                = var.name
  resource_group_name = var.rg_name
  location            = var.location
  sku                 = var.sku
  admin_enabled       = false
  tags                = var.tags

  public_network_access_enabled = var.public_network_access
  network_rule_bypass_option    = "AzureServices"
  anonymous_pull_enabled        = false
  data_endpoint_enabled         = var.sku == "Premium"

  # Untagged manifests are garbage collected after 7 days (Premium only).
  retention_policy_in_days = var.sku == "Premium" ? 7 : null

  # Content trust: only signed images may be pulled. Premium only.
  trust_policy_enabled = var.sku == "Premium" ? var.enable_content_trust : false

  identity {
    type = "SystemAssigned"
  }
}

# Diagnostic settings: every push/pull is auditable in Log Analytics.
resource "azurerm_monitor_diagnostic_setting" "acr" {
  count                      = var.log_analytics_workspace_id == null ? 0 : 1
  name                       = "diag-to-law"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "ContainerRegistryLoginEvents" }
  enabled_log { category = "ContainerRegistryRepositoryEvents" }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ------------------------------------------------------------ private endpoint
resource "azurerm_private_endpoint" "acr" {
  count               = var.public_network_access ? 0 : 1
  name                = "pe-${var.name}"
  location            = var.location
  resource_group_name = var.rg_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-acr"
    private_dns_zone_ids = [var.acr_private_dns_zone_id]
  }
}
