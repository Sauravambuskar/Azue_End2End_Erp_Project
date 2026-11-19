// Log Analytics + Application Insights + action group, Bicep edition.
targetScope = 'resourceGroup'

param location string
param tags object
param workspaceName string
param appInsightsName string
param actionGroupName string
param oncallEmail string

@minValue(1)
param dailyQuotaGb int = 1

@minValue(30)
@maxValue(730)
param retentionDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionDays
    // The cost guard. Without a cap, a chatty debug log can ingest tens of
    // GB in a day and that is the single most common surprise cloud bill.
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// Workspace-based App Insights. Classic (non-workspace) App Insights is
// retired - if you see a template creating one without workspaceResourceId,
// it is out of date.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    RetentionInDays: retentionDays
    IngestionMode: 'LogAnalytics'
    SamplingPercentage: 100
    DisableLocalAuth: false
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global' // action groups are global
  tags: tags
  properties: {
    groupShortName: take(replace(actionGroupName, '-', ''), 12)
    enabled: true
    emailReceivers: [
      {
        name: 'oncall-email'
        emailAddress: oncallEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// -------------------------------------------------------------- alert rules
resource failedRequestsAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${appInsightsName}-failed-requests'
  location: 'global'
  tags: tags
  properties: {
    description: 'ERP API 5xx rate exceeded threshold over 5 minutes.'
    severity: 1
    enabled: true
    scopes: [appInsights.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'FailedRequests'
          metricNamespace: 'microsoft.insights/components'
          metricName: 'requests/failed'
          operator: 'GreaterThan'
          threshold: 10
          timeAggregation: 'Count'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

resource ledgerAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${workspaceName}-ledger-out-of-balance'
  location: location
  tags: tags
  properties: {
    displayName: 'ERP general ledger out of balance'
    description: 'The worker reported that debits do not equal credits. This is a financial-integrity breach, not a performance issue.'
    severity: 0
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    scopes: [workspace.id]
    criteria: {
      allOf: [
        {
          query: '''
            ContainerLogV2
            | where PodNamespace == "erp"
            | where LogMessage has "LedgerOutOfBalance"
            | project TimeGenerated, PodName, LogMessage
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

output workspaceId string = workspace.id
output workspaceGuid string = workspace.properties.customerId
output appInsightsId string = appInsights.id
output actionGroupId string = actionGroup.id

// Note how this is marked. Bicep genuinely will not print a @secure() output,
// unlike a Terraform output where `sensitive = true` only hides it from the
// console while still writing it to state in plain text.
@secure()
output appInsightsConnectionString string = appInsights.properties.ConnectionString
