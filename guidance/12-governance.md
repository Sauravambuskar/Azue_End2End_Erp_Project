# 12 — Governance: Azure Policy, Defender for Cloud, compliance

**Time:** 3 hours · **Cost:** Policy is free; Defender plans cost per resource
**Prerequisite:** chapters 02 and 05 complete

Governance is the difference between a secure platform and a platform that was
secure on the day it was built. Policy makes the configuration *stay* right.

---

## 1. Azure Policy — the mental model

```
Definition   the rule:  "storage accounts must not allow public access"
     │
Initiative   a bundle of definitions, assigned as one unit
     │
Assignment   where it applies (management group / subscription / RG)
             + parameters + effect + exclusions
     │
Evaluation   new resources: at the control plane, INSTANTLY
             existing resources: a compliance scan, up to 30 minutes
```

### The effects, and when to use each

| Effect | What happens | Use for |
|---|---|---|
| **Audit** | records non-compliance, allows it | discovering an existing estate before you block |
| **Deny** | request rejected at the control plane | the rules that must never be broken |
| **Modify** | adds/changes a property on create or update | adding missing tags automatically |
| **Append** | adds a property to the request | legacy; prefer Modify |
| **DeployIfNotExists** (DINE) | deploys a missing resource | turning on diagnostic settings everywhere |
| **AuditIfNotExists** (AINE) | audits when a related resource is missing | "every VM should have the agent" |
| **Disabled** | off | temporarily parking a policy |

**`enforcementMode = DoNotEnforce` is the one people forget.** It evaluates a
Deny policy and reports what *would* have been blocked, without blocking. That
is the safest possible way to introduce a Deny to an existing estate.

> **The rollout pattern to describe:** Audit everywhere → fix the backlog →
> assign Deny with `DoNotEnforce` → confirm nothing legitimate is caught →
> switch to enforced Deny. Going straight to Deny breaks every deployment on
> Monday morning, and then the policy gets removed instead of the resources
> getting fixed.

---

## 2. Built-in first, custom only when necessary

**Reach for built-ins.** There are over 1,000, and writing a custom definition
that duplicates one is maintenance debt you have volunteered for.

```bash
# Find relevant built-ins before you write anything
az policy definition list --query "[?policyType=='BuiltIn' && contains(displayName,'Kubernetes')].{name:name, display:displayName}" -o table | head -25

az policy definition list --query "[?policyType=='BuiltIn' && contains(displayName,'Key Vault')].{name:name, display:displayName}" -o table | head -20

# The big initiatives
az policy set-definition list --query "[?policyType=='BuiltIn'].{name:name, display:displayName}" -o tsv | grep -iE "cis|benchmark|kubernetes|pci" | head
```

### The built-in initiatives worth assigning

| Initiative | Definition count | Why |
|---|---|---|
| Microsoft cloud security benchmark | ~200 | the default Azure baseline; Defender scores against it |
| CIS Microsoft Azure Foundations Benchmark v2.0 | ~100 | the one auditors ask about |
| Kubernetes cluster pod security **restricted** standards | ~8 | Gatekeeper enforcement of PSA-equivalent rules |
| NIST SP 800-53 Rev. 5 | ~700 | if you have US federal exposure |

### The four custom definitions in this project, and their justification

Read [`policy/definitions/README.md`](../policy/definitions/README.md).

| Custom definition | Why no built-in fits |
|---|---|
| `require-mandatory-tags` | the built-in requires *one* tag; we need a specific set of six |
| `allowed-regions-and-skus` | region + VM size in one policy with our specific lists |
| `deny-public-ip-on-nic` | "no public IP **except** on these three subnets" is organisation-specific |
| `deny-public-network-access` | one policy covering storage + KV + ACR + PostgreSQL together |

> *"I used built-in initiatives for the baseline — the Microsoft cloud
> security benchmark and the CIS benchmark — and wrote four custom definitions
> only where the requirement was genuinely organisation-specific, like our
> exact mandatory tag set. A custom policy that duplicates a built-in is
> something you then have to maintain forever as Azure changes."*

---

## 3. Deploy the governance baseline

```bash
source ~/.erp-lab-env
cd /d/Azure

# Create all four custom definitions at the management group, so every
# subscription below inherits them.
MG=mg-contoso
for f in policy/definitions/*.json; do
  [ "$(basename "$f")" = "README.md" ] && continue
  name="erp-$(basename "$f" .json)"
  echo "creating $name"
  az policy definition create \
    --name "$name" \
    --management-group "$MG" \
    --rules  "$(jq -c .properties.policyRule   "$f")" \
    --params "$(jq -c .properties.parameters   "$f")" \
    --mode   "$(jq -r .properties.mode         "$f")" \
    --display-name "$(jq -r .properties.displayName "$f")" \
    --description  "$(jq -r .properties.description  "$f")" \
    --only-show-errors -o none
done

az policy definition list --management-group "$MG" \
  --query "[?policyType=='Custom'].{name:name, display:displayName}" -o table
```

### Assign them — Audit first

```bash
SCOPE="/subscriptions/${SUB_ID}"

# Tags: start with Audit to see the existing state
az policy assignment create \
  --name "erp-tags-audit" \
  --display-name "ERP - mandatory tags (audit)" \
  --policy "erp-require-mandatory-tags" \
  --scope "$SCOPE" \
  --params '{"effect":{"value":"Audit"}}' \
  --only-show-errors -o none

# Regions and SKUs: Deny immediately - this is a cost guard and nothing
# legitimate is in another region yet
az policy assignment create \
  --name "erp-regions-deny" \
  --display-name "ERP - allowed regions and SKUs" \
  --policy "erp-allowed-regions-and-skus" \
  --scope "$SCOPE" \
  --params '{"allowedLocations":{"value":["centralindia","southindia"]}}' \
  --only-show-errors -o none

# Public network access: Audit in dev (so you can still docker push)
az policy assignment create \
  --name "erp-public-access-audit" \
  --display-name "ERP - data services public access (audit)" \
  --policy "erp-deny-public-network-access" \
  --scope "$SCOPE" \
  --params '{"effect":{"value":"Audit"}}' \
  --only-show-errors -o none
```

### Assign the Kubernetes built-in

```bash
AKS_RG=$(cd infra/terraform/envs/dev && terraform output -raw aks_resource_group)

az policy assignment create \
  --name "erp-aks-pod-security" \
  --display-name "ERP - Kubernetes pod security restricted standards" \
  --policy-set-definition "42b8ef37-b724-4e24-bbc8-7a7708edfe00" \
  --scope "/subscriptions/${SUB_ID}/resourceGroups/${AKS_RG}" \
  --params '{"effect":{"value":"audit"},"excludedNamespaces":{"value":["kube-system","gatekeeper-system","calico-system","tigera-operator","azure-arc"]}}' \
  --only-show-errors -o none
```

> **Start Kubernetes policies at `audit`.** A `deny` on a running cluster can
> block the platform's own add-ons from restarting, and then you have an
> outage caused by a security control. Confirm compliance, then switch to deny.

### Check compliance

```bash
# Trigger an on-demand scan (otherwise wait up to 30 minutes)
az policy state trigger-scan --subscription "$SUB_ID" --no-wait

sleep 180

az policy state summarize --subscription "$SUB_ID" \
  --query 'value[0].results' -o json

# What is actually non-compliant?
az policy state list --subscription "$SUB_ID" \
  --filter "complianceState eq 'NonCompliant'" \
  --query "value[].{resource:resourceId, policy:policyDefinitionName}" -o table \
  2>/dev/null | head -20
```

### Gatekeeper on the cluster

```bash
# The constraint templates Azure Policy installed
kubectl get constrainttemplates
kubectl get constraints

# Violations
kubectl get k8sazurev2blockdefault -o json 2>/dev/null | \
  jq -r '.items[]?.status.violations[]? | "\(.kind)/\(.name) in \(.namespace): \(.message)"' | head

# The Gatekeeper pods themselves
kubectl get pods -n gatekeeper-system
```

> **Timing gotcha:** Azure Policy syncs constraints to the cluster roughly
> every 15 minutes, and compliance reports back on a similar cycle. An
> assignment does not take effect instantly on the cluster. If you assign and
> immediately test, you will conclude it does not work.

---

## 4. Microsoft Defender for Cloud

### Free vs paid — be clear about this

| | Free (CSPM foundational) | Paid plans |
|---|---|---|
| Secure Score | yes | yes |
| Recommendations | yes | yes |
| Regulatory compliance dashboard | yes | yes |
| **Runtime threat detection** | no | yes |
| **Vulnerability assessment** | no | yes |
| Attack path analysis | no | yes (Defender CSPM) |

```bash
# What is on?
az security pricing list --query 'value[].{plan:name, tier:pricingTier}' -o table
```

### Which plans matter for this platform, and the cost

| Plan | ~Cost | What it gives you here |
|---|---|---|
| **Defender for Containers** | ~USD 7/vCPU/month | AKS runtime detection, ACR image scanning, K8s hardening |
| **Defender for Open-Source RDBMS** | ~USD 15/server/month | PostgreSQL brute-force and anomalous access detection |
| Defender for Key Vault | ~USD 0.02/10k ops | unusual secret access patterns |
| Defender CSPM | ~USD 5/resource/month | attack path analysis |

```bash
# Enable Containers for the exercise - this is the one worth seeing
az security pricing create --name Containers --tier Standard

# ...and REMEMBER TO TURN IT OFF
# az security pricing create --name Containers --tier Free
```

### Read your Secure Score and work the recommendations

```bash
az security secure-score list --query '[].{name:displayName, current:score.current, max:score.max, pct:score.percentage}' -o table

# Highest-impact unhealthy recommendations first
az security assessment list \
  --query "[?status.code=='Unhealthy'].{name:displayName, severity:metadata.severity, resource:resourceDetails.id}" \
  -o table 2>/dev/null | head -25
```

### The exercise worth doing: remediate three findings, then re-measure

Pick three recommendations and fix them **in Terraform**, not in the portal.

```bash
# BEFORE
az security secure-score list --query '[0].score.percentage' -o tsv
```

Likely findings and the Terraform fix:

| Finding | Fix |
|---|---|
| Key Vault should have purge protection enabled | `key_vault_purge_protection = true` in `envs/dev/main.tf` (already true in `envs/prod`) |
| Container registries should not allow unrestricted network access | `public_network_access = false` + Premium SKU + private endpoint |
| AKS should have Entra ID integration with Azure RBAC | already on — confirm it reports healthy |
| Diagnostic logs should be enabled | already on for everything — confirm |
| AKS clusters should disable command invoke | `run_command_enabled = false` |

```bash
cd infra/terraform/envs/dev
# Flip the posture flags in envs/dev/main.tf, which are the inputs to the
# shared stack. envs/prod already sets all of them to the hardened value.
terraform plan -out=tfplan && terraform apply tfplan

az policy state trigger-scan --subscription "$SUB_ID" --no-wait
sleep 300
# AFTER
az security secure-score list --query '[0].score.percentage' -o tsv
```

> **Why fix it in Terraform rather than the portal:** a portal fix is drift.
> It raises the score today and disappears the next time the resource is
> recreated. Fixing it in the IaC means the fix is permanent, reviewed, and
> applied identically in every environment. *"I treat Defender
> recommendations as a backlog for the Terraform, not a to-do list for the
> portal"* is a strong line.

### Regulatory compliance

**Portal → Defender for Cloud → Regulatory compliance.** Add a standard
(CIS Azure 2.0, ISO 27001, PCI DSS) and you get a control-by-control view of
where you stand.

```bash
az security regulatory-compliance-standards list \
  --query '[].{name:name, state:state, passed:passedControls, failed:failedControls}' -o table
```

For a manufacturing ERP the realistic set is **ISO 27001** plus
**CIS Azure Foundations**, and SOC 2 if the company sells to enterprises.

---

## 5. Drift detection — the governance gap people miss

Policy stops bad *creates*. It does not stop someone changing a resource in
the portal after the fact in a way policy does not cover.

### Three layers of drift detection

**1. Terraform plan on a schedule**

```bash
# Add to the infra pipeline as a nightly scheduled trigger
terraform plan -detailed-exitcode
# exit 0 = no drift, exit 2 = DRIFT DETECTED
```

```yaml
# In azure-pipelines-infra.yml
schedules:
  - cron: "0 1 * * *"
    displayName: Nightly drift detection
    branches: { include: [main] }
    always: true
```

A nightly plan that exits 2 means somebody changed something outside the
pipeline. **That is a security event, not just untidiness** — it means a
change bypassed review.

**2. Azure Activity Log alerts on direct portal changes**

```bash
az monitor activity-log alert create \
  --name "alert-direct-nsg-change" \
  -g "$(cd infra/terraform/envs/dev && terraform output -json resource_groups | jq -r .platform)" \
  --condition category=Administrative and operationName=Microsoft.Network/networkSecurityGroups/securityRules/write \
  --action-group "$(cd infra/terraform/envs/dev && terraform output -raw action_group_id 2>/dev/null)" \
  --description "An NSG rule was changed. If it was not the pipeline, investigate." \
  2>/dev/null || echo "Create via the portal: Monitor > Alerts > Activity log alert"
```

**3. The KQL query that finds human changes**

```kql
AzureActivity
| where TimeGenerated > ago(7d)
| where ActivityStatusValue == "Success"
| where OperationNameValue has_any ("write", "delete", "action")
// Exclude the pipeline's own identity - everything else is a human or
// an unknown automation, and both deserve a look
| where Caller !has "your-name-erp-ContosoERP"
| where Caller !has "aks"
| summarize Changes = count(), Operations = make_set(OperationNameValue, 10)
  by Caller, ResourceGroup
| order by Changes desc
```

> *"Policy prevents bad creates; drift detection catches bad changes. A
> nightly `terraform plan -detailed-exitcode` that returns 2 tells me
> something changed outside the pipeline, which means it bypassed code review
> — so I treat it as a security finding rather than a tidying task."*

---

## 6. Break it on purpose

**Exercise A — watch Deny work at the control plane**

```bash
# Wrong region - the allowed-regions policy should deny this
az group create -n rg-policy-test-fail -l eastus \
  --tags Workload=erp Environment=dev CostCentre=CC-LEARNING-001 \
         Owner="$MY_UPN" DataClass=internal ManagedBy=manual
```

Expected: `RequestDisallowedByPolicy`, naming the assignment and the
definition. Read the whole error — in a real incident that message is how you
identify which policy to look at.

```bash
# Now the right region, but an oversized VM size
az vm create -n vm-policy-test -g rg-erp-dev-cin-platform \
  --image Ubuntu2204 --size Standard_D64s_v5 --generate-ssh-keys 2>&1 | tail -5
```

**Exercise B — flip tags from Audit to Deny and see the difference**

```bash
# Currently Audit: this succeeds but is recorded non-compliant
az group create -n rg-untagged-audit -l centralindia
az policy state trigger-scan -g rg-untagged-audit --no-wait
sleep 120
az policy state list -g rg-untagged-audit \
  --query "value[?complianceState=='NonCompliant'].policyDefinitionName" -o tsv

# Now switch to Deny
az policy assignment update --name "erp-tags-audit" \
  --params '{"effect":{"value":"Deny"}}' -o none
sleep 60

az group create -n rg-untagged-deny -l centralindia   # now REJECTED

az group delete -n rg-untagged-audit --yes --no-wait
```

**Exercise C — Gatekeeper blocking a pod**

```bash
# Switch the Kubernetes policy to deny
az policy assignment update --name "erp-aks-pod-security" \
  --params '{"effect":{"value":"deny"},"excludedNamespaces":{"value":["kube-system","gatekeeper-system","calico-system","tigera-operator","azure-arc"]}}' -o none

echo "Waiting 15 minutes for the constraint to sync to the cluster..."
# Check for it rather than guessing
until kubectl get constraints 2>/dev/null | grep -q .; do sleep 60; echo -n "."; done
kubectl get constraints

# Now try a privileged pod - blocked by Gatekeeper this time, not PSA
kubectl -n erp run gk-test --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"gk-test","image":"busybox","securityContext":{"privileged":true}}]}}' \
  -- sleep 60
```

The error now comes from `gatekeeper-system` / `validation.gatekeeper.sh`
rather than `PodSecurity`. **Two layers, both firing.** Being able to tell
which one blocked you from the error text is a genuinely useful skill.

**Exercise D — prove an exemption is auditable**

```bash
# Sometimes a resource legitimately cannot comply. The right answer is an
# exemption with an expiry and a reason - not deleting the assignment.
az policy exemption create \
  --name "erp-legacy-exemption" \
  --policy-assignment "/subscriptions/${SUB_ID}/providers/Microsoft.Authorization/policyAssignments/erp-public-access-audit" \
  --exemption-category Waiver \
  --scope "/subscriptions/${SUB_ID}/resourceGroups/rg-erp-dev-cin-platform" \
  --expires-on "$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%SZ)" \
  --description "Dev ACR must stay public so images can be pushed from a laptop without a VPN. Reviewed by platform team. Expires in 30 days."

az policy exemption list --query '[].{name:name, category:exemptionCategory, expires:expiresOn}' -o table
```

> **Exemptions beat deleting assignments.** An exemption is scoped, has a
> category (Waiver or Mitigated), carries a reason and **expires**. Deleting an
> assignment is invisible and permanent. *"When something genuinely cannot
> comply, I write a time-bound exemption with a justification rather than
> weakening the policy, because the exemption shows up in the compliance
> report and comes back for review."*

---

## 7. Interview answers this chapter gives you

**"How do you enforce governance across subscriptions?"**

> Azure Policy assigned at the management group so every subscription
> inherits it, which means a new subscription is governed the moment it is
> created rather than after someone remembers to configure it. I use built-in
> initiatives for the baseline — the Microsoft cloud security benchmark and
> the CIS Azure Foundations benchmark — and wrote four custom definitions only
> where the requirement was organisation-specific, like our exact six
> mandatory tags and a "no public IP except on these three subnets" rule. The
> effects are chosen per environment through parameters: public network access
> is Audit at dev, where I still need to push images from a laptop, and Deny at
> prod. And the rollout matters as much as the policy — I start at Audit to
> discover the existing estate, fix the backlog, then assign the Deny with
> `enforcementMode: DoNotEnforce` to see what *would* break, and only then
> enforce. Going straight to Deny breaks every deployment on Monday and the
> policy gets removed instead of the resources getting fixed.

**"Policy versus Defender for Cloud — what is the difference?"**

> Policy is preventive and declarative: it is a rule evaluated at the control
> plane, so a Deny means the non-compliant resource never exists. Defender for
> Cloud is detective and advisory: it assesses what *does* exist, scores it,
> recommends fixes, and with the paid plans adds runtime threat detection —
> anomalous database access, suspicious process execution in a container,
> crypto-mining signatures. They work together: Defender finds that Key Vault
> purge protection is off across the estate, and Policy is how you stop it
> being off on the next one. The habit that matters is that I treat Defender
> recommendations as a backlog for the Terraform, not a to-do list for the
> portal — fixing it in the portal raises the score today and disappears the
> next time the resource is recreated.

**"How do you detect configuration drift?"**

> Three layers. A nightly `terraform plan -detailed-exitcode` in the infra
> pipeline: exit 2 means drift, and I treat that as a security finding rather
> than untidiness, because a change outside the pipeline is a change that
> bypassed code review. Activity Log alerts on the operations that matter most
> — NSG rule writes, role assignment creates, policy assignment changes — so a
> direct portal change pages somebody. And a weekly KQL query over
> `AzureActivity` that filters out the pipeline's service principal, because
> anything left is a human or an automation I do not know about, and both
> deserve a look. Policy prevents bad creates; this is what catches bad
> changes.

**"A resource genuinely cannot meet a policy. What do you do?"**

> A policy exemption, not a weakened policy and definitely not a deleted
> assignment. The exemption is scoped to that resource, has a category —
> Waiver if we are accepting the risk, Mitigated if a compensating control
> exists — carries a written justification, and has an expiry date. That means
> it shows up in the compliance report as a known exception rather than
> silently disappearing from it, and it comes back for review automatically.
> The alternative — loosening the policy for everyone because one resource
> cannot comply — is how a baseline erodes one exception at a time.

---

## Checklist

- [ ] You can explain definition / initiative / assignment / evaluation
- [ ] You know all seven effects and when to use each
- [ ] You know `enforcementMode: DoNotEnforce` and why it matters
- [ ] You can state the Audit → fix → DoNotEnforce → Deny rollout pattern
- [ ] You searched built-ins before writing custom
- [ ] All four custom definitions created at the management group
- [ ] Assignments made: tags (Audit→Deny), regions (Deny), public access (Audit)
- [ ] Kubernetes built-in initiative assigned, started at `audit`
- [ ] Compliance scan triggered and results read
- [ ] Gatekeeper constraints visible on the cluster
- [ ] You know the ~15-minute Policy→cluster sync delay
- [ ] Defender Secure Score read
- [ ] **Three recommendations remediated in Terraform, score re-measured**
- [ ] Regulatory compliance dashboard viewed with a standard added
- [ ] Nightly drift detection added to the infra pipeline
- [ ] You ran the "who changed things outside the pipeline" KQL query
- [ ] All four "break it" exercises done
- [ ] You created a time-bound exemption with a justification
- [ ] **Defender Containers plan turned back to Free if you enabled it**

Next: [chapter 13 — Cost and teardown](13-cost-and-teardown.md)
