# Azure CLI cheatsheet

Commands you will actually use on this project, grouped by task.

---

## Context

```bash
az login
az login --use-device-code                 # headless / WSL
az account list -o table
az account set --subscription "<name-or-id>"
az account show --query '{sub:name, id:id, tenant:tenantId}' -o json

# The four values you need constantly
az account show --query id -o tsv                      # subscription id
az account show --query tenantId -o tsv                # tenant id
az ad signed-in-user show --query id -o tsv            # your object id
az ad signed-in-user show --query userPrincipalName -o tsv

# Tokens
az account get-access-token --query accessToken -o tsv
az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv  # PostgreSQL
az account get-access-token --resource "api://erp-api" --query accessToken -o tsv # your API
```

### Output control — learn this, it saves hours

```bash
-o table            # human
-o tsv              # for scripts; no quotes, no headers
-o json             # default
-o yaml
--query '<JMESPath>'
--only-show-errors  # suppress warnings in scripts
--no-wait           # fire and forget
```

JMESPath patterns worth memorising:

```bash
--query '[].name'                              # one field from a list
--query '[].{n:name, l:location}'              # rename fields
--query "[?location=='centralindia']"          # filter
--query "[?contains(name,'erp')].name"         # substring filter
--query "[?powerState.code=='Running']"        # nested filter
--query 'length(@)'                            # count
--query 'sort_by([], &name)'                   # sort
--query '[0:5]'                                # first five
--query "[?tags.Workload=='erp']"              # filter by tag
```

---

## Resource groups and resources

```bash
az group list -o table
az group list --query "[?starts_with(name,'rg-erp')].name" -o tsv
az group create -n rg-x -l centralindia --tags Workload=erp Environment=dev
az group delete -n rg-x --yes --no-wait

# Everything in this project, anywhere
az resource list --query "[?tags.Workload=='erp'].{n:name, t:type, rg:resourceGroup}" -o table

# What is in a resource group
az resource list -g rg-erp-dev-cin-platform --query '[].{n:name,t:type}' -o table

# Find a resource id (needed constantly for role assignments)
az resource show -g <rg> -n <name> --resource-type <type> --query id -o tsv
```

---

## Providers and quota

```bash
az provider register --namespace Microsoft.ContainerService
az provider list --query "[?registrationState=='Registering'].namespace" -o tsv
az provider show --namespace Microsoft.ContainerService --query registrationState -o tsv

# Quota - check BEFORE you build
az vm list-usage -l centralindia \
  --query "[?contains(localName,'Total Regional vCPUs')].{used:currentValue, limit:limit}" -o table

# Is this VM size available here, and in which zones?
az vm list-skus -l centralindia --size Standard_D2s \
  --query "[?name=='Standard_D2s_v5'].{n:name, zones:locationInfo[0].zones}" -o table

# Why can't I use a SKU? (restrictions tell you)
az vm list-skus -l centralindia --size Standard_D2s_v5 \
  --query '[0].restrictions' -o json
```

---

## RBAC and identity

```bash
# Who has what, where
az role assignment list --all --include-inherited \
  --query '[].{who:principalName, type:principalType, role:roleDefinitionName, scope:scope}' -o table

# The red-flag query: any role assigned directly to a USER?
az role assignment list --all \
  --query "[?principalType=='User'].{who:principalName, role:roleDefinitionName}" -o table

# Assign (always to a group)
az role assignment create \
  --assignee-object-id "<group-object-id>" --assignee-principal-type Group \
  --role "Contributor" --scope "/subscriptions/<sub>/resourceGroups/<rg>"

az role assignment delete --assignee-object-id "<oid>" --role "Contributor" --scope "<scope>"

# What can this role actually do?
az role definition list -n "Key Vault Secrets User" \
  --query '[0].permissions[0].{actions:actions, dataActions:dataActions}' -o json

# Find a role by what it does
az role definition list --query "[?contains(roleName,'Kubernetes')].roleName" -o tsv
```

### Groups and app registrations

```bash
az ad group create --display-name grp-x --mail-nickname grp-x
az ad group show -g grp-x --query id -o tsv
az ad group member add --group grp-x --member-id "<user-oid>"
az ad group member list --group grp-x --query '[].displayName' -o table

az ad app create --display-name sp-x --query appId -o tsv
az ad sp create --id "<app-id>"
az ad sp show --id "<app-id>" --query id -o tsv        # the OBJECT id
az ad app credential list --id "<app-id>" --query 'length(@)' -o tsv   # should be 0!

az ad app federated-credential list --id "<app-id>" \
  --query '[].{name:name, subject:subject, issuer:issuer}' -o table
```

### Managed identities

```bash
az identity list -g <rg> --query '[].{n:name, client:clientId, principal:principalId}' -o table
az identity show -n id-erp-api-dev -g <rg> --query clientId -o tsv

az identity federated-credential list --identity-name id-erp-api-dev -g <rg> \
  --query '[].{n:name, sub:subject, iss:issuer}' -o json
```

### Management groups

```bash
az account management-group list --query '[].{n:name, parent:parent.name}' -o table
az account management-group create --name mg-x --display-name "X" --parent <tenant-id>
az account management-group subscription add --name mg-x --subscription <sub-id>
az account management-group show --name mg-x --expand --recurse -o json

# Elevate to manage the tenant root (chapter 01 §6)
az rest --method post --url \
  "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"
```

---

## AKS

```bash
az aks list -o table
az aks show -g <rg> -n <aks> --query '{state:provisioningState, power:powerState.code, k8s:kubernetesVersion, private:apiServerAccessProfile.enablePrivateCluster}' -o json

az aks get-credentials -g <rg> -n <aks> --overwrite-existing
kubelogin convert-kubeconfig -l azurecli        # REQUIRED for Entra clusters

# Cost control
az aks stop  -g <rg> -n <aks>
az aks start -g <rg> -n <aks>

# Node pools
az aks nodepool list -g <rg> --cluster-name <aks> \
  --query '[].{n:name, count:count, size:vmSize, mode:mode, k8s:orchestratorVersion}' -o table
az aks nodepool scale -g <rg> --cluster-name <aks> -n user --node-count 0
az aks nodepool update -g <rg> --cluster-name <aks> -n user \
  --update-cluster-autoscaler --min-count 1 --max-count 5

# Upgrades
az aks get-upgrades -g <rg> -n <aks> -o table
az aks upgrade -g <rg> -n <aks> --kubernetes-version 1.32.0 --control-plane-only
az aks nodepool upgrade -g <rg> --cluster-name <aks> -n user \
  --kubernetes-version 1.32.0 --max-surge 33%

# Add-ons
az aks update -g <rg> -n <aks> --enable-keda
az aks update -g <rg> -n <aks> --enable-azure-monitor-metrics
az aks show -g <rg> -n <aks> --query addonProfiles -o json

# Run a command from INSIDE the cluster (works with a private cluster)
az aks command invoke -g <rg> -n <aks> --command "kubectl -n erp get pods"

# Diagnose
az aks check-acr -g <rg> -n <aks> --acr <acr>.azurecr.io
```

---

## ACR

```bash
az acr login -n <acr>
az acr show -n <acr> --query '{admin:adminUserEnabled, sku:sku.name, public:publicNetworkAccess}' -o json

az acr repository list -n <acr> -o tsv
az acr repository show-tags -n <acr> --repository erp-api -o table
az acr repository show-manifests -n <acr> --repository erp-api \
  --query '[].{digest:digest, tags:tags, size:imageSize, created:createdTime}' -o table

az acr repository delete -n <acr> --image erp-api:old-tag --yes

# Purge old images (keeps the 10 newest, deletes anything over 30 days)
az acr run --registry <acr> --cmd \
  "acr purge --filter 'erp-api:.*' --ago 30d --keep 10 --untagged" /dev/null

# Build in the cloud, no local Docker needed
az acr build -r <acr> -t erp-api:v1 -f src/erp-api/Dockerfile src/erp-api
```

---

## Key Vault

```bash
az keyvault list -o table
az keyvault show -n <kv> --query '{rbac:properties.enableRbacAuthorization, purge:properties.enablePurgeProtection, public:properties.publicNetworkAccess}' -o json

az keyvault secret list --vault-name <kv> \
  --query '[].{n:name, enabled:attributes.enabled, expires:attributes.expires}' -o table
az keyvault secret set --vault-name <kv> -n <name> --value "<v>"
az keyvault secret show --vault-name <kv> -n <name> --query value -o tsv
az keyvault secret list-versions --vault-name <kv> -n <name> -o table

az keyvault secret set-attributes --vault-name <kv> -n <name> \
  --expires "$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)"

# Expiring in 30 days
CUT=$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%SZ)
az keyvault secret list --vault-name <kv> \
  --query "[?attributes.expires < '$CUT'].{n:name, expires:attributes.expires}" -o table

# Soft delete and recovery
az keyvault secret delete --vault-name <kv> -n <name>
az keyvault secret list-deleted --vault-name <kv> -o table
az keyvault secret recover --vault-name <kv> -n <name>
az keyvault secret purge --vault-name <kv> -n <name>        # refused if purge protection on

# Deleted vaults (blocking a name reuse)
az keyvault list-deleted -o table
az keyvault purge --name <kv>
```

---

## PostgreSQL Flexible Server

```bash
az postgres flexible-server list -o table
az postgres flexible-server show -g <rg> -n <pg> \
  --query '{state:state, sku:sku.name, public:network.publicNetworkAccess, aad:authConfig.activeDirectoryAuth, ha:highAvailability.state}' -o json

az postgres flexible-server stop  -g <rg> -n <pg>     # auto-restarts after 7 days
az postgres flexible-server start -g <rg> -n <pg>

az postgres flexible-server parameter list -g <rg> -s <pg> \
  --query "[?name=='require_secure_transport' || name=='pgaudit.log'].{n:name, v:value}" -o table
az postgres flexible-server parameter set -g <rg> -s <pg> --name pgbouncer.enabled --value true

# Entra administrators
az postgres flexible-server ad-admin list -g <rg> -s <pg> -o table

# Point-in-time restore (always to a NEW server)
az postgres flexible-server restore -g <rg> -n <pg>-restored \
  --source-server <pg> --restore-time "2026-11-17T14:30:00Z"
```

---

## Networking

```bash
az network vnet list -o table
az network vnet subnet list -g <rg> --vnet-name <vnet> \
  --query '[].{n:name, cidr:addressPrefix, nsg:networkSecurityGroup.id, deleg:delegations[0].serviceName}' -o table

az network vnet peering list -g <rg> --vnet-name <vnet> \
  --query '[].{n:name, state:peeringState, sync:peeringSyncLevel}' -o table
az network vnet peering sync -g <rg> --vnet-name <vnet> -n <peering>

az network nsg rule list -g <rg> --nsg-name <nsg> \
  --query "sort_by([].{p:priority, n:name, dir:direction, acc:access, src:sourceAddressPrefix, ports:destinationPortRange}, &p)" -o table

# Service tags - what IPs are behind a tag?
az network list-service-tags -l centralindia \
  --query "values[?name=='AzureKubernetesService'].properties.addressPrefixes[0:5]" -o tsv

# Private DNS - the three things that must all be true
az network private-dns zone list -g <rg> --query '[].name' -o tsv
az network private-dns link vnet list -g <rg> --zone-name <zone> -o table    # THE LINK
az network private-dns record-set a list -g <rg> --zone-name <zone> \
  --query '[].{n:name, ip:aRecords[0].ipv4Address}' -o table

az network private-endpoint list -g <rg> \
  --query '[].{n:name, target:privateLinkServiceConnections[0].privateLinkServiceId}' -o table

# Waste: unattached public IPs
az network public-ip list --query "[?ipConfiguration==null].{n:name, rg:resourceGroup}" -o table

# THE debugging tool - returns Allow/Deny AND the deciding rule name
az network watcher test-ip-flow -g <rg> --vm <vm> \
  --direction Inbound --protocol TCP --local 10.10.4.5:8000 --remote 10.10.16.4:50000

# App Gateway health - the authoritative answer
az network application-gateway show-backend-health -g <rg> -n <agw> -o table
```

---

## Monitoring

```bash
LAW_GUID=$(az monitor log-analytics workspace show --ids <law-id> --query customerId -o tsv)
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query "<KQL>" -o table

az monitor log-analytics workspace list \
  --query '[].{n:name, quota:workspaceCapping.dailyQuotaGb, ret:retentionInDays}' -o table
az monitor log-analytics workspace update -g <rg> -n <law> --quota 1

az monitor metrics alert list -g <rg> --query '[].{n:name, sev:severity, on:enabled}' -o table
az monitor scheduled-query list -g <rg> --query '[].{n:name, sev:severity}' -o table

az monitor diagnostic-settings list --resource <resource-id> -o table

# Fired alerts in the last day
az rest --method get \
  --url "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d" \
  --query "value[].{rule:properties.essentials.alertRule, sev:properties.essentials.severity, state:properties.essentials.monitorCondition}" -o table

# What changed in Azure?
az monitor activity-log list --offset 6h \
  --query "[?contains(operationName.value,'write')||contains(operationName.value,'delete')].{t:eventTimestamp, who:caller, what:operationName.localizedValue}" -o table
```

---

## Policy and Defender

```bash
az policy definition list --query "[?policyType=='Custom'].{n:name, d:displayName}" -o table
az policy definition list --query "[?policyType=='BuiltIn' && contains(displayName,'Kubernetes')].{n:name,d:displayName}" -o table

az policy assignment list --scope "/subscriptions/${SUB_ID}" -o table
az policy assignment list --scope "/subscriptions/${SUB_ID}" --disable-scope-strict-match -o table  # includes INHERITED

az policy assignment create --name x --policy <def> --scope <scope> \
  --params '{"effect":{"value":"Audit"}}'
az policy assignment update --name x --params '{"effect":{"value":"Deny"}}'
az policy assignment create --name x --policy <def> --scope <scope> --enforcement-mode DoNotEnforce

az policy state trigger-scan --subscription "${SUB_ID}" --no-wait
az policy state summarize --subscription "${SUB_ID}" -o json
az policy state list --filter "complianceState eq 'NonCompliant'" \
  --query "value[].{res:resourceId, pol:policyDefinitionName}" -o table

az policy exemption create --name x --policy-assignment <id> \
  --exemption-category Waiver --scope <scope> \
  --expires-on "$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%SZ)" --description "reason"

# Defender
az security pricing list --query 'value[].{plan:name, tier:pricingTier}' -o table
az security pricing create --name Containers --tier Standard
az security pricing create --name Containers --tier Free        # TURN IT OFF
az security secure-score list --query '[].{n:displayName, pct:score.percentage}' -o table
az security assessment list --query "[?status.code=='Unhealthy'].displayName" -o tsv | head -20
```

---

## Cost

```bash
az consumption usage list \
  --start-date "$(date -u +%Y-%m-01)" --end-date "$(date -u +%Y-%m-%d)" \
  --query "[?tags.Workload=='erp'].{svc:meterDetails.meterName, cost:pretaxCost}" -o table

az consumption budget list --query '[].{n:name, amount:amount}' -o table

az disk list --query "[?diskState=='Unattached'].{n:name, gb:diskSizeGb}" -o table
az snapshot list --query '[].{n:name, gb:diskSizeGb, created:timeCreated}' -o table
```

---

## Azure DevOps

```bash
az extension add --name azure-devops
az devops configure --defaults organization=https://dev.azure.com/<org> project=<project>

az repos list -o table
az repos create --name erp-platform

az pipelines list -o table
az pipelines run --name "ContosoERP-CI" --branch main
az pipelines runs list --pipeline-name "ContosoERP-CI" --top 5 \
  --query '[].{id:id, result:result, branch:sourceBranch}' -o table
az pipelines runs artifact download --run-id <id> --artifact-name sast-reports --path ./a

az pipelines variable-group list -o table

az repos pr create --title "x" --source-branch feature/x --target-branch main
az repos pr list --status active -o table
```

---

## Habits worth building

```bash
# 1. Always --query. Full JSON output is unreadable and slow to scan.
# 2. Always -o table for humans, -o tsv for scripts.
# 3. --no-wait for long operations, then poll.
# 4. --only-show-errors in scripts, so warnings do not pollute output.
# 5. az <cmd> --help is better than a web search. Try:
az aks create --help | grep -A3 "outbound-type"

# 6. az find for discovery
az find "az aks nodepool"

# 7. Add --debug when something fails inexplicably - it shows the raw
#    REST call and response.
az aks show -g <rg> -n <aks> --debug 2>&1 | grep -i "request url"
```
