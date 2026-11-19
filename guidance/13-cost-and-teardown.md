# 13 — Cost control and teardown

**Time:** 1 hour · **Cost:** this chapter *saves* money
**Prerequisite:** anything deployed

Read this **before** your first long practice session, not after your first
surprise bill.

---

## 1. What actually costs money here

Measured on `centralindia`, approximate, at the time of writing.

| Resource | Config | Per hour | Per day | Per month |
|---|---|---|---|---|
| AKS control plane | Free tier | **₹0** | ₹0 | ₹0 |
| AKS nodes | 2 × D2s_v5 | ₹11 | ₹265 | ₹8,000 |
| PostgreSQL | B1ms, 32 GB | ₹2 | ₹48 | ₹1,450 |
| ACR | Basic | ₹0.5 | ₹12 | ₹360 |
| Log Analytics | 1 GB/day cap | ₹1 | ₹24 | ₹720 |
| Public IP | Standard, static | ₹0.3 | ₹7 | ₹220 |
| **Baseline total** | | **~₹15** | **~₹355** | **~₹10,750** |
| | | | | |
| App Gateway WAF v2 | 1 instance | **₹20** | ₹480 | ₹14,400 |
| **Azure Firewall** | **Basic** | **₹100** | **₹2,400** | **₹72,000** |
| Cosmos DB | serverless, idle | ~₹0 | ~₹0 | ~₹0 |
| Bastion | Basic | ₹15 | ₹360 | ₹10,800 |
| Defender for Containers | 4 vCPU | ₹2 | ₹48 | ₹1,450 |

**₹ ≈ USD/83.** Baseline is roughly **USD 4.30/day**; with the firewall on it
is **USD 33/day**.

### The three facts that matter

1. **The AKS control plane is free** on the Free tier. You pay for nodes. So
   `az aks stop` takes your largest line item to zero while keeping all
   configuration.
2. **Azure Firewall is 6× everything else combined.** It is on an
   `enable_firewall` flag defaulting to `false` for exactly this reason. One
   forgotten weekend costs more than the rest of the project.
3. **Log Analytics is the one that surprises people**, because a chatty log is
   free to write and expensive to store. The 1 GB daily cap is the single most
   important default in this repo.

---

## 2. The end-of-session ritual — build the habit

Run this every time you stop working. It takes about four minutes.

```bash
cd /d/Azure

# 1. What is costing money right now?
./scripts/cost-check.sh

# 2. Stop the big two
AKS_RG=$(cd infra/terraform/envs/dev && terraform output -raw aks_resource_group)
AKS_NAME=$(cd infra/terraform/envs/dev && terraform output -raw aks_name)
DATA_RG=$(cd infra/terraform/envs/dev && terraform output -json resource_groups | jq -r .data)
PG_NAME=$(cd infra/terraform/envs/dev && terraform output -raw postgres_name)

az aks stop -g "$AKS_RG" -n "$AKS_NAME" --no-wait
az postgres flexible-server stop -g "$DATA_RG" -n "$PG_NAME" --no-wait

# 3. Confirm the expensive optional things are off
cd infra/terraform/envs/dev
grep -E "enable_(firewall|appgw|cosmos)" terraform.tfvars
```

Next session:

```bash
az aks start -g "$AKS_RG" -n "$AKS_NAME"
az postgres flexible-server start -g "$DATA_RG" -n "$PG_NAME"
# AKS start takes 3-5 minutes; PostgreSQL about 2
```

### Automate it so you cannot forget

```bash
# A nightly auto-stop at 22:00 IST, so a forgotten cluster costs one evening
# rather than a week.
az aks nodepool update -g "$AKS_RG" --cluster-name "$AKS_NAME" -n user \
  --update-cluster-autoscaler --min-count 0 --max-count 4 2>/dev/null || true
```

Better: an Automation Account runbook or a scheduled GitHub Action / Azure
DevOps pipeline that runs `az aks stop` nightly. If you only do one thing from
this section, do this one:

```yaml
# pipelines/azure-pipelines-nightly-stop.yml
schedules:
  - cron: "30 16 * * *"      # 22:00 IST
    displayName: Nightly stop
    branches: { include: [main] }
    always: true
trigger: none
pool: { vmImage: ubuntu-latest }
steps:
  - task: AzureCLI@2
    inputs:
      azureSubscription: sc-erp-dev-wif
      scriptType: bash
      scriptLocation: inlineScript
      inlineScript: |
        az aks stop -g rg-erp-dev-cin-aks -n aks-erp-dev-cin-01 --no-wait
        az postgres flexible-server stop -g rg-erp-dev-cin-data -n psql-erp-dev-cin-01 --no-wait
```

### The PostgreSQL stop caveat

**A stopped Flexible Server restarts itself automatically after 7 days.** It
is not an indefinite pause. If you are stepping away for longer, either accept
the restart or tear down and redeploy — the Terraform makes redeployment
cheap, which is the whole point of IaC.

---

## 3. Monitor spend properly

```bash
# Month to date, by service
az consumption usage list \
  --start-date "$(date -u +%Y-%m-01)" --end-date "$(date -u +%Y-%m-%d)" \
  --query "[].{svc:meterDetails.meterCategory, cost:pretaxCost}" -o tsv 2>/dev/null \
  | awk -F'\t' '{s[$1]+=$2} END {for (k in s) printf "%-40s %10.2f\n", k, s[k]}' \
  | sort -k2 -rn

# Only this project (that is what the tags are for)
az consumption usage list \
  --start-date "$(date -u +%Y-%m-01)" --end-date "$(date -u +%Y-%m-%d)" \
  --query "[?tags.Workload=='erp'].{svc:meterDetails.meterName, cost:pretaxCost}" -o table

# Remaining free-trial credit
az rest --method get \
  --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2020-05-01" \
  --query "value[].{name:properties.displayName, type:properties.agreementType}" -o table
```

Also set a **cost anomaly alert**, which is better than a budget threshold
because it detects an unusual *pattern* rather than an absolute number:

**Portal → Cost Management → Cost alerts → + Add → Anomaly alert.**

---

## 4. Find and kill waste

```bash
./scripts/cost-check.sh     # does most of this for you
```

The specific things to hunt:

```bash
# Unattached public IPs - pure waste, ~₹220/month each
az network public-ip list \
  --query "[?ipConfiguration==null].{name:name, rg:resourceGroup, sku:sku.name}" -o table

# Unattached managed disks - left behind by deleted VMs and node pools
az disk list --query "[?diskState=='Unattached'].{name:name, gb:diskSizeGb, rg:resourceGroup}" -o table

# Orphaned load balancers from a deleted LoadBalancer Service
az network lb list --query "[?backendAddressPools[0].backendIPConfigurations==null].{name:name, rg:resourceGroup}" -o table

# Snapshots nobody remembers taking
az snapshot list --query '[].{name:name, gb:diskSizeGb, created:timeCreated}' -o table

# Old container images filling ACR (Basic has a 10 GB included quota)
ACR_NAME=$(cd infra/terraform/envs/dev && terraform output -raw acr_name)
az acr repository list -n "$ACR_NAME" -o tsv | while read -r repo; do
  count=$(az acr repository show-tags -n "$ACR_NAME" --repository "$repo" --query 'length(@)' -o tsv)
  echo "$repo: $count tags"
done

# Purge images older than 30 days, keeping the 10 most recent
az acr run --registry "$ACR_NAME" --cmd \
  "acr purge --filter 'erp-api:.*' --filter 'erp-web:.*' --filter 'erp-worker:.*' --filter 'erp-migrate:.*' --ago 30d --keep 10 --untagged" \
  /dev/null
```

### Right-sizing from real data, not guesses

```bash
# What are the pods actually using?
kubectl top pods -n erp
kubectl top nodes

# Over a longer window, from Log Analytics
LAW_GUID=$(az monitor log-analytics workspace show \
  --ids "$(cd infra/terraform/envs/dev && terraform output -raw log_analytics_workspace_id)" \
  --query customerId -o tsv)

az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  Perf
  | where TimeGenerated > ago(7d)
  | where ObjectName == "K8SContainer" and CounterName == "memoryWorkingSetBytes"
  | summarize P50=percentile(CounterValue,50)/1048576,
              P95=percentile(CounterValue,95)/1048576,
              Max=max(CounterValue)/1048576
    by InstanceName
  | order by P95 desc' -o table
```

**Set requests near the p50 and limits near the p95 plus headroom.** If your
request is 192 Mi and the p95 is 90 Mi, you are reserving twice what you need,
which means the autoscaler adds nodes earlier than necessary — requests drive
scheduling and therefore node count and therefore cost.

---

## 5. Teardown

### Partial — keep the configuration, stop the meter

```bash
az aks stop -g "$AKS_RG" -n "$AKS_NAME"
az postgres flexible-server stop -g "$DATA_RG" -n "$PG_NAME"
```

Cost drops to roughly **₹2/hour** (ACR, Log Analytics, public IP).

### Scale to zero — keep the cluster reachable

```bash
az aks nodepool scale -g "$AKS_RG" --cluster-name "$AKS_NAME" -n user --node-count 0
# System pool must keep >= 1 node, so this is not free, but it is cheaper
```

### Full teardown

```bash
cd /d/Azure
./scripts/teardown.sh dev
```

The script, in order: uninstalls Helm releases and deletes the namespace
(so finalizers do not block the VNet delete), warns about the node resource
group, runs `terraform destroy`, then purges any soft-deleted Key Vault so the
name can be reused. It asks for confirmation twice and **refuses to run
against `prod`.**

### When teardown fails — the five real causes

| Symptom | Cause | Fix |
|---|---|---|
| `Subnet is in use by ...` | an orphaned load balancer or NIC from a `LoadBalancer` Service | delete the Service first, or delete the LB manually |
| VNet delete hangs | a private endpoint Terraform does not know about | `az network private-endpoint list` and delete it |
| `Cannot delete resource group` | the node resource group has resources not in state | let the AKS delete remove it; do not delete it by hand |
| Key Vault name unavailable on recreate | soft-deleted vault still holding the name | `az keyvault purge --name <name>` (impossible if purge protection is on) |
| `ResourceGroupNotEmpty` | something was created in the portal | `az resource list -g <rg>` and remove it |

```bash
# The nuclear option, if Terraform state and reality have diverged badly
for rg in $(az group list --query "[?starts_with(name,'rg-erp-dev')].name" -o tsv); do
  echo "deleting $rg"
  az group delete -n "$rg" --yes --no-wait
done

# Then clean the state so Terraform does not try to manage ghosts
cd infra/terraform/envs/dev
terraform state list | while read -r r; do terraform state rm "$r"; done
```

> Doing this once deliberately is worth it. Knowing how to recover from a
> broken state file is a real operational skill, and "I have had to recover
> Terraform state after a partial destroy" is a much better answer than
> "Terraform just works".

### What to keep between sessions

| Keep | Delete |
|---|---|
| `rg-tfstate-shared` (state; costs ~₹10/month) | `rg-erp-dev-cin-*` |
| Management group hierarchy (free) | the AKS cluster |
| Entra groups and app registrations (free) | PostgreSQL |
| Policy definitions and assignments (free) | ACR (rebuild images is fast) |

Everything in the "keep" column is free or near-free and takes real time to
recreate. Everything in the "delete" column is one `terraform apply` away.

---

## 6. The cost conversation in an interview

**"How do you manage cloud cost?"**

> Four layers, and the order matters because the cheapest controls are the
> preventive ones. **Prevent:** Azure Policy restricting regions and VM SKUs,
> so nobody can deploy a GPU node or a wrong-region resource by accident, and
> a mandatory-tag Deny policy so every rupee is attributable to a workload,
> environment and cost centre. **Detect:** budgets with actual *and forecast*
> alerts — the forecast one is the valuable one, because it warns on the burn
> rate on day three rather than the total on day twenty-five — plus cost
> anomaly alerts, which catch an unusual pattern rather than an absolute
> number. **Optimise:** right-size from observed data, not guesses; I query
> the p50 and p95 working set from Log Analytics and set requests near the p50,
> because requests drive scheduling and therefore node count and therefore
> cost. And for steady-state production, reserved instances or savings plans
> for the baseline node capacity with on-demand for the autoscaled portion.
> **Operate:** dev and test stopped outside working hours on a schedule, a
> hard daily cap on Log Analytics ingestion because telemetry is the cost that
> grows silently, and ACR purge tasks so old images do not accumulate.

**"What was the most expensive mistake you made in this project?"**

Have a real answer. If you leave the firewall on for a weekend, say so:

> I left Azure Firewall enabled over a weekend during the egress-lockdown
> exercise. It is about USD 30 a day, which was more than everything else in
> the project combined, and the forecast budget alert is what caught it on the
> Sunday. Two things came out of it: I put the firewall and the Application
> Gateway behind Terraform feature flags that default to off, so the expensive
> resources are opt-in rather than opt-out, and I added a nightly scheduled
> pipeline that stops the cluster and the database. The general lesson is that
> the cost risk in a cloud platform is not usually a big obvious mistake, it
> is something cheap that nobody turned off — so the control has to be
> automatic rather than a reminder.

That answer is better than claiming you made no mistakes. It shows you
measure, you respond, and you fix the system rather than the instance.

---

## 7. Checklist

- [ ] You know the three most expensive things and their rough hourly cost
- [ ] Budget with 50/80/**forecast 100** alerts exists (chapter 01)
- [ ] Cost anomaly alert configured
- [ ] Log Analytics daily cap set to 1 GB
- [ ] `enable_firewall` and `enable_appgw` are `false` in `terraform.tfvars`
- [ ] **You have run `./scripts/cost-check.sh` at the end of a session**
- [ ] You can stop and start both AKS and PostgreSQL from memory
- [ ] You know a stopped Flexible Server auto-restarts after 7 days
- [ ] Nightly auto-stop pipeline created (or you have accepted the risk)
- [ ] You hunted for unattached IPs, disks, snapshots and orphaned LBs
- [ ] You right-sized at least one deployment from Log Analytics percentiles
- [ ] ACR purge task understood
- [ ] **You have performed a full teardown and redeployed from scratch**
- [ ] You know the five teardown failure modes
- [ ] You have a real, specific answer to "your most expensive mistake"

Next: [chapter 14 — Platform runbook](14-runbook.md)
