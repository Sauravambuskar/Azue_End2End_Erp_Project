# KQL cheatsheet

> **The three to memorise** are marked ★. Be able to write those from blank at
> a whiteboard.

---

## The shape of every query

```kql
TableName                        // 1. source
| where TimeGenerated > ago(1h)  // 2. TIME FILTER FIRST, always
| where <narrowing filters>      // 3. then other filters
| extend Computed = ...          // 4. derive columns
| summarize agg() by dim, bin(TimeGenerated, 5m)
| order by X desc
| take 50
```

**Why time first:** the time filter is what lets the engine skip whole
partitions. Filter on anything else first and the query can scan the full
retention window. Say this out loud if you are writing KQL in front of someone.

---

## Operators you need

| Operator | Does | Note |
|---|---|---|
| `where` | filter | |
| `project` | select columns | `project-away` to drop |
| `extend` | add computed columns | |
| `summarize ... by ...` | aggregate | |
| `bin(col, 5m)` | bucket into time windows | the basis of all time series |
| `ago(1h)` / `between()` | relative time | `1m 1h 1d 7d 30d` |
| `has` | **whole-token** match, indexed, **fast** | prefer this |
| `contains` | substring, **slow** | avoid on big tables |
| `has_any ("a","b")` | any of several tokens | |
| `parse_json()` | parse a JSON string | for structured logs |
| `tostring/toreal/toint/todatetime` | cast | needed after `parse_json` |
| `countif(cond)` | conditional count | error-rate workhorse |
| `percentile(col, 95)` | percentile | **always prefer to `avg`** |
| `dcount(col)` | distinct count (approx) | |
| `make_set(col, 10)` | collect distinct values | |
| `join kind=leftouter` | join tables | `inner`, `leftouter`, `leftanti` |
| `union withsource=T *` | query all tables | discovery only, expensive |
| `render timechart` | chart it | for workbooks and dashboards |
| `let x = ...;` | variable | note the semicolon |

> **`has` vs `contains`:** `has` matches whole tokens and uses the index.
> `contains` is a substring scan. On `ContainerLogV2` the difference is
> seconds versus minutes. Using `has` correctly is a small expertise signal.
>
> **`percentile` vs `avg`:** an average hides the tail. If one request in a
> hundred takes 30 seconds, the average barely moves and your users are
> furious. Always report p95/p99.

---

## ★ 1. Error rate and latency over time

```kql
AppRequests
| where TimeGenerated > ago(1h)
| summarize
    Total  = count(),
    Failed = countif(Success == false),
    P50    = percentile(DurationMs, 50),
    P95    = percentile(DurationMs, 95),
    P99    = percentile(DurationMs, 99)
  by bin(TimeGenerated, 5m)
| extend ErrorRatePct = round(100.0 * Failed / Total, 2)
| order by TimeGenerated desc
```

## ★ 2. Who changed something in the cluster

```kql
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where Category == "kube-audit-admin"
| extend A = parse_json(log_s)
| extend Verb = tostring(A.verb),
         User = tostring(A.user.username),
         Res  = tostring(A.objectRef.resource),
         Name = tostring(A.objectRef.name),
         Ns   = tostring(A.objectRef.namespace)
| where Verb in ("delete", "create", "update", "patch")
| project TimeGenerated, User, Verb, Res, Name, Ns
| order by TimeGenerated desc
```

## ★ 3. Parse a business event out of structured logs

```kql
ContainerLogV2
| where TimeGenerated > ago(7d)
| where PodNamespace == "erp"
| where LogMessage has "ReorderPointBreached"
| extend P = parse_json(LogMessage)
| extend Sku     = tostring(P.sku),
         OnHand  = toreal(P.on_hand),
         Reorder = toreal(P.reorder_point)
| extend Shortfall = Reorder - OnHand
| summarize Breaches = count(), WorstShortfall = max(Shortfall) by Sku
| order by WorstShortfall desc
```

---

## Application Insights

```kql
// Slowest endpoints, ranked by TOTAL time consumed - the honest ranking.
// A 2-second endpoint called twice a day matters less than a 300ms one
// called 50,000 times.
AppRequests
| where TimeGenerated > ago(24h)
| summarize Calls = count(), P95 = percentile(DurationMs, 95),
            Errors = countif(Success == false)
  by Name
| extend TotalSeconds = round(Calls * P95 / 1000.0, 1)
| order by TotalSeconds desc
| take 15
```

```kql
// Exceptions grouped by type
AppExceptions
| where TimeGenerated > ago(24h)
| summarize Count = count(), Sample = any(OuterMessage), LastSeen = max(TimeGenerated)
  by ProblemId, Type
| order by Count desc
```

```kql
// Where is the time going - app or database?
AppDependencies
| where TimeGenerated > ago(1h)
| summarize Calls = count(), P95 = percentile(DurationMs, 95),
            TotalSec = round(sum(DurationMs) / 1000.0, 1)
  by Type, Target, Name
| order by TotalSec desc
| take 20
```

```kql
// N+1 query detection: one request making many identical SQL calls
AppDependencies
| where TimeGenerated > ago(1h) and Type == "SQL"
| summarize SqlCalls = count() by OperationId
| where SqlCalls > 20
| join kind=inner (AppRequests | project OperationId, Name) on OperationId
| summarize Requests = count(), MaxCalls = max(SqlCalls) by Name
| order by MaxCalls desc
```

```kql
// Cross-signal correlation: request + its SQL + its exception
let w = ago(2h);
AppRequests
| where TimeGenerated > w and Success == false
| project OperationId, Name, ResultCode, DurationMs, TimeGenerated
| join kind=leftouter (
    AppDependencies | where TimeGenerated > w and Type == "SQL"
    | summarize SqlCalls = count(), SqlMs = sum(DurationMs) by OperationId
  ) on OperationId
| join kind=leftouter (
    AppExceptions | where TimeGenerated > w
    | summarize Exception = any(OuterMessage) by OperationId
  ) on OperationId
| project TimeGenerated, Name, ResultCode, DurationMs, SqlCalls, SqlMs, Exception
| order by TimeGenerated desc
```

---

## Kubernetes / Container Insights

```kql
// Pod restarts and crash loops
KubePodInventory
| where TimeGenerated > ago(6h) and Namespace == "erp"
| summarize MaxRestarts = max(PodRestartCount), LastSeen = max(TimeGenerated)
  by Name, ContainerStatus
| where MaxRestarts > 0
| order by MaxRestarts desc
```

```kql
// OOMKills specifically
KubePodInventory
| where TimeGenerated > ago(24h)
| where ContainerStatusReason has "OOMKilled"
| project TimeGenerated, Namespace, Name, ContainerStatusReason
| order by TimeGenerated desc
```

```kql
// Memory usage percentiles, for right-sizing requests and limits
Perf
| where TimeGenerated > ago(7d)
| where ObjectName == "K8SContainer" and CounterName == "memoryWorkingSetBytes"
| summarize P50 = percentile(CounterValue, 50) / 1048576,
            P95 = percentile(CounterValue, 95) / 1048576,
            Max = max(CounterValue) / 1048576
  by InstanceName
| order by P95 desc
```

```kql
// Application errors across all containers
ContainerLogV2
| where TimeGenerated > ago(1h) and PodNamespace == "erp"
| where LogMessage has_any ("ERROR", "CRITICAL", "Traceback", "Exception")
| project TimeGenerated, PodName, ContainerName, LogMessage
| order by TimeGenerated desc
| take 50
```

```kql
// Kubernetes warning events
KubeEvents
| where TimeGenerated > ago(2h) and KubeEventType == "Warning"
| summarize Count = count(), Last = max(TimeGenerated) by Reason, Message, Name
| order by Count desc
```

---

## Security and audit

```kql
// Every Key Vault secret read, and by whom
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.KEYVAULT" and Category == "AuditEvent"
| extend Secret = tostring(split(id_s, "/")[-2])
| project TimeGenerated, OperationName, Secret,
          Caller = coalesce(identity_claim_upn_s, identity_claim_appid_g),
          Result = ResultType, CallerIP = CallerIPAddress
| order by TimeGenerated desc
```

```kql
// Anomaly hunt: a caller reading a secret for the first time
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT" and OperationName == "SecretGet"
| summarize FirstSeen = min(TimeGenerated), Reads = count()
  by Caller = coalesce(identity_claim_upn_s, identity_claim_appid_g),
     Secret = tostring(split(id_s, "/")[-2])
| where FirstSeen > ago(24h)
```

```kql
// WAF blocks - what is the firewall stopping?
AzureDiagnostics
| where TimeGenerated > ago(6h)
| where Category == "ApplicationGatewayFirewallLog"
| summarize Blocked = count(), Sample = any(requestUri_s)
  by ruleId_s, Message, action_s, clientIp_s
| order by Blocked desc
```

```kql
// Entra ID authz decisions on the cluster (the guard log)
AzureDiagnostics
| where TimeGenerated > ago(6h) and Category == "guard"
| extend G = parse_json(log_s)
| project TimeGenerated, User = tostring(G.user), Allowed = tostring(G.allowed),
          Reason = tostring(G.reason)
| where Allowed == "false"
| order by TimeGenerated desc
```

```kql
// Human changes in Azure - anything the pipeline did NOT do
AzureActivity
| where TimeGenerated > ago(7d) and ActivityStatusValue == "Success"
| where OperationNameValue has_any ("write", "delete", "action")
| where Caller !has "ContosoERP"          // exclude the pipeline SP
| where Caller !has "aks"                  // exclude cluster identities
| summarize Changes = count(), Ops = make_set(OperationNameValue, 10)
  by Caller, ResourceGroup
| order by Changes desc
```

```kql
// Role assignment changes - privilege escalation watch
AzureActivity
| where TimeGenerated > ago(30d)
| where OperationNameValue has "roleAssignments/write"
| project TimeGenerated, Caller, ResourceGroup, Properties
| order by TimeGenerated desc
```

```kql
// PostgreSQL audit (pgaudit) - who wrote what
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL" and Category == "PostgreSQLLogs"
| where Message has "AUDIT"
| project TimeGenerated, Message
| order by TimeGenerated desc
| take 50
```

```kql
// Failed authentication attempts against the database
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where Message has_any ("authentication failed", "no pg_hba.conf entry")
| summarize Attempts = count(), Sample = any(Message) by bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```

---

## Cost

```kql
// Ingestion by table - run this weekly. The expensive table is always one
// you were not thinking about.
Usage
| where TimeGenerated > ago(7d) and IsBillable == true
| summarize BillableGB = round(sum(Quantity) / 1000, 3) by DataType
| order by BillableGB desc
```

```kql
// Daily trend - catch a spike the day it happens
Usage
| where TimeGenerated > ago(30d) and IsBillable == true
| summarize GB = round(sum(Quantity) / 1000, 3) by bin(TimeGenerated, 1d)
| order by TimeGenerated desc
```

```kql
// Which pod is generating the log volume?
ContainerLogV2
| where TimeGenerated > ago(24h)
| summarize Lines = count(), Bytes = sum(strlen(LogMessage))
  by PodNamespace, PodName
| extend MB = round(Bytes / 1048576.0, 1)
| order by MB desc
| take 20
```

---

## Discovery — when you do not know the table

```kql
// Which tables have data at all?
union withsource=Table *
| where TimeGenerated > ago(1h)
| summarize Rows = count() by Table
| order by Rows desc
```

```kql
// What columns does this table have?
AppRequests
| getschema
```

```kql
// Just show me a row
AppRequests | take 1
```

---

## Running queries from the CLI

```bash
LAW_GUID=$(az monitor log-analytics workspace show \
  --ids "$(terraform output -raw log_analytics_workspace_id)" \
  --query customerId -o tsv)

az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query "$(cat <<'KQL'
AppRequests
| where TimeGenerated > ago(1h)
| summarize Total=count(), Failed=countif(Success==false) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
KQL
)" -o table

# JSON out, for scripting
az monitor log-analytics query --workspace "$LAW_GUID" \
  --analytics-query "AppRequests | summarize count()" -o json | jq '.[0]'
```

---

## Gotchas

| Gotcha | Note |
|---|---|
| Ingestion latency | 2–5 minutes is **normal**. Do not debug a non-problem. |
| `TimeGenerated` is UTC | always. Convert for humans: `datetime_utc_to_local(TimeGenerated, "Asia/Kolkata")` |
| `let` needs a semicolon | `let x = ago(1h);` |
| `join` keeps the left key only with `project` after | be explicit about columns |
| `contains` is slow | use `has` for whole tokens |
| `dcount` is approximate | use `dcount(col, 4)` for higher accuracy, or `count(distinct)` semantics via `summarize by` |
| `AzureDiagnostics` is a catch-all | always filter `ResourceProvider` and `Category` first |
| Case sensitivity | `has`/`contains` are case-**in**sensitive; `has_cs`/`contains_cs` are sensitive |
| Classic vs workspace App Insights | workspace-based uses `AppRequests`; classic used `requests`. Classic is retired. |
