# ---------------------------------------------------------------------------
# A shared Azure portal dashboard, defined as code.
#
# Interview point: "operational dashboards" in the JD does not mean somebody
# clicked around the portal. It means this JSON is in git, reviewed in a PR,
# and recreated identically in every environment.
# ---------------------------------------------------------------------------
locals {
  dashboard_parts = {
    # Request volume and failures from App Insights
    "0" = {
      position = { x = 0, y = 0, colSpan = 6, rowSpan = 4 }
      metadata = {
        type = "Extension/HubsExtension/PartType/MonitorChartPart"
        inputs = [{
          name = "options"
          value = {
            chart = {
              metrics = [{
                resourceMetadata = { id = azurerm_application_insights.this.id }
                name             = "requests/count"
                aggregationType  = 7
                namespace        = "microsoft.insights/components"
              }]
              title         = "ERP API - request volume"
              visualization = { chartType = 2 }
              timespan      = { relative = { duration = 86400000 } }
            }
          }
        }]
      }
    }
    "1" = {
      position = { x = 6, y = 0, colSpan = 6, rowSpan = 4 }
      metadata = {
        type = "Extension/HubsExtension/PartType/MonitorChartPart"
        inputs = [{
          name = "options"
          value = {
            chart = {
              metrics = [{
                resourceMetadata = { id = azurerm_application_insights.this.id }
                name             = "requests/failed"
                aggregationType  = 7
                namespace        = "microsoft.insights/components"
              }]
              title         = "ERP API - failed requests (5xx)"
              visualization = { chartType = 2 }
            }
          }
        }]
      }
    }
    "2" = {
      position = { x = 0, y = 4, colSpan = 6, rowSpan = 4 }
      metadata = {
        type = "Extension/HubsExtension/PartType/MonitorChartPart"
        inputs = [{
          name = "options"
          value = {
            chart = {
              metrics = [{
                resourceMetadata = { id = azurerm_application_insights.this.id }
                name             = "requests/duration"
                aggregationType  = 4
                namespace        = "microsoft.insights/components"
              }]
              title         = "ERP API - average server response time"
              visualization = { chartType = 2 }
            }
          }
        }]
      }
    }
    # Saved KQL: business KPI straight off the container logs
    "3" = {
      position = { x = 6, y = 4, colSpan = 6, rowSpan = 4 }
      metadata = {
        type = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
        settings = {
          content = {
            Query = join("\n", [
              "ContainerLogV2",
              "| where PodNamespace == 'erp'",
              "| where LogMessage has 'ReorderPointBreached'",
              "| summarize Breaches = count() by bin(TimeGenerated, 1h)",
              "| render timechart"
            ])
            PartTitle    = "Stock reorder breaches per hour"
            PartSubTitle = azurerm_log_analytics_workspace.this.name
          }
        }
      }
    }
  }
}

resource "azurerm_portal_dashboard" "platform" {
  name                = var.dashboard_name
  resource_group_name = var.rg_name
  location            = var.location
  tags                = merge(var.tags, { "hidden-title" = "ERP Platform - ${var.base_name}" })

  dashboard_properties = jsonencode({
    lenses = [{
      order = 0
      parts = [
        for k, p in local.dashboard_parts : {
          position = p.position
          metadata = p.metadata
        }
      ]
    }]
    metadata = {
      model = {
        timeRange = {
          value = { relative = { duration = 24, timeUnit = 1 } }
          type  = "MsPortalFx.Composition.Configuration.ValueTypes.TimeRange"
        }
      }
    }
  })
}
