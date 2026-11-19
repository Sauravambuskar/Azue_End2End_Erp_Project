variable "location" {
  description = "Azure region. centralindia keeps latency low for Hyderabad/Pune."
  type        = string
  default     = "centralindia"
}

variable "owner_email" {
  description = "Goes into the Owner tag and the alert action group."
  type        = string
}

variable "cost_centre" {
  type    = string
  default = "CC-LEARNING-001"
}

# --------------------------------------------------------------- networking
variable "hub_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "spoke_cidr" {
  description = "A different /16 from dev so both can peer to one hub."
  type        = string
  default     = "10.20.0.0/16"
}

variable "my_public_ip" {
  description = <<-DESC
    Your laptop's public IP. Used to restrict the AKS API server and Key Vault.
    Find it with:  curl -s https://api.ipify.org
    Leave null to allow all, which is not recommended even in a lab.
  DESC
  type        = string
  default     = null
}

# ---------------------------------------------------------------------- aks
variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "node_vm_size" {
  description = "Larger than dev: production carries real traffic."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "aks_admin_group_object_ids" {
  description = "Entra group object ids granted cluster-admin via Azure RBAC."
  type        = list(string)
  default     = []
}

variable "ci_service_principal_object_id" {
  description = "Object id of the Azure DevOps service connection's app registration."
  type        = string
  default     = null
}

variable "k8s_namespace" {
  type    = string
  default = "erp"
}

# ---------------------------------------------------------------------- acr
# ----------------------------------------------------------------- postgres
variable "postgres_sku" {
  description = "General Purpose, not Burstable. A burstable SKU under sustained load throttles unpredictably."
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "db_aad_admin_object_id" {
  description = "Object id of the DBA GROUP. Never an individual user in production."
  type        = string
  default     = null
}

variable "db_aad_admin_principal_name" {
  description = "Display name of the DBA group, e.g. grp-erp-dba."
  type        = string
  default     = null
}


# ------------------------------------------------------- expensive opt-ins
variable "enable_cosmos" {
  description = "Serverless Cosmos is nearly free when idle. Safe to leave on."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------- limits
variable "log_daily_quota_gb" {
  description = <<-DESC
    Hard cap on Log Analytics ingestion. Set generously in prod: hitting the
    cap means losing telemetry, and losing telemetry during an incident is
    worse than the ingestion cost.
  DESC
  type        = number
  default     = 10
}

# ---------------------------------------------------------------- human RBAC
variable "group_role_assignments" {
  type = map(object({
    object_id     = string
    role          = string
    scope         = string
    justification = string
  }))
  default = {}
}
