variable "rg_name" { type = string }
variable "location" { type = string }

variable "namespace" {
  description = "Kubernetes namespace the workloads run in."
  type        = string
  default     = "erp"
}

variable "mi_names" {
  description = "Managed identity names from the naming module."
  type = object({
    api     = string
    worker  = string
    web     = string
    migrate = string
  })
}

variable "aks_oidc_issuer_url" {
  description = "AKS OIDC issuer URL - output of the aks module."
  type        = string
}

variable "key_vault_id" {
  type    = string
  default = null
}

variable "acr_id" {
  type    = string
  default = null
}

variable "app_insights_id" {
  type    = string
  default = null
}

variable "servicebus_namespace_id" {
  type    = string
  default = null
}

variable "group_role_assignments" {
  description = <<-DESC
    Human access, always via Entra ID groups. Example:
      {
        platform_admins = {
          object_id     = "00000000-0000-0000-0000-000000000000"
          role          = "Contributor"
          scope         = "/subscriptions/.../resourceGroups/rg-erp-dev-cin-platform"
          justification = "Platform team owns the landing zone"
        }
      }
  DESC
  type = map(object({
    object_id     = string
    role          = string
    scope         = string
    justification = string
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
