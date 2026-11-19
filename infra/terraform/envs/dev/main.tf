# ===========================================================================
# ContosoERP - DEV root module.
#
# This file is deliberately thin. All the architecture lives in
# ../../stacks/erp-platform, so dev, test and prod are provably the same
# platform differing only in the values passed in.
#
# DEV POSTURE (chosen so you can learn without locking yourself out):
#   * public AKS API server, restricted to your IP
#   * local cluster accounts left enabled
#   * ACR and Key Vault public, IP-restricted, so docker push works
#   * no HA, 7-day backups, Free AKS tier
#   * firewall and App Gateway OFF (they are the expensive ones)
#
# Usage:
#   export ARM_USE_AZUREAD=true
#   export TF_VAR_postgres_admin_password="$(openssl rand -base64 24)"
#   terraform init -backend-config=backend.hcl
#   terraform plan -out=tfplan
#   terraform apply tfplan
# ===========================================================================

module "platform" {
  source = "../../stacks/erp-platform"

  env      = "dev"
  workload = "erp"
  location = var.location

  owner_email = var.owner_email
  cost_centre = var.cost_centre

  # ------------------------------------------------------------- networking
  hub_cidr     = var.hub_cidr
  spoke_cidr   = var.spoke_cidr
  my_public_ip = var.my_public_ip

  # ---------------------------------------------------- security posture
  # Permissive on purpose. See the prod root module for the contrast.
  allow_public_platform_access = true
  key_vault_purge_protection   = false
  aks_private_cluster          = false
  aks_local_account_disabled   = false
  aks_sku_tier                 = "Free"

  # --------------------------------------------------------------- sizing
  kubernetes_version = var.kubernetes_version
  node_vm_size       = var.node_vm_size
  availability_zones = var.availability_zones
  system_node_min    = 1
  system_node_max    = 2
  user_node_min      = 1
  user_node_max      = 4
  acr_sku            = var.acr_sku
  log_daily_quota_gb = var.log_daily_quota_gb

  # ------------------------------------------------------------- database
  postgres_sku                    = var.postgres_sku
  postgres_backup_retention_days  = 7
  postgres_geo_redundant_backup   = false
  postgres_high_availability_mode = null # halves the cost; dev does not need HA
  postgres_password_auth_enabled  = true # needed for the bootstrap migration
  postgres_admin_password         = var.postgres_admin_password

  db_aad_admin_object_id      = var.db_aad_admin_object_id
  db_aad_admin_principal_name = var.db_aad_admin_principal_name
  db_aad_admin_principal_type = var.db_aad_admin_principal_type

  # ------------------------------------------------------------- identity
  aks_admin_group_object_ids     = var.aks_admin_group_object_ids
  ci_service_principal_object_id = var.ci_service_principal_object_id
  k8s_namespace                  = var.k8s_namespace
  group_role_assignments         = var.group_role_assignments

  # --------------------------------------------------- expensive opt-ins
  enable_appgw    = var.enable_appgw
  enable_firewall = var.enable_firewall
  enable_cosmos   = var.enable_cosmos
}
