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
    Bootstrap password, used only when postgres_password_auth_enabled is true.
    Do NOT put this in a committed .tfvars file. Supply it at apply time:
      export TF_VAR_postgres_admin_password=$(openssl rand -base64 24)
  DESC
  type        = string
  sensitive   = true
  default     = null
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

# ===========================================================================
# Stack identity
# ===========================================================================
variable "env" {
  description = "Environment name. Drives naming, tags and policy effects."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.env)
    error_message = "env must be one of: dev, test, prod."
  }
}

variable "workload" {
  type    = string
  default = "erp"
}

# ===========================================================================
# Security posture - THIS is the real difference between dev and prod.
# Defaults are the DEV (permissive, learnable) values. envs/prod overrides
# every one of them.
# ===========================================================================
variable "allow_public_platform_access" {
  description = <<-DESC
    true  (dev)  ACR and Key Vault keep a public endpoint, IP-restricted, so
                 you can docker push and read secrets from a laptop.
    false (prod) public access disabled; reachable only over private endpoints.
                 Requires acr_sku = "Premium".
  DESC
  type        = bool
  default     = true
}

variable "key_vault_purge_protection" {
  description = <<-DESC
    false (dev)  lets you destroy and recreate the lab, reusing the name.
    true  (prod) a deleted secret cannot be permanently destroyed inside the
                 retention window. Irreversible once enabled.
  DESC
  type        = bool
  default     = false
}

variable "aks_private_cluster" {
  description = "true removes the API server's public IP entirely. Note: a Microsoft-hosted pipeline agent then cannot reach it."
  type        = bool
  default     = false
}

variable "aks_local_account_disabled" {
  description = "true removes the static cluster-admin certificate, leaving Entra ID as the only way in."
  type        = bool
  default     = false
}

variable "aks_sku_tier" {
  description = "Free has no uptime SLA. Standard adds the SLA and cost analysis."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.aks_sku_tier)
    error_message = "aks_sku_tier must be Free, Standard or Premium."
  }
}

# ---------------------------------------------------------------- node pools
variable "system_node_min" {
  type    = number
  default = 1
}

variable "system_node_max" {
  type    = number
  default = 2
}

variable "user_node_min" {
  type    = number
  default = 1
}

variable "user_node_max" {
  type    = number
  default = 4
}

# ----------------------------------------------------------------- postgres
variable "postgres_backup_retention_days" {
  type    = number
  default = 7
}

variable "postgres_geo_redundant_backup" {
  description = "true survives a regional outage. Cannot be changed after creation."
  type        = bool
  default     = false
}

variable "postgres_high_availability_mode" {
  description = "ZoneRedundant or SameZone. null disables HA, which halves the cost."
  type        = string
  default     = null

  validation {
    condition     = var.postgres_high_availability_mode == null || contains(["ZoneRedundant", "SameZone"], coalesce(var.postgres_high_availability_mode, "null"))
    error_message = "postgres_high_availability_mode must be ZoneRedundant, SameZone, or null."
  }
}

variable "postgres_password_auth_enabled" {
  description = "false forces Entra ID as the only database authentication method."
  type        = bool
  default     = true
}
