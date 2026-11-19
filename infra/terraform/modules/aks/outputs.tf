output "id" { value = azurerm_kubernetes_cluster.this.id }
output "name" { value = azurerm_kubernetes_cluster.this.name }

output "oidc_issuer_url" {
  description = "Feed this into the identity module's federated credentials."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}

output "kubelet_identity_object_id" {
  value = var.kubelet_identity_object_id
}

output "private_fqdn" {
  value = azurerm_kubernetes_cluster.this.private_fqdn
}

output "ingress_appgw_identity_principal_id" {
  description = "AGIC's identity; needs Contributor on the App Gateway."
  value = try(
    azurerm_kubernetes_cluster.this.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id,
    null
  )
}

# Deliberately NOT exposing kube_config: local accounts are disabled and
# credentials are obtained per-user via `az aks get-credentials`. Printing a
# kubeconfig into Terraform state is a finding, not a convenience.
