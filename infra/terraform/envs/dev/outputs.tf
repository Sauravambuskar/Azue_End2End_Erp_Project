# Outputs are proxied from the stack module. Consumed by:
#   * scripts/configure-kubectl.sh
#   * pipelines/templates/stage-deploy.yml
#   * scripts/db-grant-identities.sh

output "resource_groups" {
  value = module.platform.resource_groups
}

output "aks_name" {
  value = module.platform.aks_name
}

output "aks_resource_group" {
  value = module.platform.aks_resource_group
}

output "aks_oidc_issuer_url" {
  value = module.platform.aks_oidc_issuer_url
}

output "acr_login_server" {
  value = module.platform.acr_login_server
}

output "acr_name" {
  value = module.platform.acr_name
}

output "key_vault_name" {
  value = module.platform.key_vault_name
}

output "key_vault_uri" {
  value = module.platform.key_vault_uri
}

output "postgres_fqdn" {
  value = module.platform.postgres_fqdn
}

output "postgres_database" {
  value = module.platform.postgres_database
}

output "postgres_name" {
  value = module.platform.postgres_name
}

output "log_analytics_workspace_id" {
  value = module.platform.log_analytics_workspace_id
}

output "app_insights_connection_string" {
  value     = module.platform.app_insights_connection_string
  sensitive = true
}

output "action_group_id" {
  value = module.platform.action_group_id
}

output "workload_identity_client_ids" {
  description = "Put these into the Helm values as serviceAccount annotations."
  value       = module.platform.workload_identity_client_ids
}

output "workload_identity_names" {
  description = "Needed by pgaadauth_create_principal for passwordless DB access."
  value       = module.platform.workload_identity_names
}

output "appgw_fqdn" {
  value = module.platform.appgw_fqdn
}

output "cosmos_endpoint" {
  value = module.platform.cosmos_endpoint
}

output "next_steps" {
  value = module.platform.next_steps
}
