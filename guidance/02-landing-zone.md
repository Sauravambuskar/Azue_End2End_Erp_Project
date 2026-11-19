# 02 — Landing zone: management groups, subscriptions, RBAC, naming

**Time:** 3 hours · **Cost:** ₹0 (management groups and policies are free)
**Prerequisite:** chapter 01 complete

This is the chapter that makes you sound senior. Anyone can create an AKS
cluster. Designing the *container* the cluster lives in — the scope hierarchy,
the governance inheritance, the identity model, the naming contract — is the
architect-adjacent work the JD is actually asking for.

---

## 1. What a landing zone actually is

Strip away the marketing: a landing zone is **the pre-built, governed
environment a workload lands into, so the workload team does not have to make
platform decisions.**

Concretely, it answers these questions *before* anyone deploys anything:

| Question | Our answer |
|---|---|
| Which subscription does this go in? | one per environment: dev / test / prod |
| What is it called? | `modules/naming` — one algorithm, no debates |
| What must be tagged? | 6 mandatory tags, Deny policy enforced |
| Who can do what? | Entra groups → Azure roles, never per-user |
| What is the network? | hub-spoke, spoke per workload, forced egress |
| Where do logs go? | one central Log Analytics workspace per environment |
| What is forbidden? | public PaaS endpoints, wrong regions, oversized SKUs |

**The Microsoft reference** is the Azure Landing Zone (ALZ) / Cloud Adoption
Framework "enterprise-scale" architecture. We build a deliberately simplified
version of it — same shape, fewer boxes — because a 40-management-group
hierarchy in a learning subscription teaches you nothing you cannot learn from
six.

---

## 2. The hierarchy we are building

```
Tenant Root Group  (= your tenant id)
│
└── mg-contoso                              ← org root: tenant-wide guardrails
    │                                          (allowed regions, mandatory tags)
    ├── mg-contoso-platform                 ← shared services owned by you
    │   ├── mg-contoso-platform-identity    ←   (domain controllers, Entra Connect)
    │   ├── mg-contoso-platform-management  ←   (Log Analytics, automation)
    │   └── mg-contoso-platform-connectivity ←  (hub VNet, firewall, DNS)
    │
    ├── mg-contoso-landingzones             ← where workloads live
    │   ├── mg-contoso-lz-corp              ←   internal, no public endpoints
    │   │   ├── sub: erp-prod
    │   │   └── sub: erp-test
    │   └── mg-contoso-lz-online            ←   internet-facing workloads
    │
    ├── mg-contoso-sandbox                  ← loose policy, hard spend cap
    │   └── sub: erp-dev
    │
    └── mg-contoso-decommissioned           ← deny-all-new, read-only
```

### Why this shape — be ready to justify each level

- **`mg-contoso` under tenant root, not *at* tenant root.** You never assign
  policy at tenant root if you can avoid it: it hits every subscription
  including ones Microsoft or a partner might add, and you cannot exclude
  anything. One level down gives you an escape hatch.
- **platform vs landing zones split.** Platform subscriptions have different
  policy needs (they legitimately own public IPs — the firewall, the gateway)
  from workload subscriptions (which must not). Same policy set across both
  would force you to riddle it with exemptions.
- **corp vs online.** `corp` denies public endpoints outright. `online` allows
  them but mandates WAF. Our ERP is `corp` with a single controlled ingress.
- **sandbox.** Dev lives here deliberately: you *want* looser policy while
  learning (public ACR so you can `docker push` from a laptop), and you want
  it clearly separated from anything calling itself an environment.
- **decommissioned.** The place you move a subscription to before deleting it.
  A `Deny` on all new resource creation plus `Reader` only. Mentioning this
  level in an interview signals you have thought about lifecycle, not just
  creation.

---

## 3. Subscription strategy

**Decision: one subscription per environment.**

| Driver | Why it points to subscription-per-env |
|---|---|
| Blast radius | a bad `terraform destroy` cannot reach prod |
| RBAC | dev Contributor ≠ prod Contributor, with no scope gymnastics |
| Quota | dev cannot consume prod's vCPU quota |
| Cost | clean per-environment chargeback with no tag discipline required |
| Policy | different effects per env (Audit in dev, Deny in prod) by inheritance |

**The alternative** — one subscription, resource-group-per-environment — is
cheaper to set up and is what you will often find in smaller shops. Be able to
state the trade-off: it is fine until the first incident where a dev change
exhausts a shared quota or a mis-scoped role assignment grants prod access.

> **In a trial account you only have one subscription.** That is fine. Build
> the management group hierarchy for real, place your single subscription under
> `mg-contoso-sandbox`, and be able to explain where the other two *would* go.
> In the interview say exactly that: *"In the lab I had one subscription so I
> modelled dev under sandbox; the hierarchy and the policy assignments are
> built for three."*

### Create the hierarchy

```bash
source ~/.erp-lab-env
./scripts/create-management-groups.sh
```

Or by hand, so you see what it does:

```bash
# Root of our org, directly under the tenant root group
az account management-group create \
  --name mg-contoso --display-name "Contoso" \
  --parent "$TENANT_ID"

# Tier 1
for mg in platform landingzones sandbox decommissioned; do
  az account management-group create \
    --name "mg-contoso-${mg}" \
    --display-name "Contoso ${mg}" \
    --parent mg-contoso
done

# Tier 2 — platform
for mg in identity management connectivity; do
  az account management-group create \
    --name "mg-contoso-platform-${mg}" \
    --display-name "Platform ${mg}" \
    --parent mg-contoso-platform
done

# Tier 2 — landing zones
az account management-group create --name mg-contoso-lz-corp \
  --display-name "Corp landing zones" --parent mg-contoso-landingzones
az account management-group create --name mg-contoso-lz-online \
  --display-name "Online landing zones" --parent mg-contoso-landingzones

# Move your subscription into sandbox
az account management-group subscription add \
  --name mg-contoso-sandbox --subscription "$SUB_ID"
```

### Verify

```bash
# The whole tree
az account management-group list --query '[].{name:name, parent:parent.name}' -o table

# Where did my subscription land?
az account management-group show --name mg-contoso-sandbox --expand --recurse \
  --query 'children[].{type:type, name:displayName}' -o table
```

> **Propagation is slow.** Management group changes can take 5–15 minutes to
> appear everywhere, and policy evaluation up to 30 minutes. If something looks
> wrong, wait before debugging.

---

## 4. Resource group design

Within each subscription, our ERP uses **four resource groups split by
lifecycle**:

| RG | Contents | Lifecycle |
|---|---|---|
| `rg-erp-dev-cin-network` | VNets, NSGs, private DNS zones, route tables | changes rarely; deleted last |
| `rg-erp-dev-cin-platform` | ACR, Key Vault, Log Analytics, App Insights, managed identities | survives cluster rebuilds |
| `rg-erp-dev-cin-aks` | the AKS cluster and its identities | **rebuilt most often** |
| `rg-erp-dev-cin-data` | PostgreSQL, Cosmos | **never casually deleted** |

The reasoning is the thing to remember: *if two resources have different
lifecycles, they belong in different resource groups.* The test is "could I
delete this whole RG on a Friday afternoon?" — you can for `aks`, you
absolutely cannot for `data`.

There is also an **implicit fifth** RG that AKS creates and owns:
`rg-erp-dev-cin-aks-nodes`. It holds the VMSS, node disks, load balancers and
node NICs. You do not manage it, you do not put things in it, and deleting it
by hand breaks the cluster. Knowing it exists — and that it is why a
`LoadBalancer` Service can leave an orphaned public IP behind after a sloppy
teardown — is a good detail to drop.

---

## 5. Naming and tagging — the contract

Look at [`infra/terraform/modules/naming/main.tf`](../infra/terraform/modules/naming/main.tf).

### Pattern

```
<type>-<workload>-<env>-<region-short>[-<instance>]

aks-erp-dev-cin-01
psql-erp-dev-cin-01
rg-erp-dev-cin-platform
kv-erp-dev-a1b2c3          ← globally unique, so a hash suffix
acrerpdeva1b2c3            ← ACR allows no hyphens at all
```

Three rules that cause real pain if you get them wrong:

1. **Some names are globally unique** (storage, ACR, Key Vault, public DNS
   labels). The module derives a stable 6-char hash from the subscription id,
   so the name is unique *and* reproducible — re-running Terraform does not
   generate a new name.
2. **Some names have restricted character sets.** ACR and storage are
   alphanumeric only; Key Vault is 3–24 chars. The module strips hyphens and
   truncates for exactly those.
3. **Some names are fixed by Azure and you cannot choose them.**
   `AzureFirewallSubnet`, `AzureBastionSubnet`, `GatewaySubnet`. Get these
   wrong and the service simply refuses to deploy.

### Tags

```hcl
Workload     = "erp"
Environment  = "dev"
CostCentre   = "CC-LEARNING-001"
Owner        = "you@example.com"
DataClass    = "internal"
ManagedBy    = "terraform"
Repo         = "https://dev.azure.com/..."
BusinessUnit = "manufacturing"
ReviewDate   = "2027-01-01"
```

The first six are **mandatory and enforced by a Deny policy**
([`policy/definitions/require-mandatory-tags.json`](../policy/definitions/require-mandatory-tags.json)).

> **This is the point worth making in an interview:** a tagging *standard*
> that is documented in Confluence is a suggestion. A tagging standard where
> the module produces the tags and a `Deny` policy rejects anything missing
> them is a *control*. The naming module and the policy are two halves of one
> mechanism — that pairing is the answer to "how do you enforce standards?"

`ReviewDate` is the one people do not think of: it forces a periodic
re-confirmation of ownership, which is how you stop a platform accumulating
resources whose owner left the company.

---

## 6. The RBAC model

**Three rules, no exceptions:**

1. **Assign roles to groups, never to users.** A user-level assignment is
   invisible in six months and survives the person leaving.
2. **Assign the narrowest built-in role that works.** Write a custom role only
   when no built-in fits, and document why.
3. **Assign at the narrowest scope that works.** Resource group over
   subscription; subscription over management group.

### The groups

```bash
source ~/.erp-lab-env

create_group() {
  az ad group create --display-name "$1" --mail-nickname "$1" \
    --description "$2" --query id -o tsv
}

PLATFORM_ADMINS=$(create_group "grp-erp-platform-admins" "Own the ERP landing zone")
DEVELOPERS=$(create_group     "grp-erp-developers"      "ERP application developers")
SRE=$(create_group            "grp-erp-sre"             "ERP on-call and operations")
SECURITY=$(create_group       "grp-erp-security"        "Security review and audit")
DBA=$(create_group            "grp-erp-dba"             "ERP database administration")

# Add yourself to the admin group (you are the platform engineer)
az ad group member add --group "grp-erp-platform-admins" --member-id "$MY_OID"

cat >> ~/.erp-lab-env <<EOF
export GRP_PLATFORM_ADMINS="$PLATFORM_ADMINS"
export GRP_DEVELOPERS="$DEVELOPERS"
export GRP_SRE="$SRE"
export GRP_SECURITY="$SECURITY"
export GRP_DBA="$DBA"
EOF
```

### The assignment matrix

| Group | Role | Scope | Why exactly this |
|---|---|---|---|
| platform-admins | Contributor | `mg-contoso-sandbox` | builds the landing zone; **not Owner** — cannot grant roles |
| platform-admins | User Access Administrator | `rg-*-platform` | can grant roles only within platform RGs |
| developers | Reader | subscription | can look at everything, change nothing |
| developers | AKS RBAC Writer | the AKS cluster | deploy to their namespace, via Kubernetes RBAC |
| developers | AcrPull | ACR | pull images locally; **not AcrPush** — only CI pushes |
| sre | Contributor | `rg-*-aks` | can fix the cluster at 3 a.m. |
| sre | AKS RBAC Admin | the AKS cluster | full in-cluster rights incl. exec |
| sre | Monitoring Contributor | subscription | create alerts and workbooks |
| security | Security Reader | subscription | read Defender findings |
| security | Reader | subscription | read config, **no secret access** |
| dba | Contributor | `rg-*-data` | manage the database only |
| CI service principal | Contributor | `rg-*` (per env) | Terraform applies |
| CI service principal | AKS RBAC Writer + Cluster User | the cluster | `helm upgrade`; **cannot change cluster config** |

```bash
source ~/.erp-lab-env
SCOPE_SUB="/subscriptions/${SUB_ID}"

assign() {  # assign <group-object-id> <role> <scope>
  az role assignment create \
    --assignee-object-id "$1" --assignee-principal-type Group \
    --role "$2" --scope "$3" --only-show-errors -o none \
    && echo "  granted '$2' to group at $3"
}

assign "$GRP_PLATFORM_ADMINS" "Contributor" \
  "/providers/Microsoft.Management/managementGroups/mg-contoso-sandbox"
assign "$GRP_DEVELOPERS" "Reader"                  "$SCOPE_SUB"
assign "$GRP_SECURITY"   "Security Reader"         "$SCOPE_SUB"
assign "$GRP_SRE"        "Monitoring Contributor"  "$SCOPE_SUB"
```

The resource-group-scoped ones come later, after Terraform has created the RGs
— chapter 05 wires them through `var.group_role_assignments`.

### Verify

```bash
# Everything assigned in this subscription, with the principal type
az role assignment list --all --include-inherited \
  --query '[].{principal:principalName, type:principalType, role:roleDefinitionName, scope:scope}' \
  -o table

# The red flag check: any assignment directly to a USER?
az role assignment list --all \
  --query "[?principalType=='User'].{who:principalName, role:roleDefinitionName, scope:scope}" \
  -o table
```

That second query should return only your own bootstrap assignments. In a real
tenant, any row there is a finding.

---

## 7. Deploy the first Terraform

### How the Terraform is laid out, and why

```
infra/terraform/
  modules/              11 single-purpose modules: network, aks, postgres, ...
  stacks/erp-platform/  the whole platform composed as ONE unit
  envs/dev/             a THIN root module: backend + provider + values
  envs/prod/            a THIN root module: backend + provider + values
```

The `stacks/` layer is the part worth understanding. The naive approach is a
full root module per environment — and then `envs/dev/main.tf` and
`envs/prod/main.tf` are 400 near-identical lines that **drift**. Somebody
fixes something in dev and forgets prod, and the environment you actually care
about is running the older code.

With a stack, dev and prod are provably the same architecture and differ only
in the values they pass in. Compare the two root modules side by side — they
are about 80 lines each, and every difference is a security or cost decision
you can point at:

```bash
diff infra/terraform/envs/dev/main.tf infra/terraform/envs/prod/main.tf
```

See [`envs/prod/README.md`](../infra/terraform/envs/prod/README.md) for the
full delta table.

> **Interview answer:** *"How do you manage multiple environments in
> Terraform?"* — A shared composition module called by thin per-environment
> root modules, each with its own state file and backend key. Not workspaces:
> workspaces share one configuration and one backend, so a `terraform
> workspace select` mistake applies dev's plan to prod, and you cannot give
> environments different RBAC on their state. Separate root modules give you
> separate state, separate backend permissions, and a reviewable diff of
> exactly what differs between environments.

### Apply it

This creates the resource groups, network, monitoring and platform services —
no AKS yet.

```bash
# One-time: create the remote state backend
./scripts/bootstrap-tfstate.sh

cd infra/terraform/envs/dev
cp terraform.tfvars.example terraform.tfvars

# Fill it in
source ~/.erp-lab-env
MY_IP=$(curl -s https://api.ipify.org)
cat > terraform.tfvars <<EOF
location    = "${LOCATION}"
owner_email = "${MY_UPN}"
cost_centre = "CC-LEARNING-001"

my_public_ip = "${MY_IP}"

db_aad_admin_object_id      = "${MY_OID}"
db_aad_admin_principal_name = "${MY_UPN}"
db_aad_admin_principal_type = "User"

aks_admin_group_object_ids = ["${GRP_PLATFORM_ADMINS}"]

enable_appgw    = false
enable_firewall = false
enable_cosmos   = false

node_vm_size       = "Standard_D2s_v5"
availability_zones = ["1"]
acr_sku            = "Basic"
postgres_sku       = "B_Standard_B1ms"
log_daily_quota_gb = 1
EOF

export ARM_USE_AZUREAD=true
export TF_VAR_postgres_admin_password="$(openssl rand -base64 24)"

terraform init -backend-config=backend.hcl
terraform plan -out=tfplan

# READ THE PLAN. Every time. This is the habit that prevents incidents.
terraform show tfplan | head -80

terraform apply tfplan
```

> **Expect this to take 20–30 minutes**, dominated by AKS (~10 min) and
> PostgreSQL (~10 min).
>
> **Expect to run `apply` twice the first time.** The identity module
> federates against the AKS OIDC issuer URL, which does not exist until the
> cluster does. Terraform's graph handles the dependency, but if you hit an
> error about an empty issuer URL, just apply again. This is a genuine
> ordering wrinkle worth mentioning in an interview as an example of a
> real-world IaC dependency problem.

### Verify

```bash
terraform output
terraform output -json workload_identity_client_ids | jq

az resource list \
  --query "[?tags.Workload=='erp'].{name:name, type:type, rg:resourceGroup}" \
  -o table
```

---

## 8. Break it on purpose

**Exercise A — prove the tag policy works**

Assign the mandatory-tags policy, then try to create an untagged resource.

```bash
source ~/.erp-lab-env
cd /d/Azure

# Create the definition at the management group
az policy definition create \
  --name "erp-require-mandatory-tags" \
  --management-group mg-contoso \
  --rules  "$(jq -c .properties.policyRule   policy/definitions/require-mandatory-tags.json)" \
  --params "$(jq -c .properties.parameters   policy/definitions/require-mandatory-tags.json)" \
  --mode   "$(jq -r .properties.mode         policy/definitions/require-mandatory-tags.json)" \
  --display-name "ERP - Require mandatory governance tags"

# Assign it to your subscription with Deny
az policy assignment create \
  --name "erp-require-tags" \
  --policy "erp-require-mandatory-tags" \
  --scope "/subscriptions/${SUB_ID}" \
  --params '{"effect":{"value":"Deny"}}'

sleep 60   # give it a minute to take effect

# Now try to create something untagged
az group create -n rg-should-fail -l "$LOCATION"
```

Expected: **`RequestDisallowedByPolicy`**, naming the assignment. Read the
whole error — it tells you which policy blocked you, which is what you want
in a real incident.

Now do it correctly:

```bash
az group create -n rg-should-pass -l "$LOCATION" \
  --tags Workload=erp Environment=dev CostCentre=CC-LEARNING-001 \
         Owner="$MY_UPN" DataClass=internal ManagedBy=manual

az group delete -n rg-should-pass --yes --no-wait
```

**Exercise B — scope inheritance**

```bash
# Where does this assignment actually apply?
az policy assignment list --scope "/subscriptions/${SUB_ID}" \
  --query '[].{name:name, scope:scope, enforcement:enforcementMode}' -o table

# Now move the assignment UP to the management group and see it inherit
az policy assignment delete --name erp-require-tags --scope "/subscriptions/${SUB_ID}"
az policy assignment create --name "erp-require-tags" \
  --policy "erp-require-mandatory-tags" \
  --scope "/providers/Microsoft.Management/managementGroups/mg-contoso" \
  --params '{"effect":{"value":"Deny"}}'

# The subscription now sees it as INHERITED, not assigned
az policy assignment list --scope "/subscriptions/${SUB_ID}" --disable-scope-strict-match \
  --query '[].{name:name, scope:scope}' -o table
```

That `--disable-scope-strict-match` flag is the one that shows you inherited
assignments. Remembering it saves you ten confused minutes one day.

**Exercise C — enforcementMode, the safe way to roll out a Deny**

```bash
# DoNotEnforce = evaluate and report, but do not block.
# This is how you introduce a Deny policy to an existing estate without
# breaking every deployment on Monday morning.
az policy assignment create --name "erp-tags-dryrun" \
  --policy "erp-require-mandatory-tags" \
  --scope "/subscriptions/${SUB_ID}" \
  --enforcement-mode DoNotEnforce \
  --params '{"effect":{"value":"Deny"}}'
```

---

## 9. Bicep: the same thing, the other way

The JD says "Terraform **and/or** Bicep". You should be able to speak to both.

Look at [`infra/bicep/landing-zone.bicep`](../infra/bicep/landing-zone.bicep)
and deploy it to a throwaway RG:

```bash
az deployment sub create \
  --location "$LOCATION" \
  --template-file infra/bicep/landing-zone.bicep \
  --parameters workload=erp env=sandbox location="$LOCATION" \
  --parameters ownerEmail="$MY_UPN" \
  --name bicep-lz-test
```

### The honest comparison

| | Terraform | Bicep |
|---|---|---|
| State | external state file; you own it, it can drift or be corrupted | stateless — Azure Resource Manager *is* the state |
| Multi-cloud | yes | Azure only |
| Day-1 Azure feature support | lags by days to weeks (provider release) | same day (it is ARM) |
| Preview/`apply` safety | `plan` is excellent and trusted | `what-if` is good but less precise on nested props |
| Modules | mature registry, versioned | registry exists, smaller |
| Deleting a resource you removed from code | handled by state diff | needs `--mode Complete`, which is sharp-edged |
| Secrets | **land in state** — state must be treated as secret | never persisted by ARM |

**The answer to "which would you choose?"**

> For this platform I used Terraform, for two reasons specific to the context:
> the team already had Terraform skills, and the plan/approve/apply-the-saved-
> plan flow gives a strong change-control story, which matters when the same
> pipeline can delete a production database. Bicep is genuinely better in two
> situations: when you need a brand-new Azure feature on day one, and when you
> do not want state management at all — ARM already knows the desired state,
> and nothing sensitive is persisted. For a pure-Azure shop with no existing
> Terraform investment I would seriously consider Bicep, and I would not call
> it a downgrade.

That answer works because it names a trade-off in both directions. Saying
"Terraform because multi-cloud" to a question about an all-Azure platform is a
weaker answer than it sounds.

---

## 10. Interview answers this chapter gives you

**"Walk me through how you would design a landing zone for a new workload."**

> I start with the four questions that are expensive to change later:
> subscription boundary, network address space, identity model, and governance
> inheritance. Subscription first — one per environment, because that is the
> blast radius and quota boundary. Then where it sits in the management group
> hierarchy, because that determines which policies it inherits; an internal
> workload goes under corp, which denies public PaaS endpoints. Then the IP
> plan — I allocate a /16 per spoke from a documented range so peering never
> collides, and I size the AKS subnets for the maximum node count, not the
> current one, because you cannot resize a subnet in use. Then the identity
> model: groups mapped to roles, workload identities per component, and no
> standing human access to production. Only after that do I create resources,
> and they come from a naming module so every name and tag is derived rather
> than typed.

**"How do you enforce standards across many teams?"**

> Make the compliant path the easy path, then make the non-compliant path
> impossible. The easy path is a shared module: a team calls the naming module
> and gets correct names and tags for free. The impossible path is Azure
> Policy: mandatory tags are a Deny, allowed regions are a Deny, public
> endpoints on data services are a Deny at prod. And then shared pipeline
> templates, so a new team gets the SAST, SCA, secret scanning and container
> scanning gates by referencing one template rather than reimplementing them —
> and when we tighten a gate, every team gets it on their next run.

**"What is the difference between Deny and Audit, and when would you use
each?"**

> Deny blocks at the control plane, so a non-compliant resource never exists.
> Audit records non-compliance and lets it through. You use Audit to discover
> the shape of an existing estate before you start blocking — otherwise you
> break every deployment on day one. The pattern I use is Audit everywhere
> first, fix the backlog, then flip to Deny for new resources. And there is a
> third option people forget: assign the Deny policy with `enforcementMode =
> DoNotEnforce`, which evaluates the Deny logic and reports what *would* have
> been blocked without blocking it. That is the safest possible rollout.

**"A developer says they cannot deploy. How do you debug the permissions?"**

> First, which operation and at what scope — the error message names both.
> Then `az role assignment list --all --include-inherited --assignee <them>`
> to see effective permissions including inherited ones. Three things catch
> people: the role is assigned at the wrong scope, the role is right but the
> *data plane* needs a separate role — Key Vault Secrets User is not implied
> by Contributor, and neither is Storage Blob Data Contributor — or there is a
> Deny assignment or policy blocking it, which no amount of role granting will
> fix. For AKS specifically there is a fourth: they have the Azure role but
> not the in-cluster Kubernetes RBAC binding, which are two separate systems.

---

## Checklist

- [ ] Management group hierarchy created and visible
- [ ] Subscription placed under `mg-contoso-sandbox`
- [ ] Five Entra groups created, you are in platform-admins
- [ ] Role assignments made to **groups**, verified with `az role assignment list`
- [ ] No role assigned directly to a user (except your bootstrap)
- [ ] Terraform state backend bootstrapped
- [ ] `terraform apply` succeeded; `terraform output` shows your resources
- [ ] Tag policy assigned and **you have seen `RequestDisallowedByPolicy`**
- [ ] You understand inherited vs assigned (`--disable-scope-strict-match`)
- [ ] Bicep deployment tried; you can state the trade-off in both directions
- [ ] You can draw the hierarchy from memory and justify each level

Next: [chapter 03 — Networking](03-networking.md)
