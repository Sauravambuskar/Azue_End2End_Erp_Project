variable "name" { type = string }
variable "rg_name" { type = string }
variable "location" { type = string }

variable "sku" {
  type    = string
  default = "standard"
}

variable "purge_protection" {
  type    = bool
  default = true
}

variable "soft_delete_retention_days" {
  type    = number
  default = 7
}

variable "public_network_access" {
  type    = bool
  default = true
}

variable "allowed_ip_rules" {
  description = "Your laptop's public IP while learning. Empty in prod."
  type        = list(string)
  default     = []
}

variable "generated_secrets" {
  description = "Secrets Terraform generates so no human ever sees them."
  type = map(object({
    length  = number
    special = bool
  }))
  default = {}
}

variable "private_endpoint_subnet_id" {
  type    = string
  default = null
}

variable "keyvault_private_dns_zone_id" {
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
