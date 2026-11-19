variable "name" { type = string }
variable "rg_name" { type = string }
variable "location" { type = string }

variable "sku" {
  type    = string
  default = "Premium"
  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be Basic, Standard or Premium."
  }
}

# Dev defaults to public so you can docker push from a laptop without a VPN.
# Set to false for the prod exercise and pull through the private endpoint.
variable "public_network_access" {
  type    = bool
  default = true
}

variable "private_endpoint_subnet_id" {
  type    = string
  default = null
}

variable "acr_private_dns_zone_id" {
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

# Content trust requires you to sign images (docker trust / notation).
# Leave false while learning, flip to true for the supply-chain exercise.
variable "enable_content_trust" {
  type    = bool
  default = false
}
