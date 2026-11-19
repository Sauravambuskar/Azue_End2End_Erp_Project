variable "name" { type = string }
variable "rg_name" { type = string }
variable "location" { type = string }
variable "tenant_id" { type = string }

variable "pg_version" {
  type    = string
  default = "16"
}

# B1ms / B2s are burstable and cheap - right for a learning lab.
variable "sku_name" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "storage_mb" {
  type    = number
  default = 32768
}

variable "storage_tier" {
  type    = string
  default = "P4"
}

variable "database_name" {
  type    = string
  default = "erp"
}

variable "delegated_subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }

variable "zone" {
  type    = string
  default = "1"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "geo_redundant_backup" {
  type    = bool
  default = false
}

variable "high_availability_mode" {
  description = "ZoneRedundant or SameZone. null disables HA (dev)."
  type        = string
  default     = null
}

variable "standby_zone" {
  type    = string
  default = "2"
}

# --- authentication ---
variable "password_auth_enabled" {
  type    = bool
  default = true
}

variable "admin_username" {
  type    = string
  default = "erpadmin"
}

variable "admin_password" {
  description = "Only used when password_auth_enabled. Comes from Key Vault, never a tfvars file."
  type        = string
  default     = null
  sensitive   = true
}

variable "aad_admin_object_id" {
  description = "Entra object id of the group/user that administers the DB."
  type        = string
  default     = null
}

variable "aad_admin_principal_name" {
  type    = string
  default = null
}

variable "aad_admin_principal_type" {
  type    = string
  default = "Group"
}

variable "log_analytics_workspace_id" {
  type    = string
  default = null
}

variable "action_group_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
