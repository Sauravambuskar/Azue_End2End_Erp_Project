// ===========================================================================
// ContosoERP landing zone - Bicep implementation.
//
// WHY THIS FILE EXISTS
// The JD asks for "Terraform and/or Bicep". The Terraform under
// infra/terraform/ is the one this project actually deploys. This Bicep
// deploys the same core landing zone so you can compare the two honestly and
// answer the "which would you choose?" question from experience rather than
// from a blog post.
//
// Differences you will notice immediately, and should be able to name:
//   1. No state file. ARM is the state. Nothing to lock, nothing to corrupt,
//      and no secrets persisted outside Azure.
//   2. Scope is declarative and checked at compile time (targetScope below),
//      whereas Terraform infers scope from each resource's arguments.
//   3. Outputs marked @secure() are genuinely not returned in plain text.
//   4. Removing a resource from this file does NOT delete it, unless you
//      deploy in Complete mode - which is a sharp edge Terraform does not have.
//
// Deploy:
//   az deployment sub create \
//     --location centralindia \
//     --template-file infra/bicep/landing-zone.bicep \
//     --parameters workload=erp env=sandbox ownerEmail=you@example.com \
//     --name bicep-lz-test
//
// Preview first (the equivalent of terraform plan):
//   az deployment sub what-if \
//     --location centralindia \
//     --template-file infra/bicep/landing-zone.bicep \
//     --parameters workload=erp env=sandbox ownerEmail=you@example.com
// ===========================================================================

targetScope = 'subscription'

// ------------------------------------------------------------- parameters
@description('Short workload name, e.g. erp.')
@minLength(2)
@maxLength(8)
param workload string = 'erp'

@description('Environment name.')
@allowed([
  'dev'
  'test'
  'prod'
  'sandbox'
])
param env string = 'sandbox'

@description('Azure region for all resources.')
param location string = 'centralindia'

@description('Owner email - goes into the Owner tag and alerts.')
param ownerEmail string

@description('Cost centre for chargeback.')
param costCentre string = 'CC-LEARNING-001'

@description('Data classification of the workload.')
@allowed([
  'public'
  'internal'
  'confidential'
  'restricted'
])
param dataClassification string = 'internal'

@description('Hub VNet address space.')
param hubCidr string = '10.0.0.0/16'

@description('Spoke VNet address space.')
param spokeCidr string = '10.10.0.0/16'

@description('Log Analytics daily ingestion cap in GB. Cost guard.')
@minValue(1)
param logDailyQuotaGb int = 1

@description('Retention in days for Log Analytics and App Insights.')
@minValue(30)
@maxValue(730)
param retentionDays int = 30

// ----------------------------------------------------------------- naming
// Same algorithm as infra/terraform/modules/naming, so names match whichever
// tool you deploy with.
var regionShort = {
  centralindia: 'cin'
  southindia: 'sin'
  westindia: 'win'
  eastus: 'eus'
  westeurope: 'weu'
}

// Safe access (.?) with a null-coalescing fallback: the idiomatic Bicep form,
// and what the linter rule use-safe-access asks for.
var loc = regionShort[?location] ?? substring(location, 0, 3)
var base = '${workload}-${env}-${loc}'

// uniqueString() is Bicep's deterministic hash - the Bicep equivalent of the
// Terraform module's sha1(subscription_id) trick.
var uniq = substring(uniqueString(subscription().subscriptionId, workload, env), 0, 6)

var names = {
  rgNetwork: 'rg-${base}-network'
  rgPlatform: 'rg-${base}-platform'
  rgData: 'rg-${base}-data'
  rgAks: 'rg-${base}-aks'
  vnetHub: 'vnet-hub-${env}-${loc}'
  vnetSpoke: 'vnet-spoke-${base}'
  logAnalytics: 'log-${base}'
  appInsights: 'appi-${base}'
  keyVault: 'kv-${substring(workload, 0, min(6, length(workload)))}-${env}-${uniq}'
  acr: 'acr${replace(workload, '-', '')}${env}${uniq}'
  actionGroup: 'ag-${base}-oncall'
}

var tags = {
  Workload: workload
  Environment: env
  CostCentre: costCentre
  Owner: ownerEmail
  DataClass: dataClassification
  ManagedBy: 'bicep'
  BusinessUnit: 'manufacturing'
}

// -------------------------------------------------------- resource groups
resource rgNetwork 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgNetwork
  location: location
  tags: tags
}

resource rgPlatform 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgPlatform
  location: location
  tags: tags
}

resource rgData 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgData
  location: location
  tags: tags
}

resource rgAks 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgAks
  location: location
  tags: tags
}

// ------------------------------------------------------------- modules
// Bicep modules are deployed at a scope, which is explicit and compile-time
// checked. This is genuinely nicer than Terraform's implicit scoping.
module network 'modules/network.bicep' = {
  name: 'deploy-network'
  scope: rgNetwork
  params: {
    location: location
    tags: tags
    hubVnetName: names.vnetHub
    spokeVnetName: names.vnetSpoke
    hubCidr: hubCidr
    spokeCidr: spokeCidr
    baseName: base
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'deploy-monitoring'
  scope: rgPlatform
  params: {
    location: location
    tags: tags
    workspaceName: names.logAnalytics
    appInsightsName: names.appInsights
    actionGroupName: names.actionGroup
    dailyQuotaGb: logDailyQuotaGb
    retentionDays: retentionDays
    oncallEmail: ownerEmail
  }
}

module platform 'modules/platform.bicep' = {
  name: 'deploy-platform'
  scope: rgPlatform
  params: {
    location: location
    tags: tags
    keyVaultName: names.keyVault
    acrName: names.acr
    workspaceId: monitoring.outputs.workspaceId
    // Sandbox/dev keeps these public so you can push images from a laptop.
    // For prod, flip to false and add private endpoints.
    publicNetworkAccess: env == 'dev' || env == 'sandbox'
  }
}

// ----------------------------------------------------------------- outputs
output resourceGroups object = {
  network: rgNetwork.name
  platform: rgPlatform.name
  data: rgData.name
  aks: rgAks.name
}

output vnetIds object = {
  hub: network.outputs.hubVnetId
  spoke: network.outputs.spokeVnetId
}

output subnetIds object = network.outputs.subnetIds

output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output acrLoginServer string = platform.outputs.acrLoginServer
output keyVaultUri string = platform.outputs.keyVaultUri

output appliedTags object = tags

output nextSteps string = '''
Landing zone deployed with Bicep.

The AKS cluster and PostgreSQL server are NOT in this template on purpose:
this file exists for comparison with the Terraform, and duplicating 500 lines
of AKS configuration in two languages is exactly the maintenance debt you
should avoid in real life.

Pick ONE tool per platform. Use this template to answer the interview
question, then deploy the real thing with:

  cd infra/terraform/envs/dev && terraform apply
'''
