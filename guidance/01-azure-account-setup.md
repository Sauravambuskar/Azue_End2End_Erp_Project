# 01 — Azure account and safety rails

**Time:** 1 hour · **Cost:** ₹0 · **Prerequisite:** none

Before you create a single resource, you set up the things that stop this
project from becoming an expensive mistake. Do not skip this chapter. The
budget alert in §5 is the single most valuable 5 minutes in the whole course.

---

## 1. Create the account

Go to <https://azure.microsoft.com/free>.

What you get:
- **USD 200 credit, valid 30 days**
- 12 months of selected services free (which does *not* include AKS nodes)
- Always-free tier (which does include 1 free AKS control plane on the Free SKU)

What you need:
- A phone number for SMS verification
- A credit or debit card for identity verification — **you are not charged**
  unless you explicitly upgrade to pay-as-you-go
- An email that is **not** already tied to a work Microsoft tenant, otherwise
  you may land in your employer's directory with no permission to create
  anything

> **Tip:** use a personal Microsoft account. You need to be able to create
> management groups and assign roles at tenant root scope, which you will
> never be allowed to do in a corporate tenant.

### Expect this
After signup you have:
- One tenant (your directory), e.g. `yourname.onmicrosoft.com`
- One subscription named **Azure subscription 1** with the Free Trial offer
- Your account is **Owner** on that subscription — but *not* automatically
  able to manage management groups (fixed in §6)

---

## 2. Install the tooling

| Tool | Why | Install |
|---|---|---|
| Azure CLI | everything | `winget install Microsoft.AzureCLI` |
| Terraform | IaC | `winget install Hashicorp.Terraform` |
| kubectl | AKS | `az aks install-cli` |
| kubelogin | Entra-auth kubeconfig | `az aks install-cli` (installs both) |
| Helm | deploy the chart | `winget install Helm.Helm` |
| Docker Desktop | local stack + image builds | <https://docker.com/products/docker-desktop> |
| Git | obvious | `winget install Git.Git` |
| Trivy | image/IaC scanning | `winget install AquaSecurity.Trivy` |
| Gitleaks | secret scanning | `winget install Gitleaks.Gitleaks` |
| psql | DB work | comes with PostgreSQL client tools |
| jq | JSON wrangling | `winget install jqlang.jq` |

Verify:

```bash
az version
terraform version
kubectl version --client
helm version --short
docker version --format '{{.Server.Version}}'
trivy --version
```

> On Windows, run the shell commands in this course from **Git Bash**, not
> PowerShell or cmd. Every script here is POSIX `sh`.

---

## 3. Log in and find your identifiers

```bash
az login
```

A browser opens. After login:

```bash
# Which subscriptions can I see?
az account list --output table

# Pin the one you will use
az account set --subscription "Azure subscription 1"

# The four values you will need constantly — write them down
az account show --query '{subscription:id, tenant:tenantId, name:name}' -o json
az ad signed-in-user show --query '{objectId:id, upn:userPrincipalName}' -o json
```

Save them somewhere you can copy from:

```bash
cat > ~/.erp-lab-env <<'EOF'
export SUB_ID="<subscription id>"
export TENANT_ID="<tenant id>"
export MY_OID="<your user object id>"
export MY_UPN="<your UPN>"
export LOCATION="centralindia"
EOF

echo 'source ~/.erp-lab-env' >> ~/.bashrc
source ~/.erp-lab-env
```

> **Do not** put these in a file inside the repo. `SUB_ID` and `TENANT_ID` are
> not secrets, but the habit of keeping identifiers out of the repo is what
> stops a real secret going in later. Gitleaks will scan for exactly this.

---

## 4. Register the resource providers you will need

A fresh subscription has most providers unregistered. Registering later, mid
`terraform apply`, produces a confusing `MissingSubscriptionRegistration`
error. Do it now; it takes a few minutes in the background.

```bash
for ns in \
  Microsoft.ContainerService \
  Microsoft.ContainerRegistry \
  Microsoft.DBforPostgreSQL \
  Microsoft.KeyVault \
  Microsoft.Network \
  Microsoft.OperationalInsights \
  Microsoft.OperationsManagement \
  Microsoft.Insights \
  Microsoft.Monitor \
  Microsoft.Security \
  Microsoft.PolicyInsights \
  Microsoft.ManagedIdentity \
  Microsoft.DocumentDB \
  Microsoft.ServiceBus \
  Microsoft.Storage \
  Microsoft.Authorization \
  Microsoft.Management
do
  echo "registering $ns"
  az provider register --namespace "$ns" --only-show-errors
done

# Check progress (all should reach "Registered")
az provider list \
  --query "[?registrationState=='Registering'].{ns:namespace,state:registrationState}" \
  -o table
```

Also register the preview features this project uses:

```bash
# Required for the AKS features used in modules/aks
az extension add --name aks-preview --only-show-errors
az extension add --name k8s-extension --only-show-errors
az extension update --name aks-preview --only-show-errors
```

---

## 5. Set the safety rails — DO THIS NOW

### 5a. A budget with alerts

```bash
source ~/.erp-lab-env

cat > /tmp/budget.json <<EOF
{
  "category": "Cost",
  "amount": 40,
  "timeGrain": "Monthly",
  "timePeriod": {
    "startDate": "$(date -u +%Y-%m-01)T00:00:00Z",
    "endDate":   "$(date -u -d '+1 year' +%Y-%m-01)T00:00:00Z"
  },
  "notifications": {
    "at50pct": {
      "enabled": true, "operator": "GreaterThan", "threshold": 50,
      "contactEmails": ["${MY_UPN}"], "thresholdType": "Actual"
    },
    "at80pct": {
      "enabled": true, "operator": "GreaterThan", "threshold": 80,
      "contactEmails": ["${MY_UPN}"], "thresholdType": "Actual"
    },
    "forecast100": {
      "enabled": true, "operator": "GreaterThan", "threshold": 100,
      "contactEmails": ["${MY_UPN}"], "thresholdType": "Forecasted"
    }
  }
}
EOF

az rest --method put \
  --url "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.Consumption/budgets/erp-learning-budget?api-version=2023-05-01" \
  --body "@/tmp/budget.json"
```

The **forecast** alert is the important one: it warns you based on your current
burn *rate*, so you hear about a left-running firewall on day 3, not day 25.

Verify in the portal: **Cost Management + Billing → Budgets**.

### 5b. Spending limit (free trial only)

Free-trial subscriptions have a spending limit **on** by default — when the
credit runs out, resources are deprovisioned rather than billed. Leave it on.

```bash
# Confirm which offer you are on
az account show --query '{name:name, state:state}' -o table
```

If you are on pay-as-you-go there is no spending limit, which makes §5a
mandatory rather than merely wise.

### 5c. A tag-based cost view

Everything this project creates is tagged `Workload=erp`. That means you can
always answer "what is this project costing me?" in one query:

```bash
az consumption usage list \
  --start-date "$(date -u +%Y-%m-01)" \
  --end-date   "$(date -u +%Y-%m-%d)" \
  --query "[?tags.Workload=='erp'].{svc:meterDetails.meterCategory, cost:pretaxCost}" \
  -o table
```

---

## 6. Give yourself management group permissions

To create the management group hierarchy in chapter 02 you need **Owner** or
**Management Group Contributor** at the **tenant root group**. Being
subscription Owner is not enough, and this is a famously confusing gotcha.

```bash
source ~/.erp-lab-env

# Step 1: elevate your access (makes you User Access Administrator at root)
az rest --method post \
  --url "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"

# Step 2: grant yourself Owner at the tenant root group.
# The tenant root management group id EQUALS the tenant id.
az role assignment create \
  --assignee-object-id "$MY_OID" \
  --assignee-principal-type User \
  --role "Owner" \
  --scope "/providers/Microsoft.Management/managementGroups/${TENANT_ID}"
```

### Verify

```bash
az account management-group list -o table
# Should list at least the "Tenant Root Group"
```

If you get `AuthorizationFailed`, wait 5 minutes — role assignments at root
scope take a while to propagate — then retry.

> **Interview-relevant detail:** `elevateAccess` is audited and intentionally
> temporary. In a real tenant you would remove the elevation afterwards:
> **Entra ID → Properties → Access management for Azure resources → No**. Say
> that out loud if asked about tenant-level permissions; it shows you know the
> control exists for break-glass, not for daily use.

---

## 7. Decide your region

This project defaults to **`centralindia`** — right for a Hyderabad/Pune role,
low latency, and it supports everything used here.

Check capacity before you commit:

```bash
# Does the region have the VM size we want, and do you have quota?
az vm list-skus \
  --location centralindia \
  --size Standard_D2s \
  --query "[?name=='Standard_D2s_v5'].{name:name, zones:locationInfo[0].zones}" \
  -o table

# Your current vCPU quota (a new trial often has only 4-10 vCPUs total)
az vm list-usage --location centralindia \
  --query "[?contains(localName,'Standard DSv5')].{name:localName, used:currentValue, limit:limit}" \
  -o table
```

**If your quota is below 8 vCPUs**, the two-node-pool AKS design in chapter 05
will not fit. Options, in order of preference:

1. Request a quota increase (free, usually approved within hours):
   `az quota` or **Portal → Subscriptions → Usage + quotas → Request increase**
2. Use `node_vm_size = "Standard_B2s"` (2 vCPU, burstable, cheaper)
3. Set `availability_zones = []` and run a single node per pool

---

## 8. Verify the whole chapter

```bash
source ~/.erp-lab-env

echo "--- identity ---"
az account show --query '{sub:name, tenant:tenantId}' -o table
az ad signed-in-user show --query userPrincipalName -o tsv

echo "--- management group access ---"
az account management-group list --query '[].{name:name, display:displayName}' -o table

echo "--- budget ---"
az consumption budget list --query '[].{name:name, amount:amount}' -o table

echo "--- providers still registering ---"
az provider list --query "[?registrationState=='Registering'].namespace" -o tsv

echo "--- quota ---"
az vm list-usage --location "$LOCATION" \
  --query "[?contains(localName,'Total Regional vCPUs')].{used:currentValue, limit:limit}" -o table
```

Everything should be clean, and the "still registering" list should be empty
after ~10 minutes.

---

## 9. Break it on purpose

Learn what these two errors look like now, in a calm moment, rather than at
hour three of a build.

**Exercise A — the unregistered provider**

```bash
# Pick a provider you did NOT register
az provider unregister --namespace Microsoft.ServiceBus
az servicebus namespace create -g nonexistent -n test-$RANDOM -l centralindia
```

You will see `MissingSubscriptionRegistration`. Re-register it:

```bash
az provider register --namespace Microsoft.ServiceBus
```

**Exercise B — the scope mistake**

```bash
# Try a management group operation at the WRONG scope
az account management-group create --name mg-test-fail \
  --parent "/subscriptions/${SUB_ID}"
```

Fails: a management group's parent must be another management group, never a
subscription. Subscriptions are *leaves* of the hierarchy, never parents. This
is exactly the mental model chapter 02 builds on.

---

## 10. Interview answers this chapter gives you

**"How do you control cost on a cloud platform?"**

> Layered. At the subscription level, a budget with actual *and forecast*
> alerts — the forecast one matters because it catches a bad burn rate on day
> three instead of day twenty-five. At the resource level, Azure Policy
> restricts regions and VM SKUs so nobody can deploy a GPU node by accident.
> At the data level, a daily ingestion cap on Log Analytics, because telemetry
> is the cost that grows silently. Then tagging — everything carries
> `Workload`, `Environment` and `CostCentre`, enforced by a Deny policy, so
> cost is always attributable. And operationally, a stop/start discipline:
> dev AKS and dev PostgreSQL are stopped outside working hours.

**"What is the difference between a management group, a subscription and a
resource group?"**

> They are three nested scopes, and the thing that matters is what each one is
> *for*. A management group is the policy and RBAC inheritance boundary — you
> assign a policy initiative once at a management group and every subscription
> below inherits it. A subscription is the billing and quota boundary, and the
> blast-radius boundary; that is why environments get separate subscriptions.
> A resource group is the lifecycle boundary — things that are created and
> deleted together. The rule I follow is: if two resources have different
> lifecycles, they go in different resource groups.

**"Why would you need to elevate access in Entra ID?"**

> To get User Access Administrator at the tenant root group, which is what you
> need to create the management group hierarchy or assign roles at root scope.
> It is a break-glass mechanism, it is audited, and you turn it off afterwards.
> Day to day you would do landing-zone work through a privileged group with
> PIM-activated eligibility rather than standing access.

---

## Checklist

- [ ] Azure account created, subscription visible
- [ ] All tooling installed and version-checked
- [ ] `~/.erp-lab-env` holds SUB_ID, TENANT_ID, MY_OID, MY_UPN, LOCATION
- [ ] Resource providers registered (none left "Registering")
- [ ] **Budget with 50/80/forecast-100 alerts created**
- [ ] Owner at tenant root group; `az account management-group list` works
- [ ] Region chosen and vCPU quota confirmed ≥ 8
- [ ] Both "break it" exercises done — you recognise both errors
- [ ] `docker compose up -d` works and `./scripts/smoke-test.sh` passes 27/27

Next: [chapter 02 — Landing zone](02-landing-zone.md)
