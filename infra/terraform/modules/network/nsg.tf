# ---------------------------------------------------------------------------
# Network Security Groups - the per-subnet layer-4 firewall.
#
# Design rule used throughout: DENY is explicit and last. Azure already has an
# implicit deny at 65500, but writing it makes intent reviewable and lets the
# "no 0.0.0.0/0 inbound" Azure Policy pass audit cleanly.
# ---------------------------------------------------------------------------

# ----------------------------------------------------------------- App Gateway
resource "azurerm_network_security_group" "appgw" {
  name                = "nsg-appgw-${var.base_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = var.tags
}

# Required by Azure: the Gateway Manager health probes.
resource "azurerm_network_security_rule" "appgw_gwm" {
  name                        = "Allow-GatewayManager-Inbound"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "GatewayManager"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_https" {
  name                        = "Allow-HTTPS-Inbound"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_http_redirect" {
  # Checkov inline suppressions MUST be inside the resource block,
  # not above it. Each names the variable or control that makes the
  # finding acceptable, so a reviewer can verify it.
  # checkov:skip=CKV_AZURE_160:Port 80 is open to the internet only so the Application Gateway can issue a 301 redirect to HTTPS; no backend is ever reached over HTTP. The alternative, dropping port 80, makes an http:// link time out rather than redirect, which users experience as an outage.
  name                        = "Allow-HTTP-For-Redirect"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_lb" {
  name                        = "Allow-AzureLoadBalancer-Inbound"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_deny_all_in" {
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
  network_security_group_name = azurerm_network_security_group.appgw.name
}

# ------------------------------------------------------------------- AKS nodes
resource "azurerm_network_security_group" "aks" {
  name                = "nsg-aks-${var.base_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = var.tags
}

# Only the App Gateway subnet may reach the ingress controller.
resource "azurerm_network_security_rule" "aks_from_appgw" {
  name                        = "Allow-AppGW-To-Ingress"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443", "8000", "3000"]
  source_address_prefix       = azurerm_subnet.appgw.address_prefixes[0]
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_network_security_rule" "aks_intra_vnet" {
  name                        = "Allow-Intra-VNet"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_network_security_rule" "aks_deny_internet_in" {
  name                        = "Deny-Internet-Inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# --------------------------------------------------------- private endpoints
resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-pe-${var.base_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "pe_from_vnet" {
  name                        = "Allow-VNet-To-PrivateEndpoints"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["443", "5432", "10255"]
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_network_security_rule" "pe_deny_all" {
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
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

# ---------------------------------------------------------------- associations
resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

resource "azurerm_subnet_network_security_group_association" "aks_system" {
  subnet_id                 = azurerm_subnet.aks_system.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

resource "azurerm_subnet_network_security_group_association" "aks_user" {
  subnet_id                 = azurerm_subnet.aks_user.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# ------------------------------------------------------------ NSG flow logs
# Flow logs land in storage and are analysed by Traffic Analytics in LAW.
resource "azurerm_network_watcher_flow_log" "aks" {
  count = var.enable_flow_logs ? 1 : 0

  name                 = "fl-aks-${var.base_name}"
  network_watcher_name = var.network_watcher_name
  resource_group_name  = var.network_watcher_rg
  location             = var.location

  target_resource_id = azurerm_network_security_group.aks.id
  storage_account_id = var.flow_log_storage_account_id
  enabled            = true
  version            = 2

  retention_policy {
    enabled = true
    days    = 30
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = var.log_analytics_workspace_guid
    workspace_region      = var.location
    workspace_resource_id = var.log_analytics_workspace_id
    interval_in_minutes   = 10
  }

  tags = var.tags
}
