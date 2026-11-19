# envs/prod

The production root module. It calls the same
[`stacks/erp-platform`](../../stacks/erp-platform) as
[`envs/dev`](../dev) — the architecture is identical and every difference is
a value.

## The dev → prod delta, in full

| Setting | dev | prod | Why it matters |
|---|---|---|---|
| AKS API server | public, IP-restricted | **private** | no public IP at all; breaks Microsoft-hosted agents |
| AKS local accounts | enabled | **disabled** | removes the static cluster-admin cert; Entra ID only |
| AKS SKU tier | Free | **Standard** | uptime SLA + cost analysis |
| ACR / Key Vault public access | enabled | **disabled** | private endpoints only; ACR must be Premium |
| Key Vault purge protection | off | **on** | irreversible; name locked for up to 90 days after delete |
| PostgreSQL password auth | enabled | **disabled** | Entra ID is the only way in |
| PostgreSQL HA | none | **ZoneRedundant** | ~60s failover; roughly doubles DB cost |
| PostgreSQL backups | 7 days, local | **35 days, geo-redundant** | survives a regional outage |
| PostgreSQL SKU | Burstable B1ms | **General Purpose** | burstable throttles unpredictably under sustained load |
| Availability zones | `["1"]` | **`["1","2","3"]`** | survives a zone failure |
| Node counts | 1–4 | **3–12**, system 2–4 | capacity and redundancy |
| Azure Firewall | off | **on** | forced egress with an FQDN allow-list |
| App Gateway WAF | off | **on** | public ingress with OWASP 3.2 in Prevention |
| AKS outbound type | `loadBalancer` | **`userDefinedRouting`** | set automatically when the firewall is on |
| Log Analytics cap | 1 GB/day | **10 GB/day** | losing telemetry mid-incident costs more than ingestion |
| DB admin principal | your user | **a group** | never an individual in production |

## Before you apply

1. **Read [guidance/13](../../../../guidance/13-cost-and-teardown.md).**
   This environment is roughly **USD 35/day** with the firewall and gateway on.
2. Create the Entra groups and get their object ids.
3. `./scripts/db-grant-identities.sh prod` **must run before the first
   application deploy**, because password auth is disabled — the migration job
   has no other way in.
4. Plan the pipeline agent problem: a private cluster is unreachable from a
   Microsoft-hosted agent. See
   [guidance/08 §8](../../../../guidance/08-azure-devops-setup.md).

## Apply

```bash
cd infra/terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars    # then edit it

export ARM_USE_AZUREAD=true
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform show tfplan | less                    # read it properly
terraform apply tfplan
```

In practice you would not run this by hand. The
[infra pipeline](../../../../pipelines/azure-pipelines-infra.yml) runs
`plan`, publishes the plan file, waits for two approvals, and then applies
**the approved plan** — so what was reviewed is byte-for-byte what runs.
