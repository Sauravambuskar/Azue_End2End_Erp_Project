# ===========================================================================
# ContosoERP platform STACK.
#
# This is the whole platform as one composable unit. It is NOT a root module -
# it has no backend and no provider block. The thin root modules under
# envs/<env>/ call it with environment-specific values.
#
# WHY THIS LAYER EXISTS
# The naive approach is a full root module per environment, which means
# envs/dev/main.tf and envs/prod/main.tf are 400 near-identical lines. They
# then drift: somebody fixes something in dev and forgets prod, and the
# environment you actually care about is the one running the older code.
# With this layer, dev and prod are provably the same architecture and differ
# only in the values they pass in - which is exactly what you want to be able
# to say about a production environment.
#
# Apply order is handled by Terraform's dependency graph, but the logical
# story is:
#
#   1. naming      -> every name and tag, derived once
#   2. network     -> hub + spoke, NSGs, private DNS
#   3. monitor     -> Log Analytics first, so everything can log into it
#   4. acr / kv    -> platform services
#   5. aks         -> needs subnets + LAW + its own identities
#   6. identity    -> needs the AKS OIDC issuer URL for federation
#   7. postgres    -> needs the delegated subnet + private DNS zone
#   8. appgw       -> optional public entry point
#   9. firewall    -> optional egress lockdown (costs money, off by default)
#
# IMPORTANT: run `terraform apply` twice the first time. The identity module
# federates against the AKS OIDC issuer, which does not exist until AKS is
# created. This is expected and is explained in guidance/05.
# ===========================================================================

locals {
  env      = var.env
  workload = var.workload
}

data "azurerm_client_config" "current" {}

# ------------------------------------------------------------------ 1. naming
module "naming" {
  source = "../../modules/naming"

  workload            = local.workload
  env                 = local.env
  location            = var.location
  subscription_id     = data.azurerm_client_config.current.subscription_id
  owner               = var.owner_email
  cost_centre         = var.cost_centre
  data_classification = "internal"
}

# ---------------------------------------------------- resource groups (flat)
resource "azurerm_resource_group" "platform" {
  name     = module.naming.names.rg_platform
  location = var.location
  tags     = module.naming.tags
}

resource "azurerm_resource_group" "data" {
  name     = module.naming.names.rg_data
  location = var.location
  tags     = module.naming.tags
}

resource "azurerm_resource_group" "aks" {
  name     = module.naming.names.rg_aks
  location = var.location
  tags     = module.naming.tags
}

# ----------------------------------------------------------------- 2. network
module "network" {
  source = "../../modules/network"

  rg_name         = module.naming.names.rg_network
  location        = var.location
  base_name       = module.naming.base_name
  hub_vnet_name   = module.naming.names.vnet_hub
  spoke_vnet_name = module.naming.names.vnet_spoke
  hub_cidr        = var.hub_cidr
  spoke_cidr      = var.spoke_cidr
  tags            = module.naming.tags
}

# ----------------------------------------------------------------- 3. monitor
module "monitor" {
  source = "../../modules/monitor"

  rg_name           = azurerm_resource_group.platform.name
  location          = var.location
  base_name         = module.naming.base_name
  law_name          = module.naming.names.log_analytics
  appi_name         = module.naming.names.app_insights
  action_group_name = module.naming.names.action_group
  dashboard_name    = module.naming.names.dashboard

  retention_days = 30
  daily_quota_gb = var.log_daily_quota_gb
  oncall_emails  = [var.owner_email]

  tags = module.naming.tags
}

# --------------------------------------------------------------------- 4. acr
module "acr" {
  source = "../../modules/acr"

  name     = module.naming.names.acr
  rg_name  = azurerm_resource_group.platform.name
  location = var.location
  sku      = var.acr_sku

  # Dev keeps ACR public so you can `docker push` from a laptop with no VPN.
  # Prod sets this false and pulls through the private endpoint (needs Premium).
  public_network_access      = var.allow_public_platform_access
  log_analytics_workspace_id = module.monitor.law_id

  tags = module.naming.tags
}

# --------------------------------------------------------------- 4b. keyvault
module "keyvault" {
  source = "../../modules/keyvault"

  name     = module.naming.names.key_vault
  rg_name  = azurerm_resource_group.platform.name
  location = var.location

  purge_protection      = false # dev only: lets you destroy and recreate
  public_network_access = true
  allowed_ip_rules      = var.my_public_ip == null ? [] : ["${var.my_public_ip}/32"]

  generated_secrets = {
    "erp-db-admin-password" = { length = 32, special = true }
    "erp-api-signing-key"   = { length = 48, special = false }
  }

  log_analytics_workspace_id = module.monitor.law_id
  tags                       = module.naming.tags
}

# ---------------------------------------------- 5. identities used BY the AKS
# The cluster's own identity and its kubelet identity exist before the cluster.
resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = "id-aks-${module.naming.base_name}"
  resource_group_name = azurerm_resource_group.aks.name
  location            = var.location
  tags                = module.naming.tags
}

resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = module.naming.names.mi_aks_kubelet
  resource_group_name = azurerm_resource_group.aks.name
  location            = var.location
  tags                = module.naming.tags
}

# The control-plane identity must be able to manage the node subnets
# (attach NICs, update route tables) and to assign the kubelet identity.
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = module.network.spoke_vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
  description          = "AKS attaches node NICs into the spoke subnets."
}

resource "azurerm_role_assignment" "aks_kubelet_operator" {
  scope                = azurerm_user_assigned_identity.aks_kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
  description          = "Required so the control plane can assign the kubelet identity to nodes."
}

resource "azurerm_role_assignment" "aks_private_dns" {
  for_each = module.network.private_dns_zone_ids

  scope                = each.value
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
  description          = "Lets AKS register private endpoints it creates."
}

# ---------------------------------------------------------------------- 6. aks
module "aks" {
  source = "../../modules/aks"

  name                = module.naming.names.aks
  rg_name             = azurerm_resource_group.aks.name
  location            = var.location
  env                 = local.env
  node_resource_group = module.naming.names.aks_node_rg
  tenant_id           = data.azurerm_client_config.current.tenant_id
  kubernetes_version  = var.kubernetes_version

  # Dev: public API server but IP-restricted, local accounts left on so you
  # cannot lock yourself out while learning.
  # Prod: private cluster, local accounts disabled - Entra ID is the only way in.
  private_cluster                 = var.aks_private_cluster
  local_account_disabled          = var.aks_local_account_disabled
  api_server_authorized_ip_ranges = var.my_public_ip == null ? [] : ["${var.my_public_ip}/32"]

  cluster_identity_id        = azurerm_user_assigned_identity.aks_control_plane.id
  kubelet_identity_id        = azurerm_user_assigned_identity.aks_kubelet.id
  kubelet_identity_client_id = azurerm_user_assigned_identity.aks_kubelet.client_id
  kubelet_identity_object_id = azurerm_user_assigned_identity.aks_kubelet.principal_id
  admin_group_object_ids     = var.aks_admin_group_object_ids

  system_subnet_id = module.network.subnet_ids.aks_system
  user_subnet_id   = module.network.subnet_ids.aks_user
  cni_overlay      = true
  network_policy   = "calico"
  outbound_type    = var.enable_firewall ? "userDefinedRouting" : "loadBalancer"

  sku_tier            = var.aks_sku_tier
  availability_zones  = var.availability_zones
  system_node_vm_size = var.node_vm_size
  system_node_min     = var.system_node_min
  system_node_max     = var.system_node_max
  user_node_vm_size   = var.node_vm_size
  user_node_min       = var.user_node_min
  user_node_max       = var.user_node_max

  log_analytics_workspace_id = module.monitor.law_id
  ci_principal_id            = var.ci_service_principal_object_id

  tags = module.naming.tags

  depends_on = [
    azurerm_role_assignment.aks_network_contributor,
    azurerm_role_assignment.aks_kubelet_operator,
  ]
}

# ACR pull for the kubelet identity - this is what lets nodes pull images
# without an imagePullSecret.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = module.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
}

# ------------------------------------------------------- 7. workload identity
module "identity" {
  source = "../../modules/identity"

  rg_name   = azurerm_resource_group.platform.name
  location  = var.location
  namespace = var.k8s_namespace

  mi_names = {
    api     = module.naming.names.mi_api
    worker  = module.naming.names.mi_worker
    web     = module.naming.names.mi_web
    migrate = module.naming.names.mi_migrate
  }

  aks_oidc_issuer_url = module.aks.oidc_issuer_url

  key_vault_id    = module.keyvault.id
  acr_id          = module.acr.id
  app_insights_id = module.monitor.appi_id

  group_role_assignments = var.group_role_assignments

  tags = module.naming.tags
}

# ----------------------------------------------------------------- 8. postgres
module "postgres" {
  source = "../../modules/postgres"

  name      = module.naming.names.postgres
  rg_name   = azurerm_resource_group.data.name
  location  = var.location
  tenant_id = data.azurerm_client_config.current.tenant_id

  pg_version    = "16"
  sku_name      = var.postgres_sku
  storage_mb    = 32768
  database_name = "erp"

  delegated_subnet_id = module.network.subnet_ids.postgres
  private_dns_zone_id = module.network.private_dns_zone_ids.postgres

  backup_retention_days  = var.postgres_backup_retention_days
  geo_redundant_backup   = var.postgres_geo_redundant_backup
  high_availability_mode = var.postgres_high_availability_mode

  # Password auth stays enabled in dev for the bootstrap migration. Prod sets
  # this false so Entra ID is the only way to authenticate.
  password_auth_enabled = var.postgres_password_auth_enabled
  admin_username        = "erpadmin"
  admin_password        = var.postgres_password_auth_enabled ? var.postgres_admin_password : null

  # Make yourself the Entra admin so you can create PG principals for the
  # managed identities (see scripts/db-grant-identities.sh).
  aad_admin_object_id      = var.db_aad_admin_object_id
  aad_admin_principal_name = var.db_aad_admin_principal_name
  aad_admin_principal_type = var.db_aad_admin_principal_type

  log_analytics_workspace_id = module.monitor.law_id
  action_group_id            = module.monitor.action_group_id

  tags = module.naming.tags
}

# ------------------------------------------------------------------- 9. appgw
module "appgw" {
  source = "../../modules/appgw"
  count  = var.enable_appgw ? 1 : 0

  name      = module.naming.names.appgw
  rg_name   = azurerm_resource_group.platform.name
  location  = var.location
  subnet_id = module.network.subnet_ids.appgw
  dns_label = "${local.workload}-${local.env}-${module.naming.location_short}"

  availability_zones = var.availability_zones
  waf_mode           = "Prevention"
  min_capacity       = 1
  max_capacity       = 2

  log_analytics_workspace_id = module.monitor.law_id
  tags                       = module.naming.tags
}

# ---------------------------------------------------------------- 10. firewall
module "firewall" {
  source = "../../modules/firewall"

  enabled  = var.enable_firewall
  name     = module.naming.names.firewall
  rg_name  = module.network.rg_name
  location = var.location
  env      = local.env
  sku_tier = "Basic"

  firewall_subnet_id = module.network.subnet_ids.firewall
  aks_subnet_ids = [
    module.network.subnet_ids.aks_system,
    module.network.subnet_ids.aks_user,
  ]
  spoke_cidr = var.spoke_cidr

  log_analytics_workspace_id = module.monitor.law_id
  tags                       = module.naming.tags
}

# ------------------------------------------------------------------ 11. cosmos
module "cosmos" {
  source = "../../modules/cosmos"

  enabled  = var.enable_cosmos
  name     = module.naming.names.cosmos
  rg_name  = azurerm_resource_group.data.name
  location = var.location

  api_principal_id           = module.identity.principal_ids.api
  log_analytics_workspace_id = module.monitor.law_id
  tags                       = module.naming.tags
}
