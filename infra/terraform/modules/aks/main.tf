# ---------------------------------------------------------------------------
# Secure AKS platform.
#
# Every setting below is a deliberate security or operability choice. Be ready
# to justify each one - this is the single most-likely deep-dive area in the
# interview.
#
#   private_cluster_enabled      API server has no public IP (prod)
#   local_account_disabled       no cluster-admin certs; Entra ID only
#   azure_rbac_enabled           Kubernetes RBAC driven by Entra groups
#   oidc_issuer + workload_id    pods get Entra tokens, zero secrets
#   azure_policy_enabled         Gatekeeper admission control
#   network_plugin = azure       real VNet IPs, NSG/UDR apply to pods
#   network_policy = calico      pod-to-pod firewalling (NetworkPolicy)
#   outbound_type = userDefinedRouting   all egress via Azure Firewall
#   key_vault_secrets_provider   CSI driver with secret rotation
#   defender                     runtime threat detection
#   auto_upgrade + maintenance   patching without surprise reboots
#   system/user node pool split  platform add-ons isolated from workloads
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "this" {
  # checkov:skip=CKV_AZURE_227:Host encryption is controlled by var.host_encryption_enabled. It is false by DEFAULT because it needs a one-off subscription feature registration (Microsoft.Compute/EncryptionAtHost) and node pool creation fails outright if that is missing - a worse failure than the finding. Register the feature, then set it true.
  # Checkov inline suppressions MUST be inside the resource block,
  # not above it. Each names the variable or control that makes the
  # finding acceptable, so a reviewer can verify it.
  # checkov:skip=CKV_AZURE_115:Controlled by var.private_cluster. envs/prod sets true; dev keeps a public, IP-restricted API server so a learner cannot lock themselves out of their own cluster.
  # checkov:skip=CKV_AZURE_141:Controlled by var.local_account_disabled. envs/prod sets true, making Entra ID the only way in.
  # checkov:skip=CKV_AZURE_170:Controlled by var.sku_tier. envs/prod uses Standard for the uptime SLA; dev uses Free, which has no SLA and no cost.
  # checkov:skip=CKV_AZURE_117:No customer-managed disk encryption set. Node disks are platform-encrypted and host encryption is available via var.host_encryption_enabled. CMK on node disks adds key-rotation operations for no threat-model gain here: the nodes are stateless and all persistent state lives in PostgreSQL.
  name                       = var.name
  resource_group_name        = var.rg_name
  location                   = var.location
  node_resource_group        = var.node_resource_group
  dns_prefix                 = var.private_cluster ? null : var.name
  dns_prefix_private_cluster = var.private_cluster ? var.name : null
  kubernetes_version         = var.kubernetes_version
  sku_tier                   = var.sku_tier
  tags                       = var.tags

  # ---------------------------------------------------------- API server
  private_cluster_enabled             = var.private_cluster
  private_cluster_public_fqdn_enabled = false
  local_account_disabled              = var.local_account_disabled

  dynamic "api_server_access_profile" {
    for_each = var.private_cluster ? [] : [1]
    content {
      # Public cluster (dev): still restrict who can reach the API server.
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  # ------------------------------------------------- identity + Entra RBAC
  identity {
    type         = "UserAssigned"
    identity_ids = [var.cluster_identity_id]
  }

  kubelet_identity {
    client_id                 = var.kubelet_identity_client_id
    object_id                 = var.kubelet_identity_object_id
    user_assigned_identity_id = var.kubelet_identity_id
  }

  azure_active_directory_role_based_access_control {
    tenant_id              = var.tenant_id
    admin_group_object_ids = var.admin_group_object_ids
    azure_rbac_enabled     = true
  }

  # ------------------------------------------------------ workload identity
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # ------------------------------------------------------------- networking
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = var.cni_overlay ? "overlay" : null
    network_policy      = var.network_policy
    dns_service_ip      = var.dns_service_ip
    service_cidr        = var.service_cidr
    pod_cidr            = var.cni_overlay ? var.pod_cidr : null
    outbound_type       = var.outbound_type
    load_balancer_sku   = "standard"
  }

  # --------------------------------------------------- system node pool
  # Tainted CriticalAddonsOnly so only platform components land here.
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    vnet_subnet_id               = var.system_subnet_id
    zones                        = var.availability_zones
    auto_scaling_enabled         = true
    min_count                    = var.system_node_min
    max_count                    = var.system_node_max
    only_critical_addons_enabled = true
    os_disk_type                 = "Ephemeral"
    os_disk_size_gb              = var.system_os_disk_gb
    os_sku                       = "AzureLinux"
    max_pods                     = 50
    orchestrator_version         = var.kubernetes_version

    # Encryption-at-host: encrypts the node's temp disk and the OS/data disk
    # caches at the hypervisor, on top of platform disk encryption. Free, but
    # requires a one-off subscription feature registration - see the variable.
    host_encryption_enabled = var.host_encryption_enabled

    upgrade_settings {
      max_surge = "33%"
    }

    node_labels = {
      "nodepool-type" = "system"
      "environment"   = var.env
    }

    tags = var.tags
  }

  # --------------------------------------------------------------- add-ons
  azure_policy_enabled = true

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  monitor_metrics {
    annotations_allowed = null
    labels_allowed      = null
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  microsoft_defender {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  dynamic "ingress_application_gateway" {
    for_each = var.appgw_id == null ? [] : [1]
    content {
      gateway_id = var.appgw_id
    }
  }

  # ------------------------------------------------- upgrades + maintenance
  automatic_upgrade_channel = var.automatic_upgrade_channel
  node_os_upgrade_channel   = "NodeImage"

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+05:30"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Saturday"
    start_time  = "02:00"
    utc_offset  = "+05:30"
  }

  auto_scaler_profile {
    balance_similar_node_groups      = true
    expander                         = "least-waste"
    scale_down_unneeded              = "5m"
    scale_down_utilization_threshold = "0.5"
    skip_nodes_with_local_storage    = false
    skip_nodes_with_system_pods      = true
  }

  storage_profile {
    disk_driver_enabled = true
    file_driver_enabled = true
    # Blob CSI is off: this workload has no blob mounts. Fewer drivers,
    # smaller attack surface.
    blob_driver_enabled = false
  }

  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48
  cost_analysis_enabled        = var.sku_tier == "Standard"
  run_command_enabled          = var.env != "prod"

  lifecycle {
    ignore_changes = [
      # The autoscaler owns the node count after creation.
      default_node_pool[0].node_count,
      # Avoid fighting the auto-upgrade channel on every plan.
      kubernetes_version,
    ]
  }
}

# --------------------------------------------------------- user node pool
# Application workloads only. Separate pool means you can drain, upgrade or
# resize app capacity without touching CoreDNS, the metrics server, etc.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  # checkov:skip=CKV_AZURE_227:See the note on the cluster resource: controlled by var.host_encryption_enabled, which requires a subscription feature registration first.
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.user_node_vm_size
  vnet_subnet_id        = var.user_subnet_id
  zones                 = var.availability_zones
  auto_scaling_enabled  = true
  min_count             = var.user_node_min
  max_count             = var.user_node_max
  os_disk_type          = "Ephemeral"
  os_disk_size_gb       = var.user_os_disk_gb
  os_sku                = "AzureLinux"
  max_pods              = 50
  mode                  = "User"
  orchestrator_version  = var.kubernetes_version

  # Encryption-at-host: encrypts the node's temp disk and the OS/data disk
  # caches at the hypervisor, on top of platform disk encryption. Free, but
  # requires a one-off subscription feature registration - see the variable.
  host_encryption_enabled = var.host_encryption_enabled
  tags                    = var.tags

  node_labels = {
    "nodepool-type" = "user"
    "workload"      = "erp"
    "environment"   = var.env
  }

  upgrade_settings {
    max_surge = "33%"
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}

# ---------------------------------------------------- diagnostic settings
# Control-plane logs. kube-audit is where you prove "who deleted that
# deployment" - the single most useful table during an incident.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "diag-to-law"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "kube-apiserver" }
  enabled_log { category = "kube-controller-manager" }
  enabled_log { category = "kube-scheduler" }
  enabled_log { category = "cluster-autoscaler" }
  enabled_log { category = "guard" } # Entra ID authn/authz decisions

  # kube-audit-admin is the write-only subset: same forensic value as
  # kube-audit at a fraction of the ingestion cost.
  enabled_log { category = "kube-audit-admin" }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ------------------------------------------------------ cluster RBAC for CI
# The pipeline's service connection needs to deploy, not to own the cluster.
resource "azurerm_role_assignment" "ci_rbac_writer" {
  count = var.ci_principal_id == null ? 0 : 1

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = var.ci_principal_id
  description          = "Azure DevOps pipeline deploys manifests; cannot change cluster config."
}

resource "azurerm_role_assignment" "ci_cluster_user" {
  count = var.ci_principal_id == null ? 0 : 1

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = var.ci_principal_id
  description          = "Allows az aks get-credentials for the pipeline."
}
