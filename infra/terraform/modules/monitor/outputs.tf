output "law_id" { value = azurerm_log_analytics_workspace.this.id }
output "law_name" { value = azurerm_log_analytics_workspace.this.name }
output "law_guid" { value = azurerm_log_analytics_workspace.this.workspace_id }

output "appi_id" { value = azurerm_application_insights.this.id }
output "appi_connection_string" {
  value     = azurerm_application_insights.this.connection_string
  sensitive = true
}
output "appi_instrumentation_key" {
  value     = azurerm_application_insights.this.instrumentation_key
  sensitive = true
}

output "action_group_id" { value = azurerm_monitor_action_group.oncall.id }
output "dashboard_id" { value = azurerm_portal_dashboard.platform.id }
