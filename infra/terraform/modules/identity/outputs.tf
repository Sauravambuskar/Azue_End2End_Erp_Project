output "identity_ids" {
  value = { for k, v in azurerm_user_assigned_identity.workload : k => v.id }
}

output "client_ids" {
  description = "Annotate the Kubernetes ServiceAccounts with these."
  value       = { for k, v in azurerm_user_assigned_identity.workload : k => v.client_id }
}

output "principal_ids" {
  value = { for k, v in azurerm_user_assigned_identity.workload : k => v.principal_id }
}

output "identity_names" {
  description = "Used by scripts/db-grant-identities.sh to create PG principals."
  value       = { for k, v in azurerm_user_assigned_identity.workload : k => v.name }
}

output "service_account_annotations" {
  description = "Ready-to-paste values for the Helm values file."
  value = {
    for k, w in local.workloads : w.service_account => {
      "azure.workload.identity/client-id" = azurerm_user_assigned_identity.workload[k].client_id
      "azure.workload.identity/tenant-id" = data.azurerm_client_config.current.tenant_id
    }
  }
}
