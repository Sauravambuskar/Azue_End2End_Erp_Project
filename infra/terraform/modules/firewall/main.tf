# ---------------------------------------------------------------------------
# Azure Firewall (hub) + route table that forces AKS egress through it.
#
# WARNING ABOUT COST: Azure Firewall Standard is roughly the most expensive
# thing in this project (~USD 1.2/hour plus data processing). The dev
# environment sets enabled = false. Turn it on, complete exercise 4 in
# guidance/03-networking.md, then turn it off again. The Basic SKU
# is cheaper and teaches the same concepts.
#
# Why it matters for the interview: egress lockdown is what separates a demo
# cluster from an enterprise one. AKS needs a specific allow-list to function
# at all, and knowing that list is a strong signal.
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "fw" {
  count = var.enabled ? 1 : 0

  name                = "pip-${var.name}"
  resource_group_name = var.rg_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall_policy" "this" {
  # Checkov inline suppressions MUST be inside the resource block,
  # not above it. Each names the variable or control that makes the
  # finding acceptable, so a reviewer can verify it.
  # checkov:skip=CKV_AZURE_216:DenyIntelMode requires the Premium SKU. This module defaults to Basic for cost; threat_intelligence_mode is set to Alert, which logs matches. Set sku_tier to Premium and the mode to Deny for a production deployment.
  # checkov:skip=CKV_AZURE_220:IDPS is a Premium-only feature and is not available on the Basic SKU used here. See the note above.
  count = var.enabled ? 1 : 0

  name                     = "afwp-${var.name}"
  resource_group_name      = var.rg_name
  location                 = var.location
  sku                      = var.sku_tier
  threat_intelligence_mode = "Alert"
  tags                     = var.tags

  dns {
    proxy_enabled = true
  }
}

resource "azurerm_firewall_policy_rule_collection_group" "aks_required" {
  count = var.enabled ? 1 : 0

  name               = "rcg-aks-required"
  firewall_policy_id = azurerm_firewall_policy.this[0].id
  priority           = 200

  # --------------------------------------------------------- network rules
  network_rule_collection {
    name     = "nrc-aks-infra"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "allow-dns"
      protocols             = ["UDP", "TCP"]
      source_addresses      = [var.spoke_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["53"]
    }

    rule {
      name                  = "allow-ntp"
      protocols             = ["UDP"]
      source_addresses      = [var.spoke_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }

    # AKS control plane and Azure management, by service tag - never by IP.
    rule {
      name                  = "allow-azure-cloud-tcp"
      protocols             = ["TCP"]
      source_addresses      = [var.spoke_cidr]
      destination_addresses = ["AzureCloud.${var.location}"]
      destination_ports     = ["443", "9000"]
    }

    rule {
      name                  = "allow-azure-cloud-udp"
      protocols             = ["UDP"]
      source_addresses      = [var.spoke_cidr]
      destination_addresses = ["AzureCloud.${var.location}"]
      destination_ports     = ["1194", "123"]
    }
  }

  # ----------------------------------------------------- application rules
  application_rule_collection {
    name     = "arc-aks-fqdns"
    priority = 110
    action   = "Allow"

    # The FQDN tag does the heavy lifting: Microsoft maintains the list.
    rule {
      name                  = "allow-aks-fqdn-tag"
      source_addresses      = [var.spoke_cidr]
      destination_fqdn_tags = ["AzureKubernetesService"]
    }

    rule {
      name             = "allow-container-registries"
      source_addresses = [var.spoke_cidr]

      protocols {
        type = "Https"
        port = 443
      }

      destination_fqdns = [
        "*.azurecr.io",
        "*.blob.core.windows.net",
        "mcr.microsoft.com",
        "*.data.mcr.microsoft.com",
        "*.cdn.mscr.io",
      ]
    }

    rule {
      name             = "allow-os-and-package-updates"
      source_addresses = [var.spoke_cidr]

      protocols {
        type = "Https"
        port = 443
      }

      destination_fqdns = [
        "packages.microsoft.com",
        "azure.archive.ubuntu.com",
        "security.ubuntu.com",
        "*.ghcr.io",
        "pkg-containers.githubusercontent.com",
      ]
    }

    rule {
      name             = "allow-entra-keyvault-monitor"
      source_addresses = [var.spoke_cidr]

      protocols {
        type = "Https"
        port = 443
      }

      destination_fqdns = [
        "login.microsoftonline.com",
        "*.vault.azure.net",
        "*.monitor.azure.com",
        "*.ods.opinsights.azure.com",
        "*.oms.opinsights.azure.com",
        "dc.services.visualstudio.com",
      ]
    }
  }
}

resource "azurerm_firewall" "this" {
  # checkov:skip=CKV_AZURE_216:DenyIntelMode requires the Premium SKU. This module defaults to Basic for cost (Premium is roughly 3x). The attached policy sets threat_intelligence_mode = "Alert", so matches are logged to Log Analytics rather than silently allowed. Set sku_tier = "Premium" and the policy mode to "Deny" for a production deployment - see the cost warning at the top of this file.
  count = var.enabled ? 1 : 0

  name                = var.name
  resource_group_name = var.rg_name
  location            = var.location
  sku_name            = "AZFW_VNet"
  sku_tier            = var.sku_tier
  firewall_policy_id  = azurerm_firewall_policy.this[0].id
  zones               = var.availability_zones
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = var.firewall_subnet_id
    public_ip_address_id = azurerm_public_ip.fw[0].id
  }
}

# ---------------------------------------------------------- forced tunnelling
resource "azurerm_route_table" "spoke_egress" {
  count = var.enabled ? 1 : 0

  name                = "rt-spoke-egress-${var.env}"
  resource_group_name = var.rg_name
  location            = var.location
  tags                = var.tags

  bgp_route_propagation_enabled = false

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.this[0].ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "aks_subnets" {
  for_each = var.enabled ? toset(var.aks_subnet_ids) : toset([])

  subnet_id      = each.value
  route_table_id = azurerm_route_table.spoke_egress[0].id
}

resource "azurerm_monitor_diagnostic_setting" "fw" {
  count = var.enabled && var.log_analytics_workspace_id != null ? 1 : 0

  name                       = "diag-to-law"
  target_resource_id         = azurerm_firewall.this[0].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category_group = "allLogs" }

  enabled_metric {
    category = "AllMetrics"
  }
}
