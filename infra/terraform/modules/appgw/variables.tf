variable "name" { type = string }
variable "rg_name" { type = string }
variable "location" { type = string }
variable "subnet_id" { type = string }

variable "dns_label" {
  description = "Gives you <label>.<region>.cloudapp.azure.com with no domain purchase."
  type        = string
  default     = null
}

variable "availability_zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 3
}

variable "waf_mode" {
  type    = string
  default = "Prevention"
  validation {
    condition     = contains(["Prevention", "Detection"], var.waf_mode)
    error_message = "waf_mode must be Prevention or Detection."
  }
}

variable "rate_limit_per_minute" {
  type    = number
  default = 1000
}

variable "geo_block_enabled" {
  type    = bool
  default = false
}

variable "allowed_countries" {
  type    = list(string)
  default = ["IN", "US", "GB", "AE", "SG"]
}

variable "log_analytics_workspace_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
