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
  type    = string
  default = "10.10.0.0/16"
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
  description = "D2s_v5 = 2 vCPU / 8 GB. Smallest size that runs AKS add-ons comfortably."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "availability_zones" {
  description = "Set to [] if your region or subscription has no zone quota."
  type        = list(string)
  default     = ["1"]
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
variable "acr_sku" {
  description = "Basic is enough for dev; Premium is needed for private endpoints."
  type        = string
  default     = "Basic"
}

# ----------------------------------------------------------------- postgres
variable "postgres_sku" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "postgres_admin_password" {
  description = <<-DESC
    Bootstrap password. Do NOT put this in a committed .tfvars file.
    Supply it at apply time instead, for example:
      export TF_VAR_postgres_admin_password=$(openssl rand -base64 24)
    Or read it from the Key Vault secret this stack generates.
  DESC
  type        = string
  sensitive   = true
}

variable "db_aad_admin_object_id" {
  description = "Your own Entra user object id, so you can create DB principals."
  type        = string
  default     = null
}

variable "db_aad_admin_principal_name" {
  description = "Your UPN, for example you@yourtenant.onmicrosoft.com"
  type        = string
  default     = null
}

variable "db_aad_admin_principal_type" {
  type    = string
  default = "User"
}

# ------------------------------------------------------- expensive opt-ins
variable "enable_appgw" {
  description = "Application Gateway WAF v2 costs roughly USD 0.25/hour. Off by default."
  type        = bool
  default     = false
}

variable "enable_firewall" {
  description = "Azure Firewall is the priciest resource here. Off by default."
  type        = bool
  default     = false
}

variable "enable_cosmos" {
  description = "Serverless Cosmos is nearly free when idle. Safe to leave on."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------- limits
variable "log_daily_quota_gb" {
  description = "Hard cap on Log Analytics ingestion. Your main runaway-cost risk."
  type        = number
  default     = 1
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
