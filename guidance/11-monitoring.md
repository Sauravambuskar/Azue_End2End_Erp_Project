# 11 — Azure Monitor, Log Analytics, App Insights, KQL, alerts, dashboards

**Time:** 4 hours · **Cost:** ~₹1/hour (capped at 1 GB/day ingestion)
**Prerequisite:** chapters 05–06 complete, ERP deployed and receiving traffic

Monitoring is where the JD's "platform observability" lives. The interview
difference is between someone who enabled the AKS monitoring add-on and
someone who can **write a KQL query that answers a business question** and
explain what they chose *not* to alert on.

---

## 1. The telemetry map — know what lands where

```
┌─ Log Analytics Workspace (one per environment) ────────────────────┐
│                                                                    │
│  From AKS (Container Insights add-on):                             │
│    ContainerLogV2       stdout/stderr of every container           │
│    KubePodInventory     pod state, restarts, phase, over time      │
│    KubeNodeInventory    node state and capacity                    │
│    KubeEvents           the same events as `kubectl get events`    │
│    Perf                 CPU/memory/disk per container and node     │
│    InsightsMetrics      Prometheus-style metrics                   │
│                                                                    │
│  From the AKS control plane (diagnostic settings):                 │
│    AzureDiagnostics     kube-apiserver, kube-audit-admin, guard    │
│                                                                    │
│  From PaaS resources (diagnostic settings):                        │
│    AzureDiagnostics     Key Vault AuditEvent, PostgreSQLLogs,      │
│                         ApplicationGatewayFirewallLog, ACR events  │
│                                                                    │
│  From Azure itself:                                                │
│    AzureActivity        who created/changed/deleted what           │
│                                                                    │
│  From Application Insights (workspace-based, so same workspace):   │
│    AppRequests          every HTTP request: duration, result code  │
│    AppDependencies      outbound calls: SQL, HTTP                  │
│    AppExceptions        unhandled exceptions with stack traces     │
│    AppTraces            application log lines                      │
│    AppPerformanceCounters                                          │
└────────────────────────────────────────────────────────────────────┘
```

**Everything in one workspace** is a deliberate choice: it means a single KQL
query can join a WAF block to the API request it would have become and the
database query it would have run. Split workspaces make cross-signal
correlation painful, and correlation is the whole point.

> **The nuance to mention:** one workspace per *environment*, not one for
> everything. Dev log volume should never be able to exhaust the prod
> workspace's quota or dilute prod queries.

### `kube-audit` vs `kube-audit-admin` — a real cost decision

`kube-audit` logs every API call including every `GET` and `LIST`, which on a
busy cluster is enormous — the single largest ingestion source in most AKS
deployments. `kube-audit-admin` logs only the mutating calls: create, update,
patch, delete.

For "who deleted that deployment", `kube-audit-admin` has the same forensic
value at a fraction of the volume. We enable only the admin variant. That is a
good cost-versus-value answer.

---

## 2. Verify telemetry is flowing

```bash
cd infra/terraform/envs/dev
LAW_ID=$(terraform output -raw log_analytics_workspace_id)
LAW_GUID=$(az monitor log-analytics workspace show --ids "$LAW_ID" --query customerId -o tsv)
echo "workspace guid: $LAW_GUID"

# Which tables actually have data?
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  union withsource=Table *
  | where TimeGenerated > ago(1h)
  | summarize Rows = count() by Table
  | order by Rows desc' -o table
```

If `ContainerLogV2` is empty, the Container Insights add-on is not reporting:

```bash
kubectl get pods -n kube-system -l dsName=omsagent
kubectl logs -n kube-system -l dsName=omsagent --tail=30
```

### Generate some traffic to look at

```bash
kubectl -n erp port-forward svc/erp-api 8000:8000 &

# Mixed traffic: successes, 404s, 422s, and a 409
for i in $(seq 1 60); do
  curl -s -o /dev/null http://localhost:8000/api/v1/products
  curl -s -o /dev/null http://localhost:8000/api/v1/customers
  curl -s -o /dev/null http://localhost:8000/api/v1/products/999999        # 404
  curl -s -o /dev/null -X POST http://localhost:8000/api/v1/products \
    -H 'content-type: application/json' -d '{"sku":"bad sku","name":"x","unit_price":"1"}'  # 422
done

# Trigger the worker so the reorder-breach log lines appear
kubectl -n erp create job --from=cronjob/erp-worker worker-manual-$RANDOM
```

> Allow **2–5 minutes** for ingestion latency before querying. Data not
> appearing instantly is normal, not a fault — and knowing the expected
> latency stops you debugging a non-problem.

---

## 3. KQL — the queries that matter

Full set in [`cheatsheets/kql.md`](cheatsheets/kql.md). Learn these six
properly; they cover most real investigations.

### The shape of every KQL query

```kql
TableName                       // 1. source
| where TimeGenerated > ago(1h) // 2. ALWAYS filter time FIRST
| where <other filters>         // 3. then narrow
| extend <computed columns>     // 4. derive
| summarize <aggregation> by <dimension>, bin(TimeGenerated, 5m)
| order by <column> desc
| take 50
```

**Filter on time first.** The time filter is what lets the engine skip whole
partitions. A query that filters on anything else first can scan the entire
retention window.

### 1. Error rate over time

```kql
AppRequests
| where TimeGenerated > ago(4h)
| summarize
    Total   = count(),
    Failed  = countif(Success == false),
    P50     = percentile(DurationMs, 50),
    P95     = percentile(DurationMs, 95),
    P99     = percentile(DurationMs, 99)
  by bin(TimeGenerated, 5m)
| extend ErrorRatePct = round(100.0 * Failed / Total, 2)
| order by TimeGenerated desc
```

### 2. Slowest endpoints — where to spend optimisation effort

```kql
AppRequests
| where TimeGenerated > ago(24h)
| summarize
    Calls  = count(),
    P95    = percentile(DurationMs, 95),
    Errors = countif(Success == false)
  by Name
// Total time is the honest ranking: a 2-second endpoint called twice a day
// matters far less than a 300 ms endpoint called 50,000 times.
| extend TotalSeconds = round(Calls * P95 / 1000.0, 1)
| order by TotalSeconds desc
| take 15
```

### 3. Pod restarts and crash loops

```kql
KubePodInventory
| where TimeGenerated > ago(6h)
| where Namespace == "erp"
| summarize MaxRestarts = max(PodRestartCount), LastSeen = max(TimeGenerated)
  by Name, ContainerStatus
| where MaxRestarts > 0
| order by MaxRestarts desc
```

### 4. The business query — this is the one that impresses

```kql
// Stock reorder breaches over time, parsed out of the worker's structured logs
ContainerLogV2
| where TimeGenerated > ago(7d)
| where PodNamespace == "erp"
| where LogMessage has "ReorderPointBreached"
| extend P = parse_json(LogMessage)
| extend Sku       = tostring(P.sku),
         Warehouse = tostring(P.warehouse),
         OnHand    = toreal(P.on_hand),
         Reorder   = toreal(P.reorder_point)
| extend Shortfall = Reorder - OnHand
| summarize
    Breaches     = count(),
    WorstShortfall = max(Shortfall),
    Warehouses   = make_set(Warehouse)
  by Sku
| order by WorstShortfall desc
```

> **Why this matters so much in an interview:** most candidates show CPU and
> memory charts. Showing a query that answers *"which SKUs are at risk of
> stocking out, worst first"* demonstrates you understand that observability
> exists to serve the business, not to decorate a dashboard. It is the single
> highest-leverage thing in this chapter.

That query works because the worker logs **structured JSON**, which is a
deliberate design choice:

```python
log.warning(json.dumps({
    "event": "ReorderPointBreached",
    "sku": r["sku"],
    "on_hand": str(r["on_hand"]),
}))
```

If it logged `f"Low stock on {sku}"` you would be writing fragile regexes
forever. **Log structured JSON so your logs are queryable data.**

### 5. Who changed the cluster — the audit query

```kql
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where Category == "kube-audit-admin"
| extend A = parse_json(log_s)
| extend Verb  = tostring(A.verb),
         User  = tostring(A.user.username),
         Res   = tostring(A.objectRef.resource),
         Name  = tostring(A.objectRef.name),
         Ns    = tostring(A.objectRef.namespace)
| where Verb in ("delete", "create", "update", "patch")
| where Ns == "erp"
| project TimeGenerated, User, Verb, Res, Name
| order by TimeGenerated desc
```

Plus the Azure control plane:

```kql
AzureActivity
| where TimeGenerated > ago(7d)
| where OperationNameValue has_any ("delete", "write")
| where ActivityStatusValue == "Success"
| project TimeGenerated, Caller, OperationNameValue, ResourceGroup, Resource = _ResourceId
| order by TimeGenerated desc
| take 50
```

### 6. Cross-signal correlation — the query that proves you can join

```kql
// A request, the SQL it ran, and whether it threw — in one result
let window = ago(2h);
AppRequests
| where TimeGenerated > window and Success == false
| project OperationId, Name, ResultCode, DurationMs, TimeGenerated
| join kind=leftouter (
    AppDependencies
    | where TimeGenerated > window and Type == "SQL"
    | summarize SqlCalls = count(), SqlMs = sum(DurationMs) by OperationId
  ) on OperationId
| join kind=leftouter (
    AppExceptions
    | where TimeGenerated > window
    | summarize Exception = any(OuterMessage) by OperationId
  ) on OperationId
| project TimeGenerated, Name, ResultCode, DurationMs, SqlCalls, SqlMs, Exception
| order by TimeGenerated desc
```

`OperationId` is the correlation id the OpenTelemetry SDK propagates
automatically. Our middleware also sets an `X-Request-Id` header that the web
tier forwards to the API, so a single request is traceable across both tiers
and in the Node logs.

### Run queries from the CLI

```bash
az monitor log-analytics query --workspace "$LAW_GUID" \
  --analytics-query "$(cat <<'KQL'
AppRequests
| where TimeGenerated > ago(1h)
| summarize Total=count(), Failed=countif(Success==false) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
KQL
)" -o table
```

---

## 4. Alerts — and what you deliberately do not alert on

Read [`infra/terraform/modules/monitor/main.tf`](../infra/terraform/modules/monitor/main.tf).

### What we alert on, and the severity reasoning

| Alert | Sev | Type | Why this severity |
|---|---|---|---|
| ERP ledger out of balance | **0** | KQL | financial integrity breach; someone wakes up |
| API failed requests > 10 in 5 min | 1 | metric | users are affected now |
| Pod crash-looping (>5 restarts/15 min) | 1 | KQL | service is degrading |
| PostgreSQL storage > 85% | 1 | metric | writes will stop soon; act before they do |
| API p95 latency > 1500 ms | 2 | metric | degraded, not down |
| >10 SKUs below reorder point | 3 | KQL | a business signal, not an incident |

### The alert worth describing in an interview

```hcl
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "ledger_out_of_balance" {
  severity = 0   # critical
  criteria {
    query = <<-KQL
      ContainerLogV2
      | where PodNamespace == "erp"
      | where LogMessage has "LedgerOutOfBalance"
    KQL
  }
}
```

> *"Most platform alerts tell you the infrastructure is unhealthy. This one
> tells you the financial data is wrong, which for an ERP is a far more serious
> event than a pod restarting. The worker runs an integrity check on a schedule
> — debits minus credits must be zero — and exits non-zero if it is not, which
> both fails the CronJob and emits the log line this alert matches. That is
> observability serving the business rather than the platform."*

### What we deliberately do NOT alert on — the more interesting half

| Not alerted | Why |
|---|---|
| Node CPU > 80% | that is the autoscaler's job; alerting on it trains people to ignore alerts |
| Pod restarted once | Kubernetes self-heals; one restart is normal operation |
| Any single 5xx | the threshold is a *rate*, because one error is noise |
| Disk > 70% | too early to act; 85% is when you have time to act but must |
| HPA scaled | that is the system working correctly |

> *"Every alert that does not require a human action is training the on-call
> engineer to ignore alerts. So the test I apply is: if this fires at 3 a.m.,
> is there something a human must do right now? If not, it is a dashboard
> panel or a weekly report, not an alert. Alert fatigue is a bigger
> operational risk than most of the things people alert on."*

### Verify your alerts

```bash
az monitor metrics alert list -g "$(terraform output -json resource_groups | jq -r .platform)" \
  --query '[].{name:name, sev:severity, enabled:enabled}' -o table

az monitor scheduled-query list -g "$(terraform output -json resource_groups | jq -r .platform)" \
  --query '[].{name:name, sev:severity, freq:evaluationFrequency}' -o table

# Did anything fire?
az monitor activity-log alert list -o table
az rest --method get --url "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d" \
  --query "value[].{name:properties.essentials.alertRule, sev:properties.essentials.severity, state:properties.essentials.monitorCondition, fired:properties.essentials.startDateTime}" -o table
```

### Make one fire on purpose

```bash
# Break the ledger integrity check, which should raise the severity-0 alert
kubectl -n erp run psql-admin --rm -it --restart=Never --image=postgres:16-alpine \
  --env="PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)" \
  --command -- psql "host=$(terraform output -raw postgres_fqdn) user=$(az ad signed-in-user show --query userPrincipalName -o tsv) dbname=erp sslmode=require" \
  -c "INSERT INTO gl_entry(batch_id, account_code, debit, credit, description)
      VALUES ('manual-imbalance-test', '9999', 12345, 0, 'Deliberate imbalance to test the sev-0 alert');"

# Force the worker to run and detect it
kubectl -n erp create job --from=cronjob/erp-worker ledger-check-$RANDOM
kubectl -n erp logs -l job-name --tail=20 | grep -i ledger
```

You should see `LedgerOutOfBalance` and the CronJob exit non-zero. Within 15
minutes the alert fires and emails you.

Clean up:

```bash
# ... -c "DELETE FROM gl_entry WHERE batch_id = 'manual-imbalance-test';"
```

---

## 5. Dashboards as code

Read [`infra/terraform/modules/monitor/dashboard.tf`](../infra/terraform/modules/monitor/dashboard.tf).

```bash
terraform output dashboard_id 2>/dev/null || \
  az portal dashboard list -g "$(terraform output -json resource_groups | jq -r .platform)" \
    --query '[].{name:name, title:tags."hidden-title"}' -o table
```

Open it: **Portal → Dashboard → Browse all dashboards → Shared dashboards**.

### Why as code rather than clicking

- it is recreated identically in dev, test and prod
- a change is a reviewed pull request with a diff
- it survives someone deleting it
- it is not lost when the person who built it leaves

> *"'Operational dashboards' in a job description does not mean somebody
> clicked around the portal. It means the JSON is in git, it is reviewed in a
> PR, and every environment gets the same view."*

### The practical way to author one

Hand-writing the portal dashboard JSON is miserable. The workflow that
actually works:

1. Build it in the portal until it is right
2. **Export** it: Dashboard → Share → Export → Download
3. Paste the JSON into Terraform, parameterise the resource ids
4. Delete the hand-made one and let Terraform own it

Being honest about that workflow is better than pretending you wrote the JSON
by hand.

### Workbooks — the better tool for investigation

Dashboards are for a wall. **Workbooks** are for investigation: parameterised,
interactive, with drill-down.

**Portal → Monitor → Workbooks → New.** Build one with a time-range parameter
and these three queries, then save it to the resource group so it is shared:

```kql
// Parameter-driven: {TimeRange} is a workbook parameter
AppRequests
| where TimeGenerated {TimeRange}
| summarize Requests=count(), Failures=countif(Success==false) by bin(TimeGenerated, {TimeRange:grain})
| render timechart
```

---

## 6. Application instrumentation — what the code does

Read [`src/erp-api/app/core/telemetry.py`](../src/erp-api/app/core/telemetry.py)
and the middleware in [`app/main.py`](../src/erp-api/app/main.py).

### Three deliberate choices

**1. OpenTelemetry, not the proprietary SDK.**

```python
from azure.monitor.opentelemetry import configure_azure_monitor
```

The instrumentation is vendor-neutral OTel; only the *exporter* is Azure. If
this platform moved to Grafana or Datadog, you change the exporter, not the
application code. That is a genuinely good architectural answer.

**2. Telemetry failure must never break the application.**

```python
try:
    configure_azure_monitor(...)
except Exception:
    log.exception("Failed to configure Azure Monitor")
```

If App Insights is unreachable or the connection string is wrong, the API
still serves traffic. **Monitoring is not allowed to be a dependency that can
take you down.** People get this wrong surprisingly often.

**3. Structured logs plus a correlation id across tiers.**

```python
format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}'
```

and

```python
request_id = request.headers.get("X-Request-Id", str(uuid.uuid4()))
response.headers["X-Request-Id"] = request_id
```

The web tier generates the id and forwards it; the API echoes it. So one user
action is traceable through the Node logs, the Python logs and App Insights.

### Prometheus endpoint as well

```bash
kubectl -n erp port-forward svc/erp-api 8000:8000 &
curl -s http://localhost:8000/metrics | head -25
```

Why both App Insights *and* a Prometheus endpoint: App Insights is for
application-level tracing and the portal experience; Prometheus is the
Kubernetes-native format that Azure Monitor managed Prometheus and Grafana
scrape. Supporting both means the platform team's Grafana and the application
team's App Insights both work without arguing.

```bash
# Enable managed Prometheus + Grafana (costs a little; optional exercise)
az aks update -g "$AKS_RG" -n "$AKS_NAME" --enable-azure-monitor-metrics
```

---

## 7. Cost control for telemetry — the sneaky bill

Log Analytics is billed per GB ingested. It is the easiest Azure service to
accidentally spend a lot on, because a chatty debug log costs nothing to write
and a lot to store.

```bash
# What is actually consuming the quota?
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  Usage
  | where TimeGenerated > ago(7d)
  | where IsBillable == true
  | summarize BillableGB = round(sum(Quantity) / 1000, 3) by DataType
  | order by BillableGB desc' -o table

# Daily trend - catch a spike early
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
  Usage
  | where TimeGenerated > ago(14d) and IsBillable == true
  | summarize GB = round(sum(Quantity)/1000, 3) by bin(TimeGenerated, 1d)
  | order by TimeGenerated desc' -o table
```

### The five levers, in order of effectiveness

1. **A daily cap.** We set `daily_quota_gb = 1`. Ingestion stops when it is
   hit — you lose data but not money. For a lab that is the right trade.
2. **Do not enable `kube-audit`** (only `kube-audit-admin`). Usually the single
   largest line item.
3. **Sampling** in App Insights. `sampling_percentage = 100` in dev;
   20–50% in prod is normal and statistically fine for rates and percentiles.
4. **Basic Logs** tier for high-volume, low-query-value tables like
   `ContainerLogV2` — roughly 80% cheaper, with the trade-off of 8-day
   retention and no alerts on that table.
5. **Short retention** plus archive. 30 days interactive, then archive for
   compliance at a fraction of the cost.

```bash
# Set the cap (do this now if you have not)
az monitor log-analytics workspace update \
  -g "$(terraform output -json resource_groups | jq -r .platform)" \
  -n "$(terraform output -raw log_analytics_workspace_id | sed 's|.*/||')" \
  --quota 1
```

---

## 8. Break it on purpose

**Exercise A — generate a cost spike and see it in `Usage`**

```bash
# A pod that logs aggressively
kubectl -n erp run logspam --image=busybox --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"logspam","image":"busybox","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["sh","-c","i=0; while [ $i -lt 200000 ]; do echo \"{\\\"msg\\\":\\\"filler line to consume ingestion quota $i\\\"}\"; i=$((i+1)); done"]}]}}'

sleep 120
kubectl -n erp delete pod logspam

# Then query Usage and watch ContainerLogV2 jump
```

**The lesson:** one misbehaving pod can consume a day's quota in minutes. That
is why the cap exists, and it is a good concrete answer to "how do you control
monitoring cost".

**Exercise B — an alert that fires, and a flapping one that teaches you why
thresholds matter**

```bash
# Create a deliberately bad alert: fires on ANY single failed request
az monitor metrics alert create \
  --name "alert-too-sensitive" \
  -g "$(terraform output -json resource_groups | jq -r .platform)" \
  --scopes "$(terraform output -raw app_insights_connection_string >/dev/null; az monitor app-insights component show --app "appi-erp-dev-cin" -g "$(terraform output -json resource_groups | jq -r .platform)" --query id -o tsv)" \
  --condition "count requests/failed > 0" \
  --window-size 1m --evaluation-frequency 1m --severity 1

# Now make a few 404s
for i in $(seq 1 5); do curl -s -o /dev/null http://localhost:8000/api/v1/products/999999; done
```

Watch it fire repeatedly. **That is alert fatigue being manufactured in front
of you.** Delete it and compare with the real alert's threshold of 10 failures
in 5 minutes:

```bash
az monitor metrics alert delete --name "alert-too-sensitive" \
  -g "$(terraform output -json resource_groups | jq -r .platform)"
```

**Exercise C — trace a request end to end**

```bash
RID="trace-test-$(date +%s)"
curl -s -H "X-Request-Id: $RID" http://localhost:3000/bff/products >/dev/null

# Find it in the web tier logs
kubectl -n erp logs -l app.kubernetes.io/component=web --tail=200 | grep "$RID"

# And in the API logs
kubectl -n erp logs -l app.kubernetes.io/component=api --tail=200 | grep "$RID"

# And in App Insights
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query "
  AppRequests
  | where TimeGenerated > ago(15m)
  | where tostring(Properties) has '$RID'
  | project TimeGenerated, Name, ResultCode, DurationMs, OperationId" -o table
```

One id, three systems. That is distributed tracing working, and being able to
demonstrate it is worth more than naming the feature.

---

## 9. Interview answers this chapter gives you

**"How did you set up monitoring?"**

> One Log Analytics workspace per environment as the single sink, so a query
> can correlate across signals. Into it: Container Insights for pod and node
> telemetry and container logs; diagnostic settings on the AKS control plane,
> Key Vault, PostgreSQL, ACR and the Application Gateway; AzureActivity for
> control-plane changes; and workspace-based Application Insights for request
> and dependency tracing. The application is instrumented with
> OpenTelemetry — vendor-neutral instrumentation with an Azure exporter, so
> moving to another backend is an exporter change and not a code change — and
> it also exposes a Prometheus endpoint so managed Prometheus and Grafana work
> too. Logs are structured JSON with a request id generated at the web tier
> and forwarded to the API, so one user action is traceable across both tiers
> and in App Insights. Two deliberate decisions worth naming: telemetry
> configuration is wrapped in a try/except so App Insights being unreachable
> can never take the API down, and I enable `kube-audit-admin` rather than
> `kube-audit` — the mutating calls give the same forensic value as full audit
> at a fraction of the ingestion cost.

**"What do you alert on?"**

> Only things a human must act on. Six alerts. Severity 0 is the ERP general
> ledger failing its integrity check — debits not equal to credits is a
> financial-data problem, not an infrastructure one, and it is the most serious
> thing that can happen in this system. Severity 1 is user-visible: 5xx rate
> above threshold over five minutes, a pod crash-looping, and PostgreSQL
> storage above 85%, which is early enough to act but late enough to be real.
> Severity 2 is p95 latency beyond the SLO. Severity 3 is a business signal —
> more than ten SKUs below reorder point. The more interesting half is what I
> do *not* alert on: node CPU, because that is the autoscaler's job; a single
> pod restart, because Kubernetes self-heals; any individual 5xx, because the
> threshold has to be a rate. The test I apply is: if this fires at 3 a.m., is
> there something a human must do right now? If not it is a dashboard panel or
> a weekly report. Alert fatigue is a bigger operational risk than most of the
> things people alert on.

**"Write me a KQL query that..."** *(be ready for this at a whiteboard)*

Have these three memorised. They cover almost anything they will ask:

```kql
// Error rate with latency percentiles, over time
AppRequests
| where TimeGenerated > ago(1h)
| summarize Total=count(), Failed=countif(Success==false),
            P95=percentile(DurationMs, 95)
  by bin(TimeGenerated, 5m)
| extend ErrorPct = round(100.0*Failed/Total, 2)

// Who deleted something in the cluster
AzureDiagnostics
| where Category == "kube-audit-admin"
| extend A = parse_json(log_s)
| where tostring(A.verb) == "delete"
| project TimeGenerated, User=tostring(A.user.username),
          Resource=tostring(A.objectRef.resource), Name=tostring(A.objectRef.name)

// Parse a business event out of structured container logs
ContainerLogV2
| where PodNamespace == "erp" and LogMessage has "ReorderPointBreached"
| extend P = parse_json(LogMessage)
| summarize Breaches=count() by Sku=tostring(P.sku)
| order by Breaches desc
```

And say this as you write: *"I always put the time filter first, because that
is what lets the engine skip partitions — filtering on anything else first can
scan the whole retention window."*

**"How do you control monitoring costs?"**

> Log Analytics is per-GB ingested and it is the easiest Azure service to
> overspend on, because a chatty log line is free to write and expensive to
> store. Five levers, roughly in order of effect. A hard daily cap — ours is
> 1 GB — so a runaway pod costs you data, not money. Not enabling full
> `kube-audit`, which is usually the single biggest line item, and taking
> `kube-audit-admin` instead. Sampling in App Insights, which at 20–50% is
> statistically fine for rates and percentiles. The Basic Logs tier for
> high-volume, low-query-value tables like container logs, accepting 8-day
> retention and no alerting on that table. And short interactive retention
> with archive for anything kept for compliance. Then I monitor the monitoring:
> a weekly query against the `Usage` table broken down by `DataType`, because
> the thing that gets expensive is always a table you were not thinking about.

---

## Checklist

- [ ] You can name the main tables and what lands in each
- [ ] You can explain `kube-audit` vs `kube-audit-admin` as a cost decision
- [ ] Telemetry verified flowing; you know ingestion lag is 2–5 min
- [ ] You wrote and ran all six KQL queries
- [ ] **You can write the three memorised queries from scratch**
- [ ] You know to filter on time first, and why
- [ ] **You ran the business query** (reorder breaches) and understand why structured JSON logs enable it
- [ ] You can explain the severity-0 ledger alert
- [ ] **You can name five things you deliberately do NOT alert on, with reasons**
- [ ] You made an alert fire on purpose
- [ ] You created a deliberately over-sensitive alert and saw alert fatigue
- [ ] Dashboard viewed; you can explain dashboard-as-code and the export workflow
- [ ] You built one workbook
- [ ] You can explain OTel vs proprietary SDK
- [ ] You can explain why telemetry config is wrapped in try/except
- [ ] You traced one request id across web logs, API logs and App Insights
- [ ] You ran the `Usage` query and know your biggest `DataType`
- [ ] Daily cap confirmed set

Next: [chapter 12 — Governance](12-governance.md)
