output "rg_name" { value = azurerm_resource_group.network.name }
output "hub_vnet_id" { value = azurerm_virtual_network.hub.id }
output "spoke_vnet_id" { value = azurerm_virtual_network.spoke.id }
output "spoke_vnet_name" { value = azurerm_virtual_network.spoke.name }

output "subnet_ids" {
  description = "Subnet ids consumed by the aks / appgw / postgres modules."
  value = {
    firewall          = azurerm_subnet.firewall.id
    bastion           = azurerm_subnet.bastion.id
    shared            = azurerm_subnet.shared.id
    aks_system        = azurerm_subnet.aks_system.id
    aks_user          = azurerm_subnet.aks_user.id
    appgw             = azurerm_subnet.appgw.id
    private_endpoints = azurerm_subnet.private_endpoints.id
    postgres          = azurerm_subnet.postgres.id
  }
}

output "appgw_subnet_cidr" { value = azurerm_subnet.appgw.address_prefixes[0] }

output "private_dns_zone_ids" {
  value = { for k, z in azurerm_private_dns_zone.zones : k => z.id }
}

output "private_dns_zone_names" {
  value = { for k, z in azurerm_private_dns_zone.zones : k => z.name }
}

output "nsg_ids" {
  value = {
    appgw             = azurerm_network_security_group.appgw.id
    aks               = azurerm_network_security_group.aks.id
    private_endpoints = azurerm_network_security_group.private_endpoints.id
  }
}
