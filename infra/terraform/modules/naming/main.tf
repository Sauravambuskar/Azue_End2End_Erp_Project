# ---------------------------------------------------------------------------
# Naming + tagging standard (CAF aligned).
#
# Pattern: <type>-<workload>-<env>-<region-short>[-<instance>]
# Example: aks-erp-dev-cin-01
#
# Why a module: the JD asks for "resource groups and tagging standards".
# Centralising this means a policy can *enforce* what this module *produces*.
# ---------------------------------------------------------------------------
locals {
  region_short = {
    centralindia  = "cin"
    southindia    = "sin"
    westindia     = "win"
    eastus        = "eus"
    westeurope    = "weu"
    southeastasia = "sea"
  }
  loc = lookup(local.region_short, var.location, substr(replace(var.location, " ", ""), 0, 3))

  base = "${var.workload}-${var.env}-${local.loc}"

  # Globally unique, alphanumeric-only names (ACR, storage, Key Vault).
  unique_suffix = substr(sha1("${var.subscription_id}-${var.workload}-${var.env}"), 0, 6)
}

output "names" {
  description = "Canonical resource names for this workload/environment."
  value = {
    rg_platform = "rg-${local.base}-platform"
    rg_network  = "rg-${local.base}-network"
    rg_data     = "rg-${local.base}-data"
    rg_aks      = "rg-${local.base}-aks"
    rg_shared   = "rg-${local.base}-shared"

    vnet_hub    = "vnet-hub-${var.env}-${local.loc}"
    vnet_spoke  = "vnet-spoke-${local.base}"
    firewall    = "afw-hub-${var.env}-${local.loc}"
    appgw       = "agw-${local.base}"
    nat_gateway = "ng-${local.base}"

    aks         = "aks-${local.base}-01"
    aks_node_rg = "rg-${local.base}-aks-nodes"
    acr         = "acr${replace(var.workload, "-", "")}${var.env}${local.unique_suffix}"
    key_vault   = "kv-${substr(var.workload, 0, 6)}-${var.env}-${local.unique_suffix}"
    postgres    = "psql-${local.base}-01"
    cosmos      = "cosmos-${local.base}-01"
    servicebus  = "sb-${local.base}"
    storage     = "st${replace(var.workload, "-", "")}${var.env}${local.unique_suffix}"

    log_analytics = "log-${local.base}"
    app_insights  = "appi-${local.base}"
    action_group  = "ag-${local.base}-oncall"
    dashboard     = "dash-${local.base}-platform"

    mi_api         = "id-${var.workload}-api-${var.env}"
    mi_worker      = "id-${var.workload}-worker-${var.env}"
    mi_web         = "id-${var.workload}-web-${var.env}"
    mi_migrate     = "id-${var.workload}-migrate-${var.env}"
    mi_aks_kubelet = "id-${var.workload}-kubelet-${var.env}"
  }
}

output "tags" {
  description = "Mandatory tags. Azure Policy denies resources missing these."
  value = merge(
    {
      Workload     = var.workload
      Environment  = var.env
      CostCentre   = var.cost_centre
      Owner        = var.owner
      DataClass    = var.data_classification
      ManagedBy    = "terraform"
      Repo         = var.repo_url
      BusinessUnit = var.business_unit
      ReviewDate   = var.review_date
    },
    var.extra_tags
  )
}

output "location_short" { value = local.loc }
output "base_name" { value = local.base }
