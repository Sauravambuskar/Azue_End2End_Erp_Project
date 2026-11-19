output "endpoint" {
  value = var.enabled ? azurerm_cosmosdb_account.this[0].endpoint : null
}

output "account_name" {
  value = var.enabled ? azurerm_cosmosdb_account.this[0].name : null
}

output "id" {
  value = var.enabled ? azurerm_cosmosdb_account.this[0].id : null
}
