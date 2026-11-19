# 14 — ContosoERP platform runbook

**Written for:** whoever is on call for the ERP platform — including you in
six months, when you have forgotten all of this.

**Time to work through:** 2 hours · **Cost:** ₹0

The JD lists "Platform Runbook" as a key deliverable. This is it. A runbook is
not documentation of how the platform was built — that is the rest of
`guidance/`. A runbook answers **"it is 2 a.m., something is wrong, what do I
do?"**

> **Rewrite this in your own words before the interview.** A runbook you can
> talk through fluently is worth far more than one you read once.

---

## 1. Service summary

| | |
|---|---|
| **Service** | ContosoERP — manufacturing ERP (master data, sales, purchasing, inventory, finance) |
| **Business impact if down** | order entry and goods receipt stop; the plant store cannot issue stock |
| **Business hours** | 08:00–20:00 IST, Mon–Sat |
| **Owner** | Platform Engineering — `platform-engineering@contoso.com` |
| **Escalation** | L1 on-call → platform lead → CTO |
| **Repository** | `erp-platform` |
| **Change process** | PR → CI → dev → test (1 approval) → prod (2 approvals + CHG ticket + window) |

### Components

| Component | Type | Replicas (prod) | Depends on |
|---|---|---|---|
| `erp-web` | Deployment | 3 | `erp-api` |
| `erp-api` | Deployment | 3 | PostgreSQL, Key Vault, Entra ID |
| `erp-worker` | CronJob, hourly | 1 per run | PostgreSQL, Service Bus |
| `erp-migrate` | Job, Helm pre-upgrade hook | 1 per deploy | PostgreSQL |
| PostgreSQL Flexible Server | PaaS | ZoneRedundant HA | — |
| Application Gateway | PaaS | 2–10 autoscale | AKS ingress |

### SLOs

| Metric | Target | Measured by |
|---|---|---|
| Availability | 99.5% during business hours | App Insights availability |
| p95 API latency | < 1,500 ms | `AppRequests` percentile |
| Error rate | < 0.5% of requests | `AppRequests` Success == false |
| RPO | 5 minutes | PostgreSQL PITR |
| RTO | 30 minutes | tested restore |

---

## 2. First five minutes of any incident

Do these in order. Do not start debugging until you have done all five.

```bash
# 0. Set context
AKS_RG=rg-erp-prod-cin-aks; AKS_NAME=aks-erp-prod-cin-01
az aks get-credentials -g "$AKS_RG" -n "$AKS_NAME" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

# 1. Is it actually down, or is it one component?
kubectl -n erp get pods,svc,ingress
kubectl -n erp get deploy -o wide

# 2. What changed? (this answers most incidents)
helm -n erp history erp | tail -5
kubectl -n erp get events --sort-by=.lastTimestamp | tail -25

# 3. Are the dependencies healthy?
kubectl -n erp exec deploy/erp-api -- curl -sf localhost:8000/healthz/ready || echo "API NOT READY"
az postgres flexible-server show -g rg-erp-prod-cin-data -n psql-erp-prod-cin-01 --query state -o tsv

# 4. Is it Azure, not us?
az rest --method get --url "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&\$filter=properties/eventType eq 'ServiceIssue'" \
  --query "value[0:3].{title:properties.title, status:properties.status}" -o table

# 5. Communicate. Even "investigating, no cause yet" is better than silence.
```

### The decision tree

```
Is anything serving traffic?
├── NO  → is it the ingress, the pods, or the database?
│         → kubectl get pods: are they Running AND Ready?
│           ├── not Running → §3.1 (pods not starting)
│           ├── Running, not Ready → §3.2 (readiness failing, usually the DB)
│           └── Running and Ready → §3.3 (ingress / WAF / DNS)
└── YES but degraded
          ├── slow         → §3.4 (latency)
          ├── some errors  → §3.5 (partial failure)
          └── data wrong   → §3.6 (ledger integrity) ← the serious one
```

---

## 3. Runbooks by symptom

### 3.1 Pods not starting

```bash
kubectl -n erp get pods
kubectl -n erp describe pod <pod> | tail -40
```

| Pod status | Cause | Action |
|---|---|---|
| `Pending` | no capacity, or quota | `describe` → Events. "Insufficient cpu" → check autoscaler; "exceeded quota" → `kubectl -n erp describe resourcequota` |
| `ImagePullBackOff` | tag missing, or no `AcrPull` | `describe` → "manifest unknown" = bad tag; "401/403" = RBAC. Verify: `az acr repository show-tags -n <acr> --repository erp-api` |
| `CrashLoopBackOff` | app failing to start | `kubectl logs <pod> --previous` — the `--previous` is essential |
| `CreateContainerConfigError` | missing ConfigMap/Secret key | `describe` names the key |
| `ContainerCreating` (stuck) | CSI driver cannot mount from Key Vault | `kubectl -n kube-system logs -l app=secrets-store-provider-azure --tail=50` — the real error is there, not in the pod events |
| `Init:Error` | the migration hook failed | `kubectl -n erp logs job/erp-migrate-<rev>` |

**Exit codes:**
- `137` = 128+9 SIGKILL → **OOMKilled**. Check `describe` → Last State.
- `143` = 128+15 SIGTERM → graceful shutdown; something evicted it.
- anything else → application error, read the logs.

```bash
# If the container will not start at all and you need to look inside the image
kubectl -n erp debug deploy/erp-api --image=busybox --target=api -it -- sh
```

### 3.2 Pods Running but not Ready

This is almost always a **dependency**, which is by design: our liveness probe
does not touch the database, readiness does.

```bash
kubectl -n erp get endpoints erp-api        # empty = no Ready pods
kubectl -n erp exec deploy/erp-api -- curl -s localhost:8000/healthz/ready | jq
```

If `"database": "down"`:

```bash
# Is the server up?
az postgres flexible-server show -g rg-erp-prod-cin-data -n psql-erp-prod-cin-01 \
  --query '{state:state, ha:highAvailability.state}' -o json

# Is it DNS? (the most common cause - a missing private DNS VNet link)
kubectl -n erp run dns --rm -it --restart=Never --image=nicolaka/netshoot -- \
  nslookup psql-erp-prod-cin-01.postgres.database.azure.com
# A PUBLIC IP in the answer = the private DNS zone link is broken

# Is it connectivity?
kubectl -n erp run nc --rm -it --restart=Never --image=nicolaka/netshoot -- \
  nc -zv -w 5 psql-erp-prod-cin-01.postgres.database.azure.com 5432
# Timeout = NetworkPolicy or NSG. Refused = nothing listening.

# Is it authentication?
kubectl -n erp logs -l app.kubernetes.io/component=api --tail=40 | grep -i -E "auth|denied|token"
```

| Error in the log | Meaning | Fix |
|---|---|---|
| `password authentication failed for user "id-erp-api-prod"` | no PostgreSQL principal for the identity | `./scripts/db-grant-identities.sh prod` |
| `permission denied for table product` | principal exists, role not granted | `GRANT erp_app TO "id-erp-api-prod";` |
| `AADSTS70021` | federated credential subject/issuer mismatch | chapter 04 §5 |
| `too many connections` | pool × replicas exceeds the SKU limit | enable PgBouncer; reduce replicas |
| connection timeout | DNS or NetworkPolicy | the two checks above |

### 3.3 Pods healthy but users cannot reach the service

```bash
kubectl -n erp get ingress
kubectl -n erp describe ingress erp | tail -20

# Application Gateway backend health - the authoritative answer
az network application-gateway show-backend-health \
  -g rg-erp-prod-cin-platform -n agw-erp-prod-cin \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{ip:address, health:health, why:healthProbeLog}" -o table
```

| Backend health | Cause |
|---|---|
| `Unhealthy`, probe timeout | NSG blocking the gateway subnet → AKS, or the pod is not Ready |
| `Unhealthy`, 404 on probe | probe path wrong; must be `/healthz/ready` |
| `Unknown` | the `GatewayManager` 65200-65535 NSG rule is missing |
| no servers listed | AGIC has not reconciled; `kubectl -n kube-system logs -l app=ingress-appgw` |

```bash
# Is the WAF blocking legitimate traffic?
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  AzureDiagnostics
  | where Category == "ApplicationGatewayFirewallLog" and TimeGenerated > ago(30m)
  | summarize Blocked = count() by ruleId_s, Message, requestUri_s
  | order by Blocked desc | take 15' -o table
```

**If the WAF is blocking real traffic**, the emergency mitigation is to switch
the policy to Detection, then tune the specific rule properly afterwards:

```bash
az network application-gateway waf-policy update \
  -g rg-erp-prod-cin-platform -n wafpol-agw-erp-prod-cin --mode Detection
# THEN raise a follow-up to add a scoped exclusion and return to Prevention.
```

### 3.4 Slow

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  AppRequests
  | where TimeGenerated > ago(1h)
  | summarize Calls=count(), P50=percentile(DurationMs,50), P95=percentile(DurationMs,95)
    by Name
  | order by P95 desc | take 10' -o table

# Is the time in the database?
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  AppDependencies
  | where TimeGenerated > ago(1h) and Type == "SQL"
  | summarize Calls=count(), P95=percentile(DurationMs,95), TotalSec=sum(DurationMs)/1000
    by Target, Name
  | order by TotalSec desc | take 10' -o table
```

| Finding | Action |
|---|---|
| CPU throttling on pods | we set no CPU limits by design — verify none were added |
| Database p95 high | check `pg_stat_statements`; look for a missing index |
| N+1 query pattern | `AppDependencies` shows many small identical SQL calls |
| All endpoints slow equally | node pressure, or DB CPU — `kubectl top nodes` and the PG metrics |
| HPA at max replicas | raise `maxReplicas`, or find the real bottleneck |

```sql
-- From a psql session: the slowest statements
SELECT round(total_exec_time::numeric, 0) AS total_ms,
       calls,
       round(mean_exec_time::numeric, 1) AS mean_ms,
       left(query, 90) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

### 3.5 Some requests failing

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  AppRequests
  | where TimeGenerated > ago(1h) and Success == false
  | summarize Count=count() by ResultCode, Name
  | order by Count desc' -o table
```

| Code | Meaning here | Action |
|---|---|---|
| 401 | token invalid/expired | check the OIDC issuer and audience config |
| 403 | role missing | check the Entra app role or group claim |
| 409 | **business rule** — illegal state transition or oversell | usually correct behaviour; confirm with the business |
| 422 | validation failure | client sending bad data; check the caller |
| 500 | unhandled exception | `AppExceptions` for the stack trace |
| 502/503 | upstream unavailable | the API is down or the BFF cannot reach it |

```bash
# The stack traces
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  AppExceptions
  | where TimeGenerated > ago(1h)
  | summarize Count=count(), Sample=any(OuterMessage) by ProblemId
  | order by Count desc | take 10' -o table
```

### 3.6 Ledger out of balance — SEVERITY 0

**This is the most serious alert in the system.** It means the financial data
is wrong, not that the infrastructure is unhealthy.

```bash
# 1. Confirm it
kubectl -n erp create job --from=cronjob/erp-worker ledger-check-$(date +%s)
kubectl -n erp logs -l job-name --tail=20 | grep -i ledger

# 2. Quantify the imbalance
#    (from a psql session as the AAD admin)
SELECT SUM(debit) - SUM(credit) AS imbalance FROM gl_entry;

# 3. Find the offending batch - a balanced posting nets to zero per batch
SELECT batch_id,
       SUM(debit) AS dr, SUM(credit) AS cr,
       SUM(debit) - SUM(credit) AS delta,
       MIN(posting_date) AS posted,
       MIN(source_doc) AS doc
FROM gl_entry
GROUP BY batch_id
HAVING SUM(debit) <> SUM(credit)
ORDER BY posted DESC;
```

**Then:**

1. **Do not delete or edit GL rows.** The app role cannot
   (`REVOKE UPDATE, DELETE ON gl_entry`) and neither should you. Corrections
   are new, balanced reversing entries.
2. The `batch_id` and `source_doc` identify the sales or purchase order that
   produced it — investigate that document.
3. Escalate to finance. **This is a data-integrity incident, not just an IT
   one**, and finance must decide on the correcting entry.
4. Post a reversing batch, do not mutate history.

---

## 4. Standard procedures

### Deploy a new version

```bash
# Normal path: merge to main, approve the prod stage. Manual equivalent:
helm upgrade erp k8s/helm/erp -n erp \
  -f k8s/helm/erp/values-prod.yaml \
  --set image.tag=1.0.1312 \
  --atomic --wait --timeout 10m

kubectl -n erp rollout status deploy/erp-api
./scripts/smoke-test.sh https://erp.contoso-lab.com
```

### Roll back

```bash
helm -n erp history erp
helm -n erp rollback erp <revision>
kubectl -n erp rollout status deploy/erp-api
./scripts/smoke-test.sh https://erp.contoso-lab.com
```

**If the bad release included a migration**, Helm cannot undo it. Migrations
are written backward-compatible for exactly this reason. If one is genuinely
incompatible, it is a point-in-time restore — a much more serious event, with
finance sign-off.

### Scale for a known peak (month-end close)

```bash
kubectl -n erp patch hpa erp-api --type merge \
  -p '{"spec":{"minReplicas":6,"maxReplicas":30}}'

az aks nodepool update -g "$AKS_RG" --cluster-name "$AKS_NAME" -n user \
  --update-cluster-autoscaler --min-count 3 --max-count 12

# Revert afterwards
kubectl -n erp patch hpa erp-api --type merge \
  -p '{"spec":{"minReplicas":3,"maxReplicas":20}}'
```

### Rotate a secret

```bash
az keyvault secret set --vault-name kv-erp-prod-xxxxxx --name <name> --value "<new>"
# CSI driver picks it up within 2 minutes for file mounts.
# For the synced Kubernetes Secret consumed as an env var, restart:
kubectl -n erp rollout restart deploy/erp-api
```

### Apply an emergency database fix

```bash
# NEVER from a laptop. Always from inside the VNet, always as the
# migrate identity or the AAD admin, always with a change record.
kubectl -n erp run psql-emergency --rm -it --restart=Never \
  --image=postgres:16-alpine \
  --env="PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)" \
  --command -- psql "host=psql-erp-prod-cin-01.postgres.database.azure.com user=$(az ad signed-in-user show --query userPrincipalName -o tsv) dbname=erp sslmode=require"
```

**Rules:** wrap it in a transaction, `SELECT` the rows first, know your
rollback, and raise a follow-up migration so the fix is in code.

### Restore the database

```bash
# PITR always creates a NEW server; the original is untouched
az postgres flexible-server restore \
  -g rg-erp-prod-cin-data -n psql-erp-prod-restored \
  --source-server psql-erp-prod-cin-01 \
  --restore-time "2026-11-17T14:30:00Z"

# Then: verify the data, repoint the application, retire the old server.
# Expect 15-30 minutes. Communicate an RTO of 30+ minutes.
```

---

## 5. Diagnostic command reference

```bash
# ---------- cluster ----------
kubectl -n erp get pods -o wide
kubectl -n erp get events --sort-by=.lastTimestamp | tail -30
kubectl -n erp top pods
kubectl top nodes
kubectl -n erp logs -l app.kubernetes.io/part-of=contoso-erp --tail=100 --all-containers --prefix
kubectl -n erp logs <pod> --previous              # a crashed container
kubectl -n erp describe pod <pod>

# ---------- is it the network? ----------
kubectl -n erp run nst --rm -it --restart=Never --image=nicolaka/netshoot -- bash
#   nslookup <host>        DNS
#   nc -zv <host> <port>   connectivity (timeout = policy drop)
#   curl -v <url>          HTTP
#   traceroute <host>      path

# ---------- is it identity? ----------
kubectl -n erp exec deploy/erp-api -- env | grep AZURE_
kubectl -n erp exec deploy/erp-api -- ls /var/run/secrets/azure/tokens/
az identity federated-credential list --identity-name id-erp-api-prod -g rg-erp-prod-cin-platform

# ---------- is it Azure? ----------
az aks show -g "$AKS_RG" -n "$AKS_NAME" --query '{state:provisioningState, power:powerState.code, k8s:kubernetesVersion}' -o json
az postgres flexible-server show -g rg-erp-prod-cin-data -n psql-erp-prod-cin-01 --query '{state:state, ha:highAvailability.state}' -o json
az network application-gateway show-backend-health -g rg-erp-prod-cin-platform -n agw-erp-prod-cin -o table

# ---------- what changed? ----------
helm -n erp history erp
az monitor activity-log list --offset 6h --query "[?contains(operationName.value,'write') || contains(operationName.value,'delete')].{time:eventTimestamp, who:caller, what:operationName.localizedValue}" -o table
```

---

## 6. Maintenance calendar

| Frequency | Task | Command / where |
|---|---|---|
| **Daily** | check overnight alerts | Azure Monitor → Alerts |
| | confirm the worker CronJob succeeded | `kubectl -n erp get jobs` |
| **Weekly** | review Defender Secure Score and new recommendations | Defender for Cloud |
| | review policy compliance | `az policy state summarize` |
| | review Log Analytics ingestion by `DataType` | the `Usage` KQL query |
| | review and triage new CVEs from the pipeline | pipeline artefacts |
| **Monthly** | check the accepted-risk register for expiring entries | `security/sca-accepted-risks.txt` |
| | review secrets expiring in 30 days | the Key Vault expiry query |
| | **test a database restore** | chapter 06 §7 |
| | review RBAC: anything assigned to a user? | the role-assignment audit query |
| | right-size from p95 data | chapter 13 §4 |
| **Quarterly** | AKS minor version upgrade | chapter 05 §8 |
| | rotate anything that cannot be federated | |
| | review `ReviewDate` tags for orphaned resources | |
| | full DR exercise: restore into a clean RG | |

---

## 7. Known issues and gotchas

Things that have bitten us, so they do not bite you twice.

| Issue | Symptom | Resolution |
|---|---|---|
| First `terraform apply` fails on the identity module | empty OIDC issuer URL | apply again; the cluster must exist first |
| `az aks get-credentials` then Forbidden on everything | Azure role granted, no Kubernetes RBAC binding | both are needed — chapter 04 §7 |
| Pipeline hangs at AKS login | missing `kubelogin convert-kubeconfig` | Entra clusters need it for non-interactive auth |
| Private endpoint resolves to a public IP | private DNS zone not **linked** to the VNet | the link is the step people forget |
| `helm upgrade` reports success, pods broken | missing `--wait --atomic` | always use both |
| Node drain hangs forever during upgrade | PDB `minAvailable: 1` with 1 replica | PDB is disabled in dev for this reason |
| App Gateway backends `Unknown` | NSG missing the `GatewayManager` 65200-65535 rule | required by App Gateway v2 |
| Key Vault name unavailable after destroy | soft-deleted vault holds the name | `az keyvault purge` — impossible with purge protection on |
| Gatekeeper policy seems not to work | ~15-minute Azure Policy → cluster sync | wait, then `kubectl get constraints` |
| Microsoft-hosted agent cannot reach a private cluster | by design | self-hosted agent, Managed DevOps Pools, or `command invoke` |
| Token works but DB auth fails | no `pgaadauth_create_principal` for the identity | `./scripts/db-grant-identities.sh` |

---

## 8. Escalation and contacts

| Situation | Action |
|---|---|
| Service down > 15 min | page the platform lead |
| Data integrity (ledger imbalance) | page the platform lead **and** finance |
| Suspected security incident | do not remediate alone; page security, preserve evidence |
| Azure platform issue | raise a support case; check Service Health first |
| Cost anomaly > 2× baseline | notify the platform lead; do not delete anything yet |

### If you suspect a compromise

1. **Do not delete anything.** Logs and state are evidence.
2. Contain: scale the affected deployment to 0, or apply a deny-all
   NetworkPolicy — do not delete the pod, you lose the forensics.
3. Preserve: `kubectl logs`, `kubectl describe`, a node snapshot if needed.
4. Rotate every credential the workload could reach.
5. Escalate to security. They decide on further action.

```bash
# Containment without destroying evidence
kubectl -n erp scale deploy/erp-api --replicas=0
kubectl -n erp apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: emergency-isolate, namespace: erp }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
```

---

## 9. Interview use

**"Do you have operational experience, or just build experience?"**

This chapter is your answer. Talk through §2 and §3.6.

> I wrote a runbook organised by **symptom**, not by component, because at
> 2 a.m. you know what you are seeing, not what is broken. It starts with a
> fixed first-five-minutes sequence — establish context, check pod status,
> check what changed, check dependencies, check Azure Service Health, and
> communicate — because the most common cause is simply the last deployment,
> and `helm history` answers that in five seconds. Then a decision tree from
> the symptom. The one I would highlight is the general-ledger imbalance
> procedure: that is a severity-0 financial-data incident, the first rule is
> that nobody edits GL rows — the application's database role cannot, and
> neither should an engineer — corrections are new balanced reversing entries,
> and finance is escalated alongside engineering because they own the
> correcting entry. There is also a known-issues table of things that have
> actually bitten me, like the private DNS zone that exists but is not linked
> to the VNet, so it resolves to a public IP and the symptom looks like a
> network timeout.

**"What would you improve about this platform?"**

Be ready with three honest answers:

1. **No real DR test across regions.** Backups are geo-redundant and I have
   tested a restore in-region, but a genuine regional failover with DNS
   cutover has not been rehearsed. That is the gap I would close first,
   because an untested DR plan is a hypothesis.
2. **The change-ticket gate validates format, not approval.** It checks the
   ticket id looks right; it does not call ServiceNow to confirm the change is
   approved and in window. That is a demonstration of the control point rather
   than the control.
3. **No progressive delivery.** Deployments are all-or-nothing rolling
   updates. For an ERP I would add canary or blue-green with automated
   analysis — Argo Rollouts or Flagger — so a bad release affects 5% of
   traffic and rolls back on an error-rate signal rather than on a human
   noticing.

Naming real gaps is a strength. It signals you evaluate your own work.

---

## Checklist

- [ ] **You have rewritten this runbook in your own words**
- [ ] You can recite the first-five-minutes sequence from memory
- [ ] You can walk the decision tree without the document
- [ ] You know exit codes 137 and 143
- [ ] You know `--previous` for crashed-container logs
- [ ] You know the four distinct DB failure signatures and their fixes
- [ ] You can explain the ledger-imbalance procedure and why nobody edits GL rows
- [ ] You have actually run a rollback
- [ ] You have actually run a restore
- [ ] You can name three honest improvements to the platform

Next: [chapter 15 — Interview preparation](15-interview-prep.md)
