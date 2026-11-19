# 08 — Azure DevOps: org, repo, service connections, environments, approvals

**Time:** 3 hours · **Cost:** ₹0 (free tier: 5 users, 1,800 pipeline minutes/month)
**Prerequisite:** chapter 04 complete (you need the identity concepts)

This chapter is the plumbing that chapter 09's pipelines run on. Most of it is
clicking, so the value is in understanding **which setting enforces which
control** — because "we have approvals" is worthless if the approval can be
bypassed.

---

## 1. Create the organisation and project

<https://dev.azure.com> → sign in with the **same Microsoft account** you used
for Azure. That matters: an organisation backed by the same Entra tenant can
use workload identity federation without extra trust configuration.

```
Organisation: your-name-erp
Project:      ContosoERP
Visibility:   Private
Version control: Git
Work item process: Agile
```

Then turn off what you are not using — fewer moving parts, smaller attack
surface:

**Project settings → Overview → Azure DevOps services:** leave Repos,
Pipelines and Environments on. Switch off Boards, Test Plans and Artifacts
unless you want them.

### Install the CLI extension

```bash
az extension add --name azure-devops
az devops configure --defaults organization=https://dev.azure.com/your-name-erp project=ContosoERP

# Verify
az devops project show --project ContosoERP --query '{name:name, id:id}' -o table
```

---

## 2. Push this repository

```bash
cd /d/Azure

# A .gitignore that actually protects you - see section 3
git init -b main
git add -A
git status            # READ THIS. Confirm no .tfvars, no backend.hcl, no .env
git commit -m "Initial commit: ContosoERP Azure DevSecOps platform"

az repos create --name erp-platform --project ContosoERP

git remote add origin https://dev.azure.com/your-name-erp/ContosoERP/_git/erp-platform
git push -u origin main
```

> **Before that first push, run the secret scan.** Once something is in
> history, removing it is painful.
> ```bash
> gitleaks dir . --config security/secrets/gitleaks.toml --redact
> ```

---

## 3. The .gitignore that matters

The repository already has one. Confirm these lines exist, because each
corresponds to a real leak:

```gitignore
# Terraform - state contains SECRETS in plain text
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl   # keep this one in git actually - see note
crash.log

# Variable files - contain IPs, object ids, sometimes passwords
*.tfvars
!*.tfvars.example
backend.hcl
!backend.hcl.example

# Environment files
.env
.env.*
!.env.example

# Kubeconfig - contains cluster credentials
kubeconfig
*.kubeconfig
.kube/

# Certificates and keys
*.pem
*.key
*.pfx
*.p12

# Local python/node
.venv/
venv/
node_modules/
__pycache__/
*.pyc
.pytest_cache/
.ruff_cache/
.mypy_cache/
coverage.xml
junit.xml
.smoke-body.*.json
```

> **Note on `.terraform.lock.hcl`:** this one *should* be committed. It pins
> provider versions and hashes, which is a supply-chain control — it means CI
> uses exactly the providers you tested with. The default template above
> excludes it; our repo's `.gitignore` commits it deliberately.

### Why `*.tfstate` is the critical line

Terraform state stores the **actual values** of everything it manages,
including passwords, connection strings and generated secrets — in plain text,
regardless of whether the output is marked `sensitive`. `sensitive = true`
hides a value from the console; it does not encrypt state.

That is the whole argument for remote state in a storage account with RBAC,
encryption and no shared-key access, which is what
`scripts/bootstrap-tfstate.sh` built.

---

## 4. Service connections with workload identity federation

**This is the part worth doing carefully.** It is where most teams still have
a client secret, and being able to explain the federated alternative is a
differentiator.

### Create it

**Project settings → Service connections → New service connection → Azure
Resource Manager**

Then choose, carefully:

| Field | Choose | Why |
|---|---|---|
| Identity type | **Workload identity federation** | no secret to store or rotate |
| Credential | **Automatic** (recommended) | Azure DevOps creates the app registration and federated credential for you |
| Scope level | **Subscription** | then you narrow with role assignments |
| Resource group | leave blank | scope the *roles*, not the connection |
| Service connection name | `sc-erp-dev-wif` | must match `variables-common.yml` |
| Grant access to all pipelines | **unchecked** | force explicit authorisation per pipeline |

Repeat for `sc-erp-test-wif` and `sc-erp-prod-wif` if you create more
subscriptions.

### Then immediately reduce its permissions

The automatic flow grants **Contributor on the whole subscription**. That is
more than a deploy pipeline needs.

```bash
source ~/.erp-lab-env

# Find the service principal Azure DevOps created
SP_NAME="your-name-erp-ContosoERP-${SUB_ID}"
az ad sp list --display-name "your-name-erp" \
  --query '[].{name:displayName, appId:appId, oid:id}' -o table

SP_OID="<the object id from above>"

# Remove the subscription-wide Contributor
az role assignment delete --assignee-object-id "$SP_OID" \
  --role Contributor --scope "/subscriptions/${SUB_ID}"

# Grant it per resource group instead
for rg in platform data aks network; do
  az role assignment create \
    --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope "/subscriptions/${SUB_ID}/resourceGroups/rg-erp-dev-cin-${rg}" \
    --only-show-errors -o none && echo "Contributor on rg-erp-dev-cin-${rg}"
done

# AKS: deploy-only, cannot change cluster configuration
AKS_ID=$(az aks show -g rg-erp-dev-cin-aks -n aks-erp-dev-cin-01 --query id -o tsv)
az role assignment create --assignee-object-id "$SP_OID" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Kubernetes Service RBAC Writer" --scope "$AKS_ID" -o none
az role assignment create --assignee-object-id "$SP_OID" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Kubernetes Service Cluster User Role" --scope "$AKS_ID" -o none

# ACR: push images
ACR_ID=$(az acr show -n "$(cd infra/terraform/envs/dev && terraform output -raw acr_name)" --query id -o tsv)
az role assignment create --assignee-object-id "$SP_OID" \
  --assignee-principal-type ServicePrincipal \
  --role "AcrPush" --scope "$ACR_ID" -o none

# Terraform state
SA_ID=$(az storage account show -n "$(grep storage_account_name infra/terraform/envs/dev/backend.hcl | cut -d'"' -f2)" \
  -g rg-tfstate-shared --query id -o tsv)
az role assignment create --assignee-object-id "$SP_OID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$SA_ID" -o none
```

**Note what it deliberately does NOT get:**

- `Owner` or `User Access Administrator` — it cannot grant itself more access
- `Key Vault Secrets Officer` on prod — it cannot read production secrets
- Cluster `Contributor` — it can deploy workloads but not change the cluster

> *"The pipeline can deploy the application but cannot change the platform or
> grant itself permissions. Those are different jobs with different approval
> paths. If the pipeline could grant roles, a compromised pipeline is a
> compromised subscription."*

### Verify the federated credential exists and has no secret

```bash
APP_ID=$(az ad sp show --id "$SP_OID" --query appId -o tsv)

# There should be a federated credential...
az ad app federated-credential list --id "$APP_ID" \
  --query '[].{name:name, subject:subject, issuer:issuer}' -o json

# ...and NO password credentials at all
az ad app credential list --id "$APP_ID" --query 'length(@)' -o tsv
# Expect: 0
```

That `0` is the whole point of this section.

### A separate service connection for ACR

**New service connection → Docker Registry → Azure Container Registry**,
authenticated with the same workload identity. Name it `sc-erp-acr` to match
`variables-common.yml`.

---

## 5. Environments, approvals and checks

**Pipelines → Environments → New environment**

Create four:

| Environment | Purpose | Checks |
|---|---|---|
| `erp-dev` | automatic deploys from main | none |
| `erp-test` | needs sign-off | approval (1 reviewer) |
| `erp-prod` | needs sign-off + window | approval (2 reviewers), business hours, exclusive lock |
| `erp-infra-dev` | Terraform apply | approval (1 reviewer) |

### Configure the prod checks

**erp-prod → ⋮ → Approvals and checks:**

**1. Approvals**
```
Approvers:                    grp-erp-platform-admins
Minimum number of approvals:  2
Requesters can approve:       NO    ← the important one
Timeout:                      1 day
Instructions: "Confirm the change ticket, that test is green, and that you
               have read the Terraform plan if infrastructure changed."
```

**"Requesters can approve their own runs" must be off.** Leaving it on means
one person can author a change and approve it, which is not an approval — it
is a formality. That single checkbox is the difference between a real control
and theatre, and it is worth naming in an interview.

**2. Business hours**
```
Time zone:   India Standard Time
Monday-Thursday, 10:00 - 16:00
```

Nobody deploys to prod at 18:00 on a Friday. The check queues the deployment
until the next allowed window.

**3. Exclusive lock**

Prevents two pipeline runs deploying to the same environment simultaneously.
Without it, two merges in quick succession can interleave Helm upgrades and
you end up with an undefined release state.

**4. Required template** — the one people never configure
```
Repository: erp-platform
Ref: refs/heads/main
Path: pipelines/templates/stage-deploy.yml
```

This means **only a pipeline that extends your approved template can deploy to
prod**. Somebody cannot write a new pipeline that skips the security stages
and ship to production with it. Without this check, every other gate is
advisory — a developer can author `my-quick-deploy.yml` with no scanning at
all and target `erp-prod`.

> *"A required-template check is what makes the security gates mandatory
> rather than conventional. Otherwise the gates only apply to pipelines that
> choose to include them."*

---

## 6. Branch policies

**Repos → Branches → main → ⋮ → Branch policies**

| Policy | Setting | What it prevents |
|---|---|---|
| Require a minimum number of reviewers | 1 (2 in a real team) | unreviewed change |
| Prohibit the most recent pusher from approving | **on** | self-approval |
| When new changes are pushed | reset approvals | approving v1 and merging v4 |
| Check for linked work items | on (optional) | untraceable change |
| Check for comment resolution | on | "I'll fix that later" |
| Build validation | `ContosoERP-CI`, **required**, 12h expiry | merging a red build |
| Status checks | optional | external gates |
| Merge types | **squash only** | messy history |
| Automatically included reviewers | platform team for `infra/*` and `pipelines/*` | infra changed without the platform team seeing it |

That last one is genuinely useful and under-used:

**Automatically included reviewers → Add:**
```
Reviewers: grp-erp-platform-admins
Required:  yes
Path filter: /infra/*;/pipelines/*;/policy/*;/k8s/*
```

Now an application developer cannot change the Terraform or the pipeline
templates without platform review, while ordinary application changes are not
slowed down.

```bash
# The same thing from the CLI
REPO_ID=$(az repos show --repository erp-platform --query id -o tsv)

az repos policy approver-count create \
  --repository-id "$REPO_ID" --branch main \
  --blocking true --enabled true \
  --minimum-approver-count 1 \
  --creator-vote-counts false \
  --reset-on-source-push true \
  --allow-downvotes false

az repos policy merge-strategy create \
  --repository-id "$REPO_ID" --branch main \
  --blocking true --enabled true \
  --use-squash-merge true
```

---

## 7. Variable groups and Key Vault linkage

**Pipelines → Library → + Variable group**

```
Name: erp-secrets-dev
☑ Link secrets from an Azure key vault as variables
   Azure subscription: sc-erp-dev-wif
   Key vault name:     kv-erp-dev-xxxxxx
   Variables:          erp-db-admin-password, erp-api-signing-key
```

Then **Security → Pipeline permissions** → restrict to the specific pipelines
that need it. A variable group open to all pipelines means any new pipeline
can read production secrets.

### Why link rather than copy

A variable group with values typed in is a second copy of your secrets, with
its own rotation problem and a weaker audit trail. Linking to Key Vault means:

- one source of truth
- rotation in Key Vault takes effect on the next pipeline run with no edit
- the **Key Vault audit log** records the pipeline's read, so you can see
  which run read which secret

```bash
az pipelines variable-group list \
  --query '[].{name:name, type:type, vault:providerData.vault}' -o table
```

---

## 8. Agents: Microsoft-hosted vs self-hosted

| | Microsoft-hosted | Self-hosted |
|---|---|---|
| Cost | 1,800 free min/month, then per-minute | you pay for the VM |
| Setup | none | install the agent, maintain it |
| Clean environment each run | **yes** | no — state leaks between runs |
| Can reach a private AKS API server | **no** | yes |
| Can reach a VNet-injected database | **no** | yes |
| Egress IP | from a large public range | yours, so firewall rules are possible |

**The decision for this project:** Microsoft-hosted for dev, because the dev
cluster's API server is public (IP-restricted). For a **private** cluster or a
VNet-injected database you need either:

1. a **self-hosted agent** on a VM in `snet-shared-services`, or
2. **Managed DevOps Pools** — Microsoft-managed agents injected into your
   VNet, which gets you clean ephemeral agents *and* private connectivity, or
3. `az aks command invoke`, which runs your command from inside the cluster
   without needing network access — which is exactly why
   `run_command_enabled = false` in prod.

> *"The interesting constraint is that a private cluster breaks Microsoft-hosted
> agents, and people discover that after they have hardened the network. The
> options are a self-hosted agent in the VNet, Managed DevOps Pools for
> VNet-injected ephemeral agents, or `command invoke` — and I would not use
> `command invoke` in production because it is a deliberate bypass of the
> network controls I just built."*

### If you do need a self-hosted agent

```bash
# On a VM in snet-shared-services, no public IP, reached via Bastion
mkdir ~/azagent && cd ~/azagent
curl -sO https://vstsagentpackage.azureedge.net/agent/4.248.0/vsts-agent-linux-x64-4.248.0.tar.gz
tar zxf vsts-agent-linux-x64-4.248.0.tar.gz

# Register it with a PAT scoped to Agent Pools (read, manage) ONLY
./config.sh --unattended \
  --url https://dev.azure.com/your-name-erp \
  --auth pat --token "$AZDO_PAT" \
  --pool erp-private-pool \
  --agent "$(hostname)" \
  --acceptTeeEula

sudo ./svc.sh install && sudo ./svc.sh start
```

Then in the pipeline: `pool: { name: erp-private-pool }` instead of
`vmImage: ubuntu-latest`.

---

## 9. Create the pipelines

```bash
az pipelines create \
  --name "ContosoERP-CI" \
  --repository erp-platform --repository-type tfsgit \
  --branch main \
  --yml-path pipelines/azure-pipelines.yml \
  --skip-first-run

az pipelines create \
  --name "ContosoERP-Infra" \
  --repository erp-platform --repository-type tfsgit \
  --branch main \
  --yml-path pipelines/azure-pipelines-infra.yml \
  --skip-first-run
```

### Before the first run — update the variables

Edit [`pipelines/templates/variables-common.yml`](../pipelines/templates/variables-common.yml)
with your real values:

```bash
cd infra/terraform/envs/dev
echo "acrName:          $(terraform output -raw acr_name)"
echo "acrLoginServer:   $(terraform output -raw acr_login_server)"
echo "aksClusterDev:    $(terraform output -raw aks_name)"
echo "aksResourceGroupDev: $(terraform output -raw aks_resource_group)"
```

Then authorise the pipeline to use the service connections: the first run will
pause with "This pipeline needs permission to access a resource" — click
**View → Permit**. Or pre-authorise:

```bash
PIPELINE_ID=$(az pipelines show --name "ContosoERP-CI" --query id -o tsv)
# Then in the UI: Service connections → sc-erp-dev-wif → Security →
#   Pipeline permissions → + → ContosoERP-CI
```

---

## 10. Break it on purpose

**Exercise A — prove branch protection works**

```bash
git checkout main
echo "# direct push attempt" >> README.md
git commit -am "direct to main"
git push origin main
```

Rejected: `TF402455: Pushes to this branch are not permitted; you must use a
pull request.`

Do it properly:

```bash
git reset --hard origin/main
git checkout -b feature/test-policy
echo "# via PR" >> README.md
git commit -am "test the PR flow"
git push -u origin feature/test-policy

az repos pr create --title "Test branch policy" \
  --source-branch feature/test-policy --target-branch main \
  --description "Verifying build validation and reviewer policy"
```

Observe: the PR shows the required build running, and the merge button is
disabled until it passes.

**Exercise B — try to bypass the security gates**

```bash
cat > pipelines/sneaky.yml <<'EOF'
# A pipeline with NO security stages that targets prod directly.
trigger: none
pool: { vmImage: ubuntu-latest }
jobs:
  - deployment: sneaky
    environment: erp-prod
    strategy:
      runOnce:
        deploy:
          steps:
            - script: echo "deployed with no scanning at all"
EOF

git checkout -b feature/sneaky && git add -A
git commit -m "add a pipeline that skips the gates"
git push -u origin feature/sneaky

az pipelines create --name "Sneaky" --repository erp-platform \
  --repository-type tfsgit --branch feature/sneaky \
  --yml-path pipelines/sneaky.yml
```

**With the required-template check configured, this run is blocked** at the
environment with "The pipeline does not extend a required template". Without
that check, it would deploy.

```bash
git checkout main
git branch -D feature/sneaky
git push origin --delete feature/sneaky
rm pipelines/sneaky.yml
```

This exercise is worth doing because it converts "we have approvals" into
"here is how I proved the approvals could not be bypassed", which is a much
better thing to say.

**Exercise C — self-approval**

Temporarily turn **Requesters can approve** back on, run a deploy to
`erp-prod`, and approve your own run. Then turn it off and watch the same run
wait for someone else. Short, and it makes the control concrete.

---

## 11. Interview answers this chapter gives you

**"How do you authenticate your pipeline to Azure?"**

> Workload identity federation, so there is no secret at all. The service
> connection presents a short-lived OIDC token; Entra ID trusts it because the
> app registration has a federated credential pinned to that exact
> organisation, project and service-connection name. Nothing to rotate,
> nothing to store in a variable group, nothing that can be exfiltrated and
> replayed. It also eliminated a recurring outage class — pipelines failing
> because a two-year client secret expired at the worst possible moment. The
> step people skip afterwards is reducing the permissions: the automatic setup
> grants Contributor on the whole subscription, so I remove that and grant
> Contributor per resource group, plus AcrPush and AKS RBAC Writer. It
> deliberately has no Owner and no User Access Administrator, so a compromised
> pipeline cannot grant itself more access.

**"How do you control what reaches production?"**

> Four layers, and each one closes a hole the previous one leaves. Branch
> policies on main: PR required, build validation required, the most recent
> pusher cannot approve, approvals reset on a new push, and the platform team
> is an automatically-required reviewer for anything under `infra/`,
> `pipelines/` or `policy/`. Then the pipeline itself: the deploy stage depends
> on the security stage, so a failed SAST or secret scan means there is no
> image to deploy. Then environment checks on `erp-prod`: two approvers,
> requesters cannot approve their own runs, a business-hours window, and an
> exclusive lock so two runs cannot interleave. And the one that ties it
> together — a required-template check, so only a pipeline extending the
> approved deploy template can target prod. Without that, somebody writes a
> new pipeline with no gates and ships straight to production, and every other
> control is advisory.

**"Microsoft-hosted or self-hosted agents?"**

> Microsoft-hosted by default, because every run gets a clean ephemeral
> environment and there is nothing to patch — and a clean agent is a real
> security property, since state cannot leak between runs. The constraint that
> forces a change is network: a Microsoft-hosted agent cannot reach a private
> AKS API server or a VNet-injected database, which is exactly the posture I
> want in production. So the options become a self-hosted agent on a VM in the
> shared-services subnet, or Managed DevOps Pools, which gives you
> Microsoft-managed ephemeral agents injected into your own VNet — that is
> usually the right answer now because you keep the clean-agent property and
> get private connectivity. There is a third option, `az aks command invoke`,
> which runs commands from inside the cluster, but I would not use it in
> production because it is deliberately a bypass of the network controls.

**"How do you handle secrets in pipelines?"**

> Mostly by not having them, because the service connection is federated. What
> is genuinely needed comes from a variable group **linked** to Key Vault
> rather than typed in — one source of truth, rotation takes effect on the
> next run with no pipeline edit, and the read shows up in the Key Vault audit
> log attributed to the pipeline. The variable group's pipeline permissions are
> restricted to the specific pipelines that need it, because a group open to
> all pipelines means any new pipeline can read production secrets. And in the
> YAML, secrets are never interpolated into a script body — they are passed as
> `env:` so Azure DevOps masks them in the logs. The masking is not perfect:
> if you base64 or substring a secret the masker will not catch the derived
> value, which is why Gitleaks also runs against the working tree.

---

## Checklist

- [ ] Organisation and project created, unused services switched off
- [ ] Repository pushed; **gitleaks run clean before the first push**
- [ ] `.gitignore` covers tfstate, tfvars, backend.hcl, .env, kubeconfig, keys
- [ ] You can explain why `*.tfstate` is the critical line
- [ ] Service connections use **workload identity federation**
- [ ] `az ad app credential list` returns **0** — no secret exists
- [ ] Subscription-wide Contributor removed; per-RG roles granted instead
- [ ] Service principal has no Owner and no User Access Administrator
- [ ] Four environments created
- [ ] `erp-prod`: 2 approvers, **requesters cannot approve**, business hours, exclusive lock
- [ ] **Required-template check configured on `erp-prod`**
- [ ] Branch policies on main, including auto-required reviewers for `infra/*`
- [ ] Variable group **linked** to Key Vault, pipeline permissions restricted
- [ ] You can state the Microsoft-hosted vs self-hosted trade-off and the private-cluster constraint
- [ ] Both pipelines created
- [ ] Direct push to main rejected
- [ ] **Gate-bypass pipeline blocked by the required-template check**
- [ ] Self-approval exercise done

Next: [chapter 09 — CI/CD pipelines](09-cicd-pipelines.md)
