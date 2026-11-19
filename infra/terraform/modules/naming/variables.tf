variable "workload" {
  description = "Short workload name, e.g. erp."
  type        = string
}

variable "env" {
  description = "Environment: dev, test or prod."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.env)
    error_message = "env must be one of: dev, test, prod."
  }
}

variable "location" {
  description = "Azure region, e.g. centralindia."
  type        = string
}

variable "subscription_id" {
  description = "Used only to derive a stable unique suffix for global names."
  type        = string
}

variable "cost_centre" {
  type    = string
  default = "CC-PLATFORM-001"
}

variable "owner" {
  type    = string
  default = "platform-engineering@contoso.com"
}

variable "data_classification" {
  type    = string
  default = "internal"

  validation {
    condition = contains(
      ["public", "internal", "confidential", "restricted"],
      var.data_classification
    )
    error_message = "data_classification must be public, internal, confidential or restricted."
  }
}

variable "business_unit" {
  type    = string
  default = "manufacturing"
}

variable "repo_url" {
  type    = string
  default = "https://dev.azure.com/contoso/erp/_git/erp-platform"
}

variable "review_date" {
  description = "Date the resource ownership must be re-confirmed (governance)."
  type        = string
  default     = "2027-01-01"
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}
