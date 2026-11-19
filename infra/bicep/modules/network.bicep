// Hub-spoke network, Bicep edition. Mirrors infra/terraform/modules/network.
targetScope = 'resourceGroup'

param location string
param tags object
param baseName string
param hubVnetName string
param spokeVnetName string
param hubCidr string
param spokeCidr string

// cidrSubnet() is a Bicep built-in, the equivalent of Terraform's cidrsubnet().
var subnets = {
  firewall: cidrSubnet(hubCidr, 26, 0) //           10.0.0.0/26
  bastion: cidrSubnet(hubCidr, 26, 1) //            10.0.0.64/26
  shared: cidrSubnet(hubCidr, 24, 2) //             10.0.2.0/24
  aksSystem: cidrSubnet(spokeCidr, 22, 0) //        10.10.0.0/22
  aksUser: cidrSubnet(spokeCidr, 22, 1) //          10.10.4.0/22
  appgw: cidrSubnet(spokeCidr, 24, 16) //           10.10.16.0/24
  privateEndpoints: cidrSubnet(spokeCidr, 24, 17) // 10.10.17.0/24
  postgres: cidrSubnet(spokeCidr, 24, 19) //        10.10.19.0/24
}

// ------------------------------------------------------------------- NSGs
resource nsgAks 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-aks-${baseName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-AppGW-To-Ingress'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: subnets.appgw
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['80', '443', '3000', '8000']
        }
      }
      {
        name: 'Allow-Intra-VNet'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgAppgw 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-appgw-${baseName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // Mandatory for App Gateway v2. Without it the gateway never becomes
        // healthy, and the error message does not tell you why.
        name: 'Allow-GatewayManager-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'Allow-Web-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['80', '443']
        }
      }
      {
        name: 'Allow-AzureLoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ------------------------------------------------------------------ VNets
resource hub 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: hubVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [hubCidr]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet' // name is fixed by Azure
        properties: {
          addressPrefix: subnets.firewall
        }
      }
      {
        name: 'AzureBastionSubnet' // name is fixed by Azure
        properties: {
          addressPrefix: subnets.bastion
        }
      }
      {
        name: 'snet-shared-services'
        properties: {
          addressPrefix: subnets.shared
        }
      }
    ]
  }
}

resource spoke 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: spokeVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [spokeCidr]
    }
    subnets: [
      {
        name: 'snet-aks-system'
        properties: {
          addressPrefix: subnets.aksSystem
          networkSecurityGroup: {
            id: nsgAks.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
            {
              service: 'Microsoft.KeyVault'
            }
          ]
        }
      }
      {
        name: 'snet-aks-user'
        properties: {
          addressPrefix: subnets.aksUser
          networkSecurityGroup: {
            id: nsgAks.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
            {
              service: 'Microsoft.KeyVault'
            }
          ]
        }
      }
      {
        name: 'snet-appgw'
        properties: {
          addressPrefix: subnets.appgw
          networkSecurityGroup: {
            id: nsgAppgw.id
          }
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: subnets.privateEndpoints
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: 'snet-postgres'
        properties: {
          addressPrefix: subnets.postgres
          delegations: [
            {
              name: 'psql-delegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- peering
resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hub
  name: 'peer-hub-to-spoke'
  properties: {
    remoteVirtualNetwork: {
      id: spoke.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
  }
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: spoke
  name: 'peer-spoke-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hub.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false
  }
}

// ------------------------------------------------------- private DNS zones
// These names are FIXED by Azure Private Link and must be literal strings -
// environment().suffixes.storage would render a different value and the zone
// would resolve nothing. Hence the explicit linter suppression.
var privateDnsZones = [
  'privatelink.postgres.database.azure.com'
  'privatelink.vaultcore.azure.net'
  'privatelink.azurecr.io'
  #disable-next-line no-hardcoded-env-urls
  'privatelink.blob.core.windows.net'
  'privatelink.documents.azure.com'
]

resource dnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zone in privateDnsZones: {
    name: zone
    location: 'global' // private DNS zones are always global
    tags: tags
  }
]

// A zone with no VNet link resolves nothing. This loop is the step people
// forget, and the symptom is a private endpoint that still returns the
// public IP.
resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zone, i) in privateDnsZones: {
    name: 'link-spoke'
    parent: dnsZones[i]
    location: 'global'
    tags: tags
    properties: {
      virtualNetwork: {
        id: spoke.id
      }
      registrationEnabled: false
    }
  }
]

// ----------------------------------------------------------------- outputs
output hubVnetId string = hub.id
output spokeVnetId string = spoke.id

output subnetIds object = {
  firewall: '${hub.id}/subnets/AzureFirewallSubnet'
  bastion: '${hub.id}/subnets/AzureBastionSubnet'
  shared: '${hub.id}/subnets/snet-shared-services'
  aksSystem: '${spoke.id}/subnets/snet-aks-system'
  aksUser: '${spoke.id}/subnets/snet-aks-user'
  appgw: '${spoke.id}/subnets/snet-appgw'
  privateEndpoints: '${spoke.id}/subnets/snet-private-endpoints'
  postgres: '${spoke.id}/subnets/snet-postgres'
}

output subnetCidrs object = subnets
