variable "rg_name" { type = string }
variable "location" { type = string }
variable "base_name" { type = string }

variable "law_name" { type = string }
variable "appi_name" { type = string }
variable "action_group_name" { type = string }
variable "dashboard_name" { type = string }

variable "retention_days" {
  type    = number
  default = 30
}

# Hard cost guard. 1 GB/day is plenty for this lab; -1 means unlimited.
variable "daily_quota_gb" {
  type    = number
  default = 1
}

variable "sampling_percentage" {
  type    = number
  default = 100
}

variable "oncall_emails" {
  type    = list(string)
  default = []
}

variable "webhook_url" {
  type      = string
  default   = null
  sensitive = true
}

variable "failed_request_threshold" {
  type    = number
  default = 10
}

variable "latency_threshold_ms" {
  type    = number
  default = 1500
}

variable "tags" {
  type    = map(string)
  default = {}
}
