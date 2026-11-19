# Terraform cheatsheet

---

## The loop

```bash
cd infra/terraform/envs/dev

export ARM_USE_AZUREAD=true                                  # for the blob backend
export TF_VAR_postgres_admin_password="$(openssl rand -base64 24)"

terraform init -backend-config=backend.hcl
terraform fmt -recursive ../..
terraform validate
terraform plan -out=tfplan
terraform show tfplan | head -80          # READ IT. Every time.
terraform apply tfplan
terraform output
```

---

## Commands

```bash
# init
terraform init                            # first time
terraform init -upgrade                   # pick up new provider versions
terraform init -reconfigure               # change backend config
terraform init -migrate-state             # move state to a new backend
terraform init -backend=false             # validate only, no backend needed

# plan
terraform plan                            # to the console
terraform plan -out=tfplan                # save it (what apply should consume)
terraform plan -detailed-exitcode         # 0=no changes 1=error 2=changes
terraform plan -refresh-only              # DRIFT: what changed outside Terraform?
terraform plan -target=module.aks         # one module (debugging only)
terraform plan -var-file=prod.tfvars
terraform plan -destroy                   # preview a destroy

# apply
terraform apply tfplan                    # the approved plan - what CI does
terraform apply -auto-approve             # no prompt
terraform apply -lock-timeout=5m          # wait for a held lock
terraform apply -parallelism=5            # default is 10; lower it to debug

# destroy
terraform destroy
terraform destroy -target=module.firewall  # one module

# inspect
terraform output
terraform output -json
terraform output -raw aks_name             # no quotes - for scripts
terraform show                             # current state, human readable
terraform show -json tfplan | jq '.resource_changes[].address'
terraform graph | dot -Tpng > graph.png
terraform providers
terraform version
```

---

## State

```bash
terraform state list
terraform state list | grep aks
terraform state show module.aks.azurerm_kubernetes_cluster.this

# Import something that exists in Azure but not in state
terraform import module.acr.azurerm_container_registry.this \
  /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerRegistry/registries/<name>

# Forget a resource without deleting it in Azure
terraform state rm module.firewall.azurerm_firewall.this[0]

# Rename after a refactor (better: use a moved block, see below)
terraform state mv module.old module.new

# Locks
terraform force-unlock <LOCK_ID>          # the id is IN the error message

# Refresh state from reality
terraform apply -refresh-only
```

> **Never force-unlock without checking nobody is actually applying.** That is
> how state gets corrupted.

### `moved` blocks beat `state mv`

```hcl
# Refactoring without breaking anyone's state
moved {
  from = azurerm_kubernetes_cluster.main
  to   = module.aks.azurerm_kubernetes_cluster.this
}
```

This travels with the code, so every consumer's state migrates on their next
plan. `terraform state mv` only fixes *your* state and silently breaks
everyone else's.

---

## HCL patterns used in this project

### Validation — fail fast with a useful message

```hcl
variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "test", "prod"], var.env)
    error_message = "env must be one of: dev, test, prod."
  }
}
```

> **Attributes are newline-separated, never comma-separated.**
> `variable "x" { type = string, default = "y" }` is a parse error.

### Conditional resources

```hcl
# count for a simple on/off
resource "azurerm_firewall" "this" {
  count = var.enabled ? 1 : 0
  # ...
}
# then reference with [0] and guard the output
output "fw_ip" {
  value = var.enabled ? azurerm_firewall.this[0].ip_configuration[0].private_ip_address : null
}

# for_each for a set, which gives STABLE addresses
resource "azurerm_private_dns_zone" "zones" {
  for_each = local.private_dns_zones
  name     = each.value
}
```

> **Prefer `for_each` over `count` for collections.** With `count`, removing
> the middle element reindexes everything after it and Terraform destroys and
> recreates resources that did not change. With `for_each` the key is the
> address, so removal affects only that one.

### Dynamic blocks

```hcl
dynamic "email_receiver" {
  for_each = var.oncall_emails
  content {
    name          = "email-${replace(email_receiver.value, "@", "-at-")}"
    email_address = email_receiver.value
  }
}
```

### lifecycle

```hcl
lifecycle {
  # Do not fight the autoscaler or the auto-upgrade channel on every plan
  ignore_changes = [
    default_node_pool[0].node_count,
    kubernetes_version,
  ]
  prevent_destroy       = true    # for a production database
  create_before_destroy = true    # for a resource with a unique name
  replace_triggered_by  = [azurerm_resource.other]
}
```

### Useful functions

```hcl
cidrsubnet("10.10.0.0/16", 6, 0)        # => 10.10.0.0/22
cidrhost("10.10.0.0/22", 5)             # => 10.10.0.5
substr(sha1("seed"), 0, 6)              # stable unique suffix
lookup(local.map, var.key, "default")
try(expr, fallback)                     # swallow an error
coalesce(a, b, c)                       # first non-null
merge(map1, map2)
toset([...])  tolist(...)  tomap(...)
jsonencode({...})  jsondecode(str)
timeadd(timestamp(), "8760h")
replace(s, "-", "")
format("%s-%s-%02d", a, b, 1)
one(list)                               # the single element, or error
```

### Local values keep expressions readable

```hcl
locals {
  base = "${var.workload}-${var.env}-${local.loc}"
  tags = merge(var.common_tags, { Environment = var.env })

  spoke_subnets = {
    aks_system = cidrsubnet(var.spoke_cidr, 6, 0)
    aks_user   = cidrsubnet(var.spoke_cidr, 6, 1)
  }
}
```

---

## Modules

```hcl
module "aks" {
  source = "../../modules/aks"          # local path
  # source = "git::https://...//modules/aks?ref=v1.2.0"   # pinned tag
  # source = "Azure/aks/azurerm"; version = "~> 9.0"      # registry

  name    = module.naming.names.aks
  rg_name = azurerm_resource_group.aks.name

  depends_on = [azurerm_role_assignment.aks_network_contributor]
}
```

```bash
terraform get -update                    # refresh local modules
```

> **Always pin a remote module to a tag or commit**, never a branch. An
> unpinned module means someone else's merge changes your infrastructure.

---

## Providers

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"               # >= 4.14.0, < 5.0.0
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true    # dev convenience
    }
    resource_group {
      prevent_deletion_if_contains_resources = true   # safety
    }
  }
  resource_provider_registrations = "core"   # faster plans
}
```

### Version constraints

| Constraint | Means |
|---|---|
| `4.14.0` | exactly |
| `~> 4.14` | `>= 4.14.0, < 5.0.0` — allows minor and patch |
| `~> 4.14.0` | `>= 4.14.0, < 4.15.0` — patch only |
| `>= 4.14, < 5.0` | explicit range |

**Commit `.terraform.lock.hcl`.** It pins exact versions *and* hashes, so CI
uses the providers you tested with. That is a supply-chain control, not
clutter.

---

## Authentication

```bash
# Local: your own identity
az login
export ARM_USE_AZUREAD=true          # for the azurerm state backend

# CI with workload identity federation - no secret anywhere
export ARM_USE_OIDC=true
export ARM_USE_AZUREAD=true
export ARM_CLIENT_ID="$servicePrincipalId"
export ARM_OIDC_TOKEN="$idToken"
export ARM_TENANT_ID="$tenantId"
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

| Variable | Note |
|---|---|
| `ARM_USE_AZUREAD` | use Entra ID for the storage backend; **required** when shared-key access is disabled |
| `ARM_USE_OIDC` | federated credential instead of a secret |
| `ARM_CLIENT_SECRET` | avoid. If you set this you have a secret to rotate. |
| `TF_VAR_<name>` | sets variable `<name>` |
| `TF_LOG=DEBUG` | very verbose; `TF_LOG_PATH=tf.log` to a file |
| `TF_IN_AUTOMATION=1` | shortens output for CI |
| `TF_CLI_ARGS_plan` | default flags for `plan` |

---

## Secrets and state — the thing to understand

**Terraform state stores the actual values of everything it manages, in plain
text.** `sensitive = true` hides a value from the console output; it does
**not** encrypt state.

```hcl
output "db_password" {
  value     = random_password.db.result
  sensitive = true          # hidden in CLI output; STILL PLAIN TEXT IN STATE
}
```

Therefore:

- remote state in a storage account with RBAC, encryption and versioning
- `--allow-shared-key-access false`, so account keys are useless
- never commit `*.tfstate`
- treat state as a secret, because it is one

```bash
# Prove it to yourself once
terraform state pull | jq '.resources[] | select(.type=="random_password")' | head -20
```

---

## Scanning

```bash
checkov -d infra/terraform --framework terraform --compact --quiet
tfsec infra/terraform
terrascan scan -i terraform -d infra/terraform
trivy config infra/terraform
```

Suppress **inline, with a reason**, so the next reviewer sees the reasoning:

```hcl
# checkov:skip=CKV_AZURE_4:Diagnostic logging is configured by the
#   azurerm_monitor_diagnostic_setting resource below; Checkov does not
#   correlate it with the cluster resource.
resource "azurerm_kubernetes_cluster" "this" {
```

A bare `--skip-check` in the CLI flags is invisible to anyone reading the
Terraform. That should fail code review.

---

## Debugging

```bash
# Why does it want to replace this?
terraform plan | grep -B5 "forces replacement"

# What exactly will change?
terraform show -json tfplan | jq -r '.resource_changes[]
  | select(.change.actions[0] != "no-op")
  | "\(.change.actions[0]): \(.address)"'

# Verbose
TF_LOG=DEBUG TF_LOG_PATH=tf.log terraform apply
grep -i "error\|403\|404" tf.log | head

# Inspect state as JSON
terraform state pull | jq '.resources[].type' | sort -u

# Test an expression without applying anything
terraform console
> cidrsubnet("10.10.0.0/16", 6, 1)
> module.naming.names
```

---

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `could not acquire access token` | not logged in / wrong sub | `az login; az account set -s <sub>` |
| `AuthorizationPermissionMismatch` on state | shared-key disabled, no Entra auth | `export ARM_USE_AZUREAD=true` + Storage Blob Data Contributor |
| `Error acquiring the state lock` | a previous run died | `terraform force-unlock <id>` after checking |
| `MissingSubscriptionRegistration` | provider not registered | `az provider register --namespace <ns>` |
| `A resource with the ID ... already exists` | exists in Azure, not in state | `terraform import` |
| `Invalid for_each argument` | the value is unknown at plan time | restructure, or use a two-stage apply |
| `Cycle: ...` | circular dependency | break it with `depends_on` or a data source |
| `Provider produced inconsistent result` | a provider bug or an Azure API eventual-consistency issue | retry; often resolves |
| Empty OIDC issuer URL on first apply | the cluster does not exist yet | apply again |

---

## Habits worth building

1. **Always `terraform plan -out` then apply the plan file.** The approved
   change is then byte-for-byte the applied change.
2. **Always read the plan.** Not skim — read. `-/+` means destroy and recreate.
3. **`terraform fmt -recursive` before every commit.** Unformatted diffs make
   every future plan review noisier.
4. **Commit `.terraform.lock.hcl`.**
5. **Never `-target` in production.** It applies a partial graph and leaves
   state inconsistent with the configuration. It is a debugging tool.
6. **`plan -refresh-only` on a schedule** to catch drift — exit code 2 means
   something changed outside the pipeline, which means it bypassed review.
7. **One state file per environment.** A single state for everything means a
   dev mistake can touch prod and every apply locks the whole estate.
