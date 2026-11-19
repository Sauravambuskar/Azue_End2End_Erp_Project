variable "enabled" {
  type    = bool
  default = false
}

variable "name" { type = string }
variable "rg_name" { type = string }
variable "location" { type = string }

variable "public_network_access" {
  type    = bool
  default = true
}

variable "disable_key_auth" {
  description = "true forces Entra ID data-plane auth only. Do this in the RBAC exercise."
  type        = bool
  default     = false
}

variable "api_principal_id" {
  type    = string
  default = null
}

variable "log_analytics_workspace_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
