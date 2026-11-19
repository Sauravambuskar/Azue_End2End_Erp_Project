output "private_ip" {
  value = var.enabled ? azurerm_firewall.this[0].ip_configuration[0].private_ip_address : null
}

output "public_ip" {
  value = var.enabled ? azurerm_public_ip.fw[0].ip_address : null
}

output "policy_id" {
  value = var.enabled ? azurerm_firewall_policy.this[0].id : null
}

output "route_table_id" {
  value = var.enabled ? azurerm_route_table.spoke_egress[0].id : null
}
