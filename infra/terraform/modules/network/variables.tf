variable "rg_name" { type = string }
variable "location" { type = string }
variable "base_name" { type = string }
variable "hub_vnet_name" { type = string }
variable "spoke_vnet_name" { type = string }

variable "hub_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "spoke_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# --- flow logs (optional; off in dev to save cost) ---
variable "enable_flow_logs" {
  type    = bool
  default = false
}
variable "network_watcher_name" {
  type    = string
  default = "NetworkWatcher_centralindia"
}
variable "network_watcher_rg" {
  type    = string
  default = "NetworkWatcherRG"
}
variable "flow_log_storage_account_id" {
  type    = string
  default = null
}
variable "log_analytics_workspace_id" {
  type    = string
  default = null
}
variable "log_analytics_workspace_guid" {
  type    = string
  default = null
}
