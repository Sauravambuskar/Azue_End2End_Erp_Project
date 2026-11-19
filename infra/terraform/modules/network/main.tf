# ---------------------------------------------------------------------------
# Hub-spoke network for the ERP platform.
#
#   HUB  10.0.0.0/16
#     AzureFirewallSubnet        10.0.0.0/26    (name is fixed by Azure)
#     AzureBastionSubnet         10.0.1.0/26    (name is fixed by Azure)
#     snet-shared-services       10.0.2.0/24
#
#   SPOKE 10.10.0.0/16
#     snet-aks-system            10.10.0.0/22   (system node pool)
#     snet-aks-user              10.10.4.0/22   (user node pool)
#     snet-aks-pods              10.10.8.0/22   (Azure CNI Overlay / pod subnet)
#     snet-appgw                 10.10.16.0/24  (Application Gateway WAF v2)
#     snet-private-endpoints     10.10.17.0/24  (PostgreSQL, Key Vault, ACR...)
#     snet-jump                  10.10.18.0/27
#
# All egress from the spoke is forced through the firewall by a UDR.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "network" {
  name     = var.rg_name
  location = var.location
  tags     = var.tags
}

# ------------------------------------------------------------------- hub VNet
resource "azurerm_virtual_network" "hub" {
  name                = var.hub_vnet_name
  resource_group_name = azurerm_resource_group.network.name
  location            = var.location
  address_space       = [var.hub_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_cidr, 10, 0)] # 10.0.0.0/26
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_cidr, 10, 64)] # 10.0.1.0/26
}

resource "azurerm_subnet" "shared" {
  name                 = "snet-shared-services"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_cidr, 8, 2)] # 10.0.2.0/24
}

# ----------------------------------------------------------------- spoke VNet
resource "azurerm_virtual_network" "spoke" {
  name                = var.spoke_vnet_name
  resource_group_name = azurerm_resource_group.network.name
  location            = var.location
  address_space       = [var.spoke_cidr]
  tags                = var.tags
}

locals {
  spoke_subnets = {
    aks_system = { cidr = cidrsubnet(var.spoke_cidr, 6, 0) } # 10.10.0.0/22
    aks_user   = { cidr = cidrsubnet(var.spoke_cidr, 6, 1) } # 10.10.4.0/22
    aks_pods   = { cidr = cidrsubnet(var.spoke_cidr, 6, 2) } # 10.10.8.0/22
  }
}

resource "azurerm_subnet" "aks_system" {
  name                 = "snet-aks-system"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.spoke_subnets.aks_system.cidr]
  service_endpoints    = ["Microsoft.Storage", "Microsoft.KeyVault"]
}

resource "azurerm_subnet" "aks_user" {
  name                 = "snet-aks-user"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.spoke_subnets.aks_user.cidr]
  service_endpoints    = ["Microsoft.Storage", "Microsoft.KeyVault"]
}

resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.spoke_cidr, 8, 16)] # 10.10.16.0/24
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.spoke_cidr, 8, 17)] # 10.10.17.0/24

  private_endpoint_network_policies = "Enabled"
}

# Delegated subnet for PostgreSQL Flexible Server VNet injection.
resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.spoke_cidr, 8, 19)] # 10.10.19.0/24

  delegation {
    name = "psql-delegation"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# ------------------------------------------------------------------- peering
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "peer-hub-to-spoke"
  resource_group_name          = azurerm_resource_group.network.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "peer-spoke-to-hub"
  resource_group_name          = azurerm_resource_group.network.name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
}

# ----------------------------------------------------------- private DNS zones
# One zone per PaaS service. Linked to BOTH VNets so pods and jump hosts
# resolve private IPs, never public endpoints.
locals {
  private_dns_zones = {
    postgres = "privatelink.postgres.database.azure.com"
    keyvault = "privatelink.vaultcore.azure.net"
    acr      = "privatelink.azurecr.io"
    blob     = "privatelink.blob.core.windows.net"
    cosmos   = "privatelink.documents.azure.com"
    sb       = "privatelink.servicebus.windows.net"
    monitor  = "privatelink.monitor.azure.com"
  }
}

resource "azurerm_private_dns_zone" "zones" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.network.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke_links" {
  for_each              = local.private_dns_zones
  name                  = "link-spoke-${each.key}"
  resource_group_name   = azurerm_resource_group.network.name
  private_dns_zone_name = azurerm_private_dns_zone.zones[each.key].name
  virtual_network_id    = azurerm_virtual_network.spoke.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub_links" {
  for_each              = local.private_dns_zones
  name                  = "link-hub-${each.key}"
  resource_group_name   = azurerm_resource_group.network.name
  private_dns_zone_name = azurerm_private_dns_zone.zones[each.key].name
  virtual_network_id    = azurerm_virtual_network.hub.id
  registration_enabled  = false
  tags                  = var.tags
}
