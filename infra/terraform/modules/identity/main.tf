# ---------------------------------------------------------------------------
# Workload identities for the ERP platform.
#
# THIS IS THE MOST IMPORTANT MODULE TO UNDERSTAND FOR THE INTERVIEW.
#
# The chain, end to end:
#
#   Kubernetes ServiceAccount  (erp/erp-api-sa)
#        |  annotated with the client id of ...
#        v
#   User-assigned managed identity  (id-erp-api-dev)
#        |  trusts tokens from the AKS OIDC issuer for that exact
#        |  namespace+serviceaccount pair via a ...
#        v
#   Federated identity credential
#        |  so the pod's projected SA token is exchanged for an
#        v
#   Entra ID access token  ->  used against Key Vault / ACR / PostgreSQL
#
# Result: no client secret, no connection string, nothing to rotate, nothing
# to leak. Each workload gets its OWN identity, so blast radius is per-pod.
# ---------------------------------------------------------------------------

locals {
  # One identity per workload, each with the roles it genuinely needs.
  workloads = {
    api = {
      name            = var.mi_names.api
      service_account = "erp-api-sa"
      pg_role         = "erp_app"
    }
    worker = {
      name            = var.mi_names.worker
      service_account = "erp-worker-sa"
      pg_role         = "erp_app"
    }
    web = {
      name            = var.mi_names.web
      service_account = "erp-web-sa"
      pg_role         = null
    }
    migrate = {
      name            = var.mi_names.migrate
      service_account = "erp-migrate-sa"
      pg_role         = "erp_migrator"
    }
  }
}

resource "azurerm_user_assigned_identity" "workload" {
  for_each = local.workloads

  name                = each.value.name
  resource_group_name = var.rg_name
  location            = var.location
  tags                = merge(var.tags, { WorkloadComponent = each.key })
}

# ------------------------------------------------- federated identity creds
# The subject MUST match exactly: system:serviceaccount:<namespace>:<sa-name>
resource "azurerm_federated_identity_credential" "workload" {
  for_each = local.workloads

  name                = "fic-${each.key}-${var.namespace}"
  resource_group_name = var.rg_name
  parent_id           = azurerm_user_assigned_identity.workload[each.key].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.aks_oidc_issuer_url
  subject             = "system:serviceaccount:${var.namespace}:${each.value.service_account}"
}

# ------------------------------------------------------------- Key Vault RBAC
# Secrets User, not Secrets Officer: the app reads, it never writes.
resource "azurerm_role_assignment" "kv_secrets_user" {
  for_each = var.key_vault_id == null ? {} : local.workloads

  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload[each.key].principal_id
}

# -------------------------------------------------------------------- ACR RBAC
# AcrPull only. Pushing is done by the pipeline's service connection, not by
# anything running in the cluster.
resource "azurerm_role_assignment" "acr_pull" {
  for_each = var.acr_id == null ? {} : local.workloads

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.workload[each.key].principal_id
}

# ------------------------------------------------------- App Insights / metrics
resource "azurerm_role_assignment" "monitoring_publisher" {
  for_each = var.app_insights_id == null ? {} : local.workloads

  scope                = var.app_insights_id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.workload[each.key].principal_id
}

# ------------------------------------------------------------- Service Bus
resource "azurerm_role_assignment" "sb_sender" {
  count = var.servicebus_namespace_id == null ? 0 : 1

  scope                = var.servicebus_namespace_id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_user_assigned_identity.workload["worker"].principal_id
}

# ---------------------------------------------------------------------------
# Human / group RBAC on the platform resource groups.
#
# Model used by this project (least privilege, group-based, never per-user):
#
#   grp-erp-platform-admins   -> Contributor on the platform RGs
#   grp-erp-developers        -> Reader + AKS RBAC Writer in the erp namespace
#   grp-erp-sre              -> AKS RBAC Admin + Monitoring Contributor
#   grp-erp-security         -> Security Reader + Key Vault Reader
#
# You pass the object ids in; they are created once in Entra ID by hand (or by
# the entra-groups.ps1 script in scripts/).
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "group_assignments" {
  for_each = var.group_role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = each.value.object_id
  principal_type       = "Group"

  description = each.value.justification
}
