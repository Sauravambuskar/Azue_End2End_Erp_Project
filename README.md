# ContosoERP — Azure DevSecOps practice platform

An end-to-end, buildable Azure platform carrying a real ERP application,
built as interview preparation for an **Azure DevSecOps Engineer** role.

Every requirement in the target job description maps to something in this
repository. See [`guidance/checklists/jd-coverage-matrix.md`](guidance/checklists/jd-coverage-matrix.md).

> **New here? Go to [`guidance/00-START-HERE.md`](guidance/00-START-HERE.md).**
> That file is the course; this one is the map.

---

## What this is

A manufacturing ERP system — products, inventory, sales orders, purchase
orders and a double-entry general ledger — running on a secure Azure landing
zone that you build, automate, secure and operate yourself.

The application is real so the platform has real problems to solve: database
migrations against a server with no public endpoint, passwordless
authentication, pod-to-pod network policy, zero-downtime rollout, and a smoke
test that verifies the ledger balances rather than just that a pod is running.

---

## Repository layout

```
.
├── guidance/              ← START HERE. 16 chapters, step by step.
│   ├── 00-START-HERE.md       learning path, budget options, 3-week plan
│   ├── 01..15-*.md            one chapter per platform area
│   ├── checklists/            JD coverage matrix, daily practice, pre-interview
│   └── cheatsheets/           az, kubectl, terraform, KQL, troubleshooting
│
├── src/                   ← the ERP application
│   ├── erp-api/               FastAPI + SQLAlchemy, 10 tests, hardened image
│   ├── erp-web/               Node/Express BFF + UI, 19 tests, allow-listed proxy
│   └── erp-worker/            Python CronJob, 18 tests: reorder scan, GL check
│
├── db/                    ← PostgreSQL
│   ├── migrations/            V001 schema, V002 least-privilege roles, V003 views
│   ├── seed/                  demo master data
│   └── Dockerfile             migration runner image
│
├── infra/
│   ├── terraform/             the real deployment
│   │   ├── modules/           11 single-purpose modules: naming, network, aks,
│   │   │                      postgres, keyvault, acr, monitor, identity,
│   │   │                      cosmos, appgw, firewall
│   │   ├── stacks/erp-platform/  the whole platform composed as one unit
│   │   └── envs/dev, envs/prod   thin root modules: backend + provider + values
│   └── bicep/                 the same landing zone in Bicep, for comparison
│
├── k8s/
│   ├── base/                  namespace with PSA restricted, quotas, RBAC
│   └── helm/erp/              the chart: deployments, CronJob, migration hook,
│                              HPA, PDB, NetworkPolicy, SecretProviderClass
│
├── pipelines/             ← Azure DevOps
│   ├── azure-pipelines.yml            application CI/CD
│   ├── azure-pipelines-infra.yml      Terraform plan/approve/apply
│   ├── azure-pipelines-nightly-stop.yml  the cost guard
│   └── templates/                     9 reusable, cross-team templates
│
├── policy/                ← governance
│   ├── definitions/           4 custom Azure Policy definitions
│   └── initiatives/           the landing-zone baseline initiative
│
├── security/              ← DevSecOps configuration
│   ├── secrets/gitleaks.toml      custom Azure secret patterns
│   ├── sast/semgrep-erp.yml       9 custom rules for THIS codebase
│   ├── dast/zap-rules.tsv         OWASP ZAP tuning
│   └── sca-accepted-risks.txt     expiring accepted-risk register
│
└── scripts/               ← operations
    ├── bootstrap-tfstate.sh       day-zero remote state
    ├── create-management-groups.sh
    ├── db-grant-identities.sh     the step everyone forgets
    ├── build-and-push.sh          build, verify non-root, scan, push
    ├── run-migrations.sh          passwordless migration runner
    ├── smoke-test.sh              27 business-level checks
    ├── configure-kubectl.sh       get-credentials + kubelogin + verify
    ├── validate-local.sh          all 20 CI checks, locally
    ├── cost-check.sh              run this at the end of every session
    └── teardown.sh
```

---

## Quick start — zero Azure cost

Run the whole ERP on your laptop first. No Azure account needed.

```bash
docker compose up -d

curl -s http://localhost:8000/healthz/ready
./scripts/smoke-test.sh http://localhost:8000     # expect 27/27 PASS

# open http://localhost:3000  and click through the ERP
```

Then verify the whole repository:

```bash
./scripts/validate-local.sh
```

Twenty checks: terraform fmt and validate (dev *and* prod), bicep build, helm
lint and template, three test suites (pytest x2, node:test), ruff, bandit,
eslint, semgrep, gitleaks, checkov, policy JSON, pipeline YAML, markdown links
and shell syntax — the same gates the pipeline runs. Tools you have not
installed are skipped rather than failed, so this works on day one and gets
stricter as you install more of the toolchain.

---

## Quick start — on Azure

Full walkthrough in [`guidance/`](guidance/). The short version:

```bash
# 1. Safety rails first (chapter 01) - budget alerts, provider registration
az login

# 2. Landing zone (chapter 02)
./scripts/create-management-groups.sh
./scripts/bootstrap-tfstate.sh

# 3. Infrastructure (chapters 02-06)
cd infra/terraform/envs/dev
cp terraform.tfvars.example terraform.tfvars   # edit it
export ARM_USE_AZUREAD=true
export TF_VAR_postgres_admin_password="$(openssl rand -base64 24)"
terraform init -backend-config=backend.hcl
terraform apply

# 4. Database identities (chapter 06) - the step everyone forgets
cd /d/Azure && ./scripts/db-grant-identities.sh dev

# 5. Build, scan and push (chapter 05)
./scripts/build-and-push.sh "$(cd infra/terraform/envs/dev && terraform output -raw acr_login_server)" v0.1.0

# 6. Deploy (chapter 05)
kubectl apply -f k8s/base/namespace.yaml
helm upgrade --install erp k8s/helm/erp -n erp --create-namespace \
  -f k8s/helm/erp/values-dev.yaml --atomic --wait

# 7. Verify
./scripts/smoke-test.sh http://localhost:8000

# 8. ALWAYS, at the end of every session
./scripts/cost-check.sh
az aks stop -g rg-erp-dev-cin-aks -n aks-erp-dev-cin-01
```

> **Expect `terraform apply` to need running twice the first time.** The
> identity module federates against the AKS OIDC issuer URL, which does not
> exist until the cluster does.

---

## Cost

| State | Approximate cost |
|---|---|
| Everything running (2 AKS nodes, B1ms Postgres, Basic ACR, 1 GB/day logs) | **~USD 4–6/day** |
| AKS stopped, Postgres stopped | **~USD 0.30/day** |
| With Azure Firewall enabled | **+USD 30/day** ← never leave this on |
| With App Gateway WAF enabled | **+USD 6/day** |

A new Azure account's **USD 200 / 30-day credit** comfortably covers the whole
project if you stop AKS between sessions.

`enable_firewall` and `enable_appgw` default to **false**. Turn them on only
for the specific exercises in chapter 03, then turn them off.

---

## Verified working

Everything below is checked, not claimed. Reproduce with one command:

```bash
./scripts/validate-local.sh      # 20 checks, no Azure account needed
```

| Check | Result |
|---|---|
| `pytest` — API (full order lifecycle + balanced-ledger assertion) | **10 passed** |
| `pytest` — worker (structured-log shape, exit codes, ledger integrity) | **18 passed** |
| `node:test` — web BFF (allow-list, traversal, headers, SSRF) | **19 passed** |
| `scripts/smoke-test.sh` against a live API | **27/27 passed** |
| `terraform validate` — dev root module | **clean** |
| `terraform validate` — prod root module | **clean** |
| `terraform fmt -check -recursive` | **clean** |
| `checkov` — Terraform, 11 modules + stack + 2 envs | **132 passed, 0 failed, 99 documented skips** |
| `gitleaks` — custom Azure ruleset, whole tree | **0 findings** |
| `semgrep` — 9 custom ERP rules | **0 findings** |
| `bicep build` | **clean, 0 warnings** |
| `helm lint` + `helm template` — dev and prod values | **19 / 22 objects render** |
| `ruff` — api + worker | **clean** |
| `bandit` — api + worker, high severity | **clean** |
| `eslint` incl. eslint-plugin-security — web | **clean** |
| Pipeline + manifest YAML parses | **16 files clean** |
| Markdown internal links | **95 links, 0 broken** |
| Shell scripts parse | **11 scripts clean** |
| Web → BFF → API → DB, three tiers end to end | **working** |

### Four bugs the scanners found in this repository

Each is written up as a worked example, because the lesson transfers:

| Found by | Bug | Where it is explained |
|---|---|---|
| gitleaks | **461 findings on a repo with no secrets.** Three config bugs: `.gitignore` not honoured so `.venv` was scanned, path patterns written with `/` only so they failed on Windows, and a custom regex that matched shell interpolation. | [ch 10 §3](guidance/10-devsecops-gates.md) |
| checkov | **30 failures.** Four were genuine — three subnets had no NSG at all. The rest were dev-vs-prod posture already parameterised. Also: inline suppressions must be *inside* the resource block or they are silently ignored. | [ch 10 §7](guidance/10-devsecops-gates.md) |
| semgrep | A custom rule flagged the **correct** parameterised connection string. A rule that fires on good code gets deleted, not fixed. | [ch 10 §4](guidance/10-devsecops-gates.md) |
| node:test | `server.js` called `app.listen()` at import time, so the test process hung forever instead of exiting. Guarded with `require.main === module`. Also exposed that the SPA fallback returned HTML with a 200 for `/api/v1/*`. | `src/erp-web/src/server.js` |

> The transferable lesson, and the best single thing to say about SAST in an
> interview: **validate every detection rule against known-good *and*
> known-bad input.** A rule you have only ever seen produce zero findings is
> as untested as one you have only ever seen produce findings.

## The architecture in one diagram

```
Internet → App Gateway (WAF v2, OWASP 3.2) → AKS ingress
                                               ↓
                              erp-web (BFF) → erp-api → PostgreSQL
                                               ↑          (VNet-injected,
                                          erp-worker       no public endpoint,
                                          (CronJob)        Entra ID tokens)
            All egress → Azure Firewall (FQDN allow-list) in the hub VNet

  Identity:  K8s ServiceAccount → federated credential → managed identity
             → Entra ID token → Key Vault / ACR / PostgreSQL
             No secrets. Nothing to rotate.
```

---

## Where to read the reasoning

The code is commented with *why*, not *what*. The highest-value files to read:

| File | What it teaches |
|---|---|
| [`infra/terraform/modules/identity/main.tf`](infra/terraform/modules/identity/main.tf) | the workload identity chain, end to end |
| [`infra/terraform/modules/aks/main.tf`](infra/terraform/modules/aks/main.tf) | every AKS security setting, with the reason |
| [`k8s/helm/erp/templates/networkpolicy.yaml`](k8s/helm/erp/templates/networkpolicy.yaml) | default-deny and the IMDS block |
| [`src/erp-api/app/core/db.py`](src/erp-api/app/core/db.py) | passwordless DB auth, token-per-connection |
| [`pipelines/templates/job-build-image.yml`](pipelines/templates/job-build-image.yml) | why you scan *before* you push |
| [`pipelines/templates/stage-deploy.yml`](pipelines/templates/stage-deploy.yml) | approvals, atomic deploys, failure diagnostics |
| [`db/migrations/V002__least_privilege_roles.sql`](db/migrations/V002__least_privilege_roles.sql) | database-level least privilege, append-only ledger |

---

## Licence and attribution

Built as a personal learning project. The ERP domain, "Contoso" naming and all
data are fictional.
