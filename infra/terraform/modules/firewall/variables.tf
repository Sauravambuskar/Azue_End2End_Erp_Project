variable "enabled" {
  description = "Azure Firewall is expensive. Keep false in dev except during the egress exercise."
  type        = bool
  default     = false
}

variable "name" { type = string }
variable "rg_name" { type = string }
variable "location" { type = string }
variable "env" { type = string }

variable "sku_tier" {
  type    = string
  default = "Basic"
  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Basic, Standard or Premium."
  }
}

variable "firewall_subnet_id" {
  type    = string
  default = null
}

variable "aks_subnet_ids" {
  type    = list(string)
  default = []
}

variable "spoke_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = []
}

variable "log_analytics_workspace_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
