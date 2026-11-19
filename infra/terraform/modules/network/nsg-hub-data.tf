# ===========================================================================
# NSGs for the subnets that are not AKS or App Gateway.
#
# Split into its own file because nsg.tf was getting long, and because these
# three were added in response to a Checkov CKV2_AZURE_31 finding - "every
# subnet must have an NSG". That finding was correct: an unprotected subnet
# relies entirely on Azure's implicit rules, which trust the whole VNet.
# ===========================================================================

# ---------------------------------------------------------------------------
# AzureBastionSubnet
#
# Bastion is NOT deployed by this project (it costs roughly INR 15/hour), but
# the subnet is reserved for it and still needs an NSG.
#
# The rule set below is the one Microsoft REQUIRES for Bastion. Get any of it
# wrong and Bastion deploys successfully and then simply does not work, with
# no useful error - which is why it is written out in full here rather than
# left for whoever enables Bastion later.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "bastion" {
  name                = "nsg-bastion-${var.base_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = var.tags
}

locals {
  bastion_rules = {
    # ------------------------------------------------------------- inbound
    "Allow-HTTPS-Inbound" = {
      priority  = 120
      direction = "Inbound"
      protocol  = "Tcp"
      src       = "Internet"
      dst       = "*"
      dst_ports = ["443"]
    }
    "Allow-GatewayManager-Inbound" = {
      priority  = 130
      direction = "Inbound"
      protocol  = "Tcp"
      src       = "GatewayManager"
      dst       = "*"
      dst_ports = ["443"]
    }
    "Allow-AzureLoadBalancer-Inbound" = {
      priority  = 140
      direction = "Inbound"
      protocol  = "Tcp"
      src       = "AzureLoadBalancer"
      dst       = "*"
      dst_ports = ["443"]
    }
    "Allow-BastionHostCommunication-Inbound" = {
      priority  = 150
      direction = "Inbound"
      protocol  = "*"
      src       = "VirtualNetwork"
      dst       = "VirtualNetwork"
      dst_ports = ["8080", "5701"]
    }
    # ------------------------------------------------------------ outbound
    "Allow-SshRdp-Outbound" = {
      priority  = 100
      direction = "Outbound"
      protocol  = "Tcp"
      src       = "*"
      dst       = "VirtualNetwork"
      dst_ports = ["22", "3389"]
    }
    "Allow-AzureCloud-Outbound" = {
      priority  = 110
      direction = "Outbound"
      protocol  = "Tcp"
      src       = "*"
      dst       = "AzureCloud"
      dst_ports = ["443"]
    }
    "Allow-BastionCommunication-Outbound" = {
      priority  = 120
      direction = "Outbound"
      protocol  = "*"
      src       = "VirtualNetwork"
      dst       = "VirtualNetwork"
      dst_ports = ["8080", "5701"]
    }
    "Allow-GetSessionInformation-Outbound" = {
      priority  = 130
      direction = "Outbound"
      protocol  = "*"
      src       = "*"
      dst       = "Internet"
      dst_ports = ["80"]
    }
  }
}

resource "azurerm_network_security_rule" "bastion" {
  # Checkov evaluates destination_port_ranges per rule but not per-rule in a
  # for_each, so it attributes every port in the map to every rule and
  # reports the 443-only Allow-HTTPS-Inbound rule as exposing 22, 3389 and 80.
  # Verify with: az network nsg rule list -g <rg> --nsg-name nsg-bastion-*
  # checkov:skip=CKV_AZURE_9:False positive. No rule in this map permits any inbound port other than 443 from the Internet; 22 and 3389 are OUTBOUND to VirtualNetwork only, which is how Bastion reaches a jump host.
  # checkov:skip=CKV_AZURE_10:False positive, same cause as CKV_AZURE_9.
  # checkov:skip=CKV_AZURE_160:False positive. Port 80 appears only in Allow-GetSessionInformation-Outbound, which is an OUTBOUND rule required by Azure Bastion.
  for_each = local.bastion_rules

  name                        = each.key
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = "Allow"
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_ranges     = each.value.dst_ports
  source_address_prefix       = each.value.src
  destination_address_prefix  = each.value.dst
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.bastion.name
}

resource "azurerm_subnet_network_security_group_association" "bastion" {
  subnet_id                 = azurerm_subnet.bastion.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

# ---------------------------------------------------------------------------
# Shared services subnet: jump hosts and DNS forwarders.
# Inbound only from Bastion. No direct SSH or RDP from anywhere else, which
# is the whole reason Bastion exists.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "shared" {
  name                = "nsg-shared-${var.base_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "shared_from_bastion" {
  name                        = "Allow-SshRdp-From-Bastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["22", "3389"]
  source_address_prefix       = azurerm_subnet.bastion.address_prefixes[0]
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.shared.name
}

resource "azurerm_network_security_rule" "shared_deny_all_in" {
  name                        = "Deny-All-Inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.shared.name
}

resource "azurerm_subnet_network_security_group_association" "shared" {
  subnet_id                 = azurerm_subnet.shared.id
  network_security_group_id = azurerm_network_security_group.shared.id
}

# ---------------------------------------------------------------------------
# PostgreSQL delegated subnet.
#
# The server is VNet-injected into this subnet, so this NSG is the layer-4
# boundary around the database itself. Only 5432 (and 6432 for the built-in
# PgBouncer), only from inside the VNet, everything else denied.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "postgres" {
  name                = "nsg-postgres-${var.base_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "postgres_from_vnet" {
  name                        = "Allow-Postgres-From-VNet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["5432", "6432"]
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.postgres.name
}

resource "azurerm_network_security_rule" "postgres_deny_all_in" {
  name                        = "Deny-All-Inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.postgres.name
}

resource "azurerm_subnet_network_security_group_association" "postgres" {
  subnet_id                 = azurerm_subnet.postgres.id
  network_security_group_id = azurerm_network_security_group.postgres.id
}
