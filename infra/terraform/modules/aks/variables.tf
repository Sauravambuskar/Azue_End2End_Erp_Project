variable "name" { type = string }
variable "rg_name" { type = string }
variable "location" { type = string }
variable "env" { type = string }
variable "node_resource_group" { type = string }
variable "tenant_id" { type = string }

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "sku_tier" {
  description = "Free has no SLA. Standard gives the uptime SLA and cost analysis."
  type        = string
  default     = "Free"
  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

# ------------------------------------------------------------- API server
variable "private_cluster" {
  type    = bool
  default = false
}

variable "local_account_disabled" {
  description = "true removes the cluster-admin kubeconfig. Entra ID only."
  type        = bool
  default     = false
}

variable "api_server_authorized_ip_ranges" {
  description = "Public cluster only: CIDRs allowed to reach the API server."
  type        = list(string)
  default     = []
}

# -------------------------------------------------------------- identity
variable "cluster_identity_id" { type = string }
variable "kubelet_identity_id" { type = string }
variable "kubelet_identity_client_id" { type = string }
variable "kubelet_identity_object_id" { type = string }

variable "admin_group_object_ids" {
  description = "Entra ID groups that get cluster-admin. Never individual users."
  type        = list(string)
  default     = []
}

variable "ci_principal_id" {
  type    = string
  default = null
}

# ------------------------------------------------------------ networking
variable "system_subnet_id" { type = string }
variable "user_subnet_id" { type = string }

variable "cni_overlay" {
  description = "Azure CNI Overlay conserves VNet IPs; pods get a private CIDR."
  type        = bool
  default     = true
}

variable "network_policy" {
  type    = string
  default = "calico"
  validation {
    condition     = contains(["calico", "azure", "cilium"], var.network_policy)
    error_message = "network_policy must be calico, azure or cilium."
  }
}

variable "service_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "172.16.0.10"
}

variable "pod_cidr" {
  type    = string
  default = "172.17.0.0/16"
}

variable "outbound_type" {
  description = "userDefinedRouting forces egress through Azure Firewall."
  type        = string
  default     = "loadBalancer"
  validation {
    condition = contains(
      ["loadBalancer", "userDefinedRouting", "managedNATGateway", "userAssignedNATGateway"],
      var.outbound_type
    )
    error_message = "Invalid outbound_type."
  }
}

# ------------------------------------------------------------ node pools
variable "availability_zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "system_node_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}
variable "system_node_min" {
  type    = number
  default = 1
}

variable "system_node_max" {
  type    = number
  default = 3
}

variable "system_os_disk_gb" {
  description = "Must be >= the VM's cache size for Ephemeral OS disks."
  type        = number
  default     = 64
}

variable "user_node_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "user_node_min" {
  type    = number
  default = 1
}

variable "user_node_max" {
  type    = number
  default = 5
}

variable "user_os_disk_gb" {
  type    = number
  default = 64
}

# --------------------------------------------------------------- add-ons
variable "log_analytics_workspace_id" { type = string }

variable "appgw_id" {
  description = "Set to enable AGIC (Application Gateway Ingress Controller)."
  type        = string
  default     = null
}

variable "automatic_upgrade_channel" {
  type    = string
  default = "patch"
  validation {
    condition     = contains(["none", "patch", "rapid", "stable", "node-image"], var.automatic_upgrade_channel)
    error_message = "Invalid automatic_upgrade_channel."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "host_encryption_enabled" {
  description = <<-DESC
    Encryption-at-host for node temp disks and disk caches, on top of the
    platform-managed disk encryption. It is free, but it requires a one-off
    subscription feature registration:

      az feature register --namespace Microsoft.Compute --name EncryptionAtHost
      az provider register --namespace Microsoft.Compute

    Leave this false until the feature shows "Registered", or node pool
    creation fails with a feature-not-enabled error.
  DESC
  type        = bool
  default     = false
}
