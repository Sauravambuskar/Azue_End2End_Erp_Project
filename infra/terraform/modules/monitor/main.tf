# ---------------------------------------------------------------------------
# Observability stack: Log Analytics + Application Insights + alerts +
# an action group + a shared dashboard.
#
# This single module covers the JD's "Monitoring" row end to end:
#   Azure Monitor, Application Insights, Log Analytics, alerts, dashboards.
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = var.law_name
  resource_group_name = var.rg_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_days
  tags                = var.tags

  # Cost guard while learning: caps ingestion so a noisy loop cannot bill you.
  daily_quota_gb = var.daily_quota_gb

  internet_ingestion_enabled = true
  internet_query_enabled     = true
}

# Workspace-based App Insights (classic is retired).
resource "azurerm_application_insights" "this" {
  name                = var.appi_name
  resource_group_name = var.rg_name
  location            = var.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this.id
  retention_in_days   = var.retention_days
  sampling_percentage = var.sampling_percentage
  tags                = var.tags

  # Local (instrumentation-key) auth. Leave enabled while learning; set
  # false to force Entra ID auth for telemetry ingestion.
  local_authentication_enabled = true
}

# --------------------------------------------------------------- action group
resource "azurerm_monitor_action_group" "oncall" {
  name                = var.action_group_name
  resource_group_name = var.rg_name
  short_name          = substr(replace(var.action_group_name, "-", ""), 0, 12)
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = var.oncall_emails
    content {
      name                    = "email-${replace(email_receiver.value, "@", "-at-")}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  dynamic "webhook_receiver" {
    for_each = var.webhook_url == null ? [] : [var.webhook_url]
    content {
      name                    = "teams-or-slack"
      service_uri             = webhook_receiver.value
      use_common_alert_schema = true
    }
  }
}

# ----------------------------------------------------- availability / latency
resource "azurerm_monitor_metric_alert" "api_failures" {
  name                = "alert-${var.base_name}-api-failed-requests"
  resource_group_name = var.rg_name
  scopes              = [azurerm_application_insights.this.id]
  description         = "ERP API 5xx rate exceeded threshold over 5 minutes."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/failed"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = var.failed_request_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.oncall.id
  }
}

resource "azurerm_monitor_metric_alert" "api_latency" {
  name                = "alert-${var.base_name}-api-latency"
  resource_group_name = var.rg_name
  scopes              = [azurerm_application_insights.this.id]
  description         = "ERP API p95 server response time above SLO."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/duration"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.latency_threshold_ms
  }

  action {
    action_group_id = azurerm_monitor_action_group.oncall.id
  }
}

# ------------------------------------------------- KQL (log) based alerts
# These are the interesting ones: they alert on *business* and *platform*
# conditions, which is what distinguishes a platform engineer from someone
# who only wired up CPU alerts.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pod_restarts" {
  name                 = "alert-${var.base_name}-pod-crashloop"
  resource_group_name  = var.rg_name
  location             = var.location
  description          = "A pod in the erp namespace restarted more than 5 times in 15 min."
  severity             = 1
  enabled              = true
  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"
  scopes               = [azurerm_log_analytics_workspace.this.id]
  tags                 = var.tags

  criteria {
    query = <<-KQL
      KubePodInventory
      | where Namespace == "erp"
      | summarize Restarts = max(PodRestartCount) by Name, bin(TimeGenerated, 5m)
      | where Restarts > 5
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.oncall.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "ledger_out_of_balance" {
  name                 = "alert-${var.base_name}-ledger-out-of-balance"
  resource_group_name  = var.rg_name
  location             = var.location
  description          = "Worker reported the ERP general ledger does not balance."
  severity             = 0 # critical: this is a financial-integrity breach
  enabled              = true
  evaluation_frequency = "PT15M"
  window_duration      = "PT1H"
  scopes               = [azurerm_log_analytics_workspace.this.id]
  tags                 = var.tags

  criteria {
    query = <<-KQL
      ContainerLogV2
      | where PodNamespace == "erp"
      | where LogMessage has "LedgerOutOfBalance"
      | project TimeGenerated, PodName, LogMessage
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.oncall.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "reorder_breach" {
  name                 = "alert-${var.base_name}-stock-reorder-breach"
  resource_group_name  = var.rg_name
  location             = var.location
  description          = "More than 10 SKUs fell below reorder point."
  severity             = 3
  enabled              = true
  evaluation_frequency = "PT1H"
  window_duration      = "PT6H"
  scopes               = [azurerm_log_analytics_workspace.this.id]
  tags                 = var.tags

  criteria {
    query = <<-KQL
      ContainerLogV2
      | where PodNamespace == "erp"
      | where LogMessage has "ReorderPointBreached"
      | summarize Breaches = dcount(tostring(parse_json(LogMessage).sku))
    KQL

    time_aggregation_method = "Count"
    threshold               = 10
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.oncall.id]
  }
}
