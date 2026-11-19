# These outputs are consumed by:
#   * scripts/configure-kubectl.sh
#   * the Helm values rendered in pipelines/templates/stage-deploy.yml
#   * scripts/db-grant-identities.sh

output "resource_groups" {
  value = {
    platform = azurerm_resource_group.platform.name
    data     = azurerm_resource_group.data.name
    aks      = azurerm_resource_group.aks.name
    network  = module.network.rg_name
  }
}

output "aks_name" {
  value = module.aks.name
}

output "aks_resource_group" {
  value = azurerm_resource_group.aks.name
}

output "aks_oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "acr_name" {
  value = module.acr.name
}

output "key_vault_name" {
  value = module.keyvault.name
}

output "key_vault_uri" {
  value = module.keyvault.uri
}

output "postgres_fqdn" {
  value = module.postgres.fqdn
}

output "postgres_database" {
  value = module.postgres.database_name
}

output "postgres_name" {
  value = module.postgres.name
}

output "log_analytics_workspace_id" {
  value = module.monitor.law_id
}

output "app_insights_connection_string" {
  value     = module.monitor.appi_connection_string
  sensitive = true
}

output "workload_identity_client_ids" {
  description = "Put these into the Helm values as serviceAccount annotations."
  value       = module.identity.client_ids
}

output "workload_identity_names" {
  description = "Needed by pgaadauth_create_principal for passwordless DB access."
  value       = module.identity.identity_names
}

output "appgw_fqdn" {
  value = var.enable_appgw ? module.appgw[0].fqdn : null
}

output "cosmos_endpoint" {
  value = module.cosmos.endpoint
}

# ---------------------------------------------------------------------------
# Handy next-step commands, printed after every apply.
# ---------------------------------------------------------------------------
output "next_steps" {
  value = <<-EOT

    ------------------------------------------------------------------
    Apply finished. Next:

    1. Get cluster credentials:
         az aks get-credentials -g ${azurerm_resource_group.aks.name} -n ${module.aks.name} --overwrite-existing

    2. Grant the managed identities access to PostgreSQL:
         ./scripts/db-grant-identities.sh

    3. Build and push images:
         az acr login -n ${module.acr.name}
         ./scripts/build-and-push.sh ${module.acr.login_server} v0.1.0

    4. Deploy:
         helm upgrade --install erp k8s/helm/erp --namespace erp --create-namespace --set image.registry=${module.acr.login_server} --set image.tag=v0.1.0

    Workload identity client ids:
    ${jsonencode(module.identity.client_ids)}
    ------------------------------------------------------------------
  EOT
}

output "action_group_id" {
  description = "Used by scripts and by other alert rules."
  value       = module.monitor.action_group_id
}
