# ===========================================================================
# ContosoERP - PROD root module.
#
# Same stack as dev. Every difference is a value, not a different
# architecture - which is the point of the stacks/ layer, and the thing you
# want to be able to say about a production environment.
#
# PROD POSTURE, and what each setting buys:
#
#   aks_private_cluster = true
#       The API server has NO public IP. Consequence you must plan for: a
#       Microsoft-hosted pipeline agent can no longer reach it. You need a
#       self-hosted agent in the VNet, Managed DevOps Pools, or
#       `az aks command invoke` (which is a deliberate bypass of the network
#       controls, so not in prod). See guidance/08 section 8.
#
#   aks_local_account_disabled = true
#       Removes the static cluster-admin certificate. Entra ID becomes the
#       only way in, so every kubectl call is attributable to a person or a
#       workload identity. Consequence: if Entra ID is unavailable you cannot
#       reach the cluster. That is the correct trade-off, but it is a trade-off.
#
#   allow_public_platform_access = false
#       ACR and Key Vault lose their public endpoints and are reachable only
#       through private endpoints. REQUIRES acr_sku = "Premium" - private
#       endpoints are not available on Basic or Standard.
#
#   key_vault_purge_protection = true
#       A deleted secret cannot be permanently destroyed inside the retention
#       window, which defends against a malicious or accidental hard delete by
#       an administrator. IRREVERSIBLE once enabled, and it means the vault
#       name is unavailable for up to 90 days after a delete.
#
#   postgres_password_auth_enabled = false
#       Entra ID is the only way to authenticate to the database. Run
#       scripts/db-grant-identities.sh BEFORE flipping this, or the migration
#       job has no way in.
#
#   postgres_high_availability_mode = "ZoneRedundant"
#       ~60 second failover on a zone failure. Roughly DOUBLES the database
#       cost, because you are paying for a hot standby. Note that HA is not
#       backup: it replicates logical corruption instantly.
#
#   enable_firewall = true
#       All egress forced through Azure Firewall with an FQDN allow-list, so
#       a compromised pod cannot exfiltrate. This also switches the cluster's
#       outbound_type to userDefinedRouting.
#
# ---------------------------------------------------------------------------
# DO NOT APPLY THIS IN A LEARNING SUBSCRIPTION WITHOUT READING guidance/13.
# With the firewall and App Gateway enabled this costs roughly USD 35/day.
# It exists so the dev/prod delta is explicit and reviewable, and so the
# infra pipeline's `prod` path is real rather than a dead reference.
# ---------------------------------------------------------------------------
# ===========================================================================

module "platform" {
  source = "../../stacks/erp-platform"

  env      = "prod"
  workload = "erp"
  location = var.location

  owner_email = var.owner_email
  cost_centre = var.cost_centre

  # ------------------------------------------------------------- networking
  # A separate address space from dev, so the two can be peered to the same
  # hub later without colliding.
  hub_cidr     = var.hub_cidr
  spoke_cidr   = var.spoke_cidr
  my_public_ip = var.my_public_ip

  # ----------------------------------------------------- security posture
  allow_public_platform_access = false
  key_vault_purge_protection   = true
  aks_private_cluster          = true
  aks_local_account_disabled   = true
  aks_sku_tier                 = "Standard" # uptime SLA + cost analysis

  # --------------------------------------------------------------- sizing
  kubernetes_version = var.kubernetes_version
  node_vm_size       = var.node_vm_size
  availability_zones = ["1", "2", "3"] # spread across all three zones
  system_node_min    = 2               # survive losing one system node
  system_node_max    = 4
  user_node_min      = 3
  user_node_max      = 12
  acr_sku            = "Premium" # required for private endpoints
  log_daily_quota_gb = var.log_daily_quota_gb

  # ------------------------------------------------------------- database
  postgres_sku                    = var.postgres_sku
  postgres_backup_retention_days  = 35
  postgres_geo_redundant_backup   = true
  postgres_high_availability_mode = "ZoneRedundant"
  postgres_password_auth_enabled  = false # Entra ID only
  postgres_admin_password         = null

  db_aad_admin_object_id      = var.db_aad_admin_object_id
  db_aad_admin_principal_name = var.db_aad_admin_principal_name
  db_aad_admin_principal_type = "Group" # a group, never a person, in prod

  # ------------------------------------------------------------- identity
  aks_admin_group_object_ids     = var.aks_admin_group_object_ids
  ci_service_principal_object_id = var.ci_service_principal_object_id
  k8s_namespace                  = var.k8s_namespace
  group_role_assignments         = var.group_role_assignments

  # ----------------------------------------------------- production ingress
  enable_appgw    = true
  enable_firewall = true
  enable_cosmos   = var.enable_cosmos
}
