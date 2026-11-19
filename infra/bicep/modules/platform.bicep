// Key Vault + ACR, Bicep edition.
targetScope = 'resourceGroup'

param location string
param tags object
param keyVaultName string
param acrName string
param workspaceId string

@description('Dev/sandbox keeps these public so you can push images without a VPN. Set false for prod and add private endpoints.')
param publicNetworkAccess bool = true

// ------------------------------------------------------------- Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // RBAC mode, not legacy access policies. One permission model across the
    // whole platform, and it supports PIM and Deny assignments.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Purge protection is irreversible once enabled, which is why dev leaves
    // it off: you want to be able to destroy and recreate the lab.
    enablePurgeProtection: null
    publicNetworkAccess: publicNetworkAccess ? 'Enabled' : 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: publicNetworkAccess ? 'Allow' : 'Deny'
    }
  }
}

resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: keyVault
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        // AuditEvent is the one that matters: every secret read, by whom.
        category: 'AuditEvent'
        enabled: true
      }
      {
        category: 'AzurePolicyEvaluationDetails'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ------------------------------------------------------------------- ACR
resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: publicNetworkAccess ? 'Basic' : 'Premium' // private endpoints need Premium
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // No shared username and password, ever. Pulls use AcrPull on a managed
    // identity; pushes use the pipeline's federated service connection.
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: publicNetworkAccess ? 'Enabled' : 'Disabled'
    networkRuleBypassOptions: 'AzureServices'
    policies: {
      quarantinePolicy: {
        // Images are unpullable until they have been scanned. Only available
        // on Premium.
        status: publicNetworkAccess ? 'disabled' : 'enabled'
      }
      retentionPolicy: {
        status: publicNetworkAccess ? 'disabled' : 'enabled'
        days: 7
      }
      trustPolicy: {
        type: 'Notary'
        status: 'disabled' // enable once you are signing images
      }
    }
  }
}

resource acrDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: acr
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        category: 'ContainerRegistryLoginEvents'
        enabled: true
      }
      {
        category: 'ContainerRegistryRepositoryEvents'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
output acrId string = acr.id
output acrLoginServer string = acr.properties.loginServer
