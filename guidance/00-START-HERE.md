# START HERE

> **Written for:** you — preparing for the Azure DevSecOps Engineer interview
> (Hyderabad / Pune, 4 years experience, Tekskills payroll).

This folder is your course. The rest of the repository is your lab.

---

## 1. What this project is

You are building **ContosoERP** — a manufacturing ERP system (products,
inventory, sales orders, purchase orders, general ledger) running on a secure
Azure platform that you design, build, automate, secure and operate yourself.

The ERP application exists so the platform has something real to carry. An
empty `nginx` pod teaches you nothing; a system with a database, a background
job, financial integrity rules and three tiers forces you to confront real
problems — migrations with no public DB endpoint, passwordless auth, pod-to-pod
network policy, zero-downtime rollout, business-level smoke tests.

Every single line of the job description maps to something you will build.
See [`checklists/jd-coverage-matrix.md`](checklists/jd-coverage-matrix.md).

---

## 2. The architecture you are going to be able to draw from memory

```
                            Internet
                               │
                     ┌─────────▼──────────┐
                     │ Application Gateway│  WAF v2, OWASP 3.2, TLS 1.2+
                     │   (public IP)      │  rate limit, geo rules
                     └─────────┬──────────┘
                               │  snet-appgw 10.10.16.0/24
═══════════════════════════════│═══════════════════ SPOKE VNet 10.10.0.0/16
                     ┌─────────▼──────────┐
                     │  AKS ingress       │
                     └─────────┬──────────┘
          ┌────────────────────┼────────────────────┐
          │                    │                    │
   ┌──────▼──────┐      ┌──────▼──────┐     ┌──────▼───────┐
   │  erp-web    │─────▶│  erp-api    │     │ erp-worker   │
   │  Node BFF   │ only │  FastAPI    │     │ CronJob      │
   │  SA+MI      │ path │  SA+MI      │     │ SA+MI        │
   └─────────────┘      └──────┬──────┘     └──────┬───────┘
      NetworkPolicy: default deny, 3 explicit flows │
                            ┌──────────────────────┘
                            │ 5432, Entra ID token (no password)
                     ┌──────▼─────────────┐
                     │ PostgreSQL Flexible│  VNet-injected, no public endpoint
                     │ pgaudit, TLS req.  │  private DNS zone
                     └────────────────────┘
          ┌─────────────┬────────────────┬──────────────┐
     ┌────▼────┐  ┌─────▼─────┐  ┌───────▼──────┐  ┌────▼─────┐
     │   ACR   │  │ Key Vault │  │Log Analytics │  │ Cosmos   │
     │ AcrPull │  │ RBAC mode │  │ App Insights │  │serverless│
     └─────────┘  └───────────┘  └──────────────┘  └──────────┘
          all reached over private endpoints in prod

═══════════════════════════════════════════════════ HUB VNet 10.0.0.0/16
   ┌──────────────────┐   ┌──────────────┐
   │ Azure Firewall   │   │   Bastion    │   all spoke egress forced here
   │ FQDN allow-list  │   │              │   by a UDR (0.0.0.0/0 → firewall)
   └──────────────────┘   └──────────────┘
```

**Identity chain (memorise this — it is the most-asked question):**

```
K8s ServiceAccount (erp/erp-api-sa)
   ↓ annotated with the client id of
User-assigned managed identity (id-erp-api-dev)
   ↓ trusts the AKS OIDC issuer for exactly that namespace:serviceaccount via
Federated identity credential
   ↓ pod's projected SA token is exchanged for an
Entra ID access token
   ↓ presented to
Key Vault / ACR / PostgreSQL
```

No secrets. Nothing to rotate. Nothing to leak.

---

## 3. How to use this folder

Read the chapters **in order**. Each one has:

- **Why this exists** — the reasoning, so you can defend the decision
- **Step-by-step** — exact commands, in order, that work
- **Verify** — how to prove it worked
- **Break it on purpose** — a deliberate failure, so you recognise the symptom
- **Interview answers** — the questions this chapter prepares you for
- **Cost** — what this chapter costs per hour, and how to turn it off

| # | Chapter | Time | Cost while running |
|---|---|---|---|
| 01 | [Azure account and safety rails](01-azure-account-setup.md) | 1 h | ₹0 |
| 02 | [Landing zone, management groups, RBAC](02-landing-zone.md) | 3 h | ₹0 |
| 03 | [Hub-spoke networking, NSGs, private endpoints](03-networking.md) | 4 h | ~₹0 (firewall off) |
| 04 | [Entra ID, workload identity, Okta SSO](04-identity.md) | 4 h | ₹0 |
| 05 | [Secure AKS platform](05-aks-platform.md) | 6 h | ~₹12/hr |
| 06 | [PostgreSQL, passwordless auth, migrations](06-database.md) | 4 h | ~₹2/hr |
| 07 | [Key Vault and secret hygiene](07-keyvault-and-secrets.md) | 2 h | ~₹0 |
| 08 | [Azure DevOps setup](08-azure-devops-setup.md) | 3 h | ₹0 (free tier) |
| 09 | [CI/CD pipelines and promotion](09-cicd-pipelines.md) | 5 h | ₹0 |
| 10 | [DevSecOps gates: SAST, DAST, SCA, images](10-devsecops-gates.md) | 5 h | ₹0 |
| 11 | [Monitoring, Log Analytics, KQL, alerts](11-monitoring.md) | 4 h | ~₹1/hr |
| 12 | [Governance: Policy and Defender for Cloud](12-governance.md) | 3 h | ₹0–low |
| 13 | [Cost control and teardown](13-cost-and-teardown.md) | 1 h | saves money |
| 14 | [Platform runbook](14-runbook.md) | 2 h | ₹0 |
| 15 | [Interview preparation](15-interview-prep.md) | 6 h | ₹0 |

**Total: roughly 50–55 focused hours.**

---

## 4. Three ways to run this, by budget

### Path A — Zero cost (start here, today)

Run the whole ERP on your laptop with Docker. No Azure account needed.
You learn the application, the migrations, the Helm chart and the security
tooling. Then do Azure chapters as *reading* plus `terraform plan`.

```bash
docker compose up -d
# open http://localhost:3000
```

### Path B — Free trial (recommended)

A new Azure account gives **USD 200 credit for 30 days**, plus 12 months of
popular free services. That is more than enough for this entire project if you
follow the stop/start discipline in chapter 13.

Realistic burn: **USD 3–6 per day** with AKS running, **under USD 0.50 per
day** with AKS stopped. You will not exhaust the credit.

### Path C — Pay-as-you-go, disciplined

If your trial has expired, everything here still works at roughly
**USD 4–7/day** while actively practising, provided `enable_firewall=false`
and `enable_appgw=false` except during those two specific exercises.

> **The one rule that protects your wallet:** run
> `./scripts/cost-check.sh` at the end of *every* session. It takes 20 seconds
> and it is the difference between a USD 40 month and a USD 400 month.

---

## 5. A realistic 3-week plan

### Week 1 — Platform foundations
| Day | Do | Outcome |
|---|---|---|
| 1 | Ch 01 + 02, run `docker compose up` | Account safe, ERP running locally, you understand the app |
| 2 | Ch 03 | Hub-spoke deployed, you can explain CIDR planning |
| 3 | Ch 04 | Workload identity working end to end |
| 4 | Ch 05 part 1 | AKS cluster up, ERP deployed by hand with Helm |
| 5 | Ch 05 part 2 | NetworkPolicy, HPA, PDB, probes all exercised |
| 6 | Ch 06 | Passwordless PostgreSQL, migrations running in-cluster |
| 7 | Review + redraw the architecture from memory | Consolidation |

### Week 2 — Automation and security
| Day | Do | Outcome |
|---|---|---|
| 8 | Ch 07 | Key Vault + CSI driver, secret rotation understood |
| 9 | Ch 08 | Azure DevOps org, repo, WIF service connections, environments |
| 10 | Ch 09 | Full pipeline green, dev deploy automated |
| 11 | Ch 10 part 1 | Secrets + SAST + SCA gates, all deliberately failed once |
| 12 | Ch 10 part 2 | Container scanning, IaC scanning, DAST |
| 13 | Ch 11 | Dashboards, KQL queries you wrote yourself, alerts firing |
| 14 | Ch 12 | Policies assigned, Defender recommendations remediated |

### Week 3 — Operate and rehearse
| Day | Do | Outcome |
|---|---|---|
| 15 | Ch 14 | Runbook written in your own words |
| 16 | Break-it day: work through `cheatsheets/troubleshooting.md` top to bottom | You have *seen* every failure mode |
| 17 | Ch 15 part 1 | Answer bank drafted |
| 18 | Ch 15 part 2 | Out loud, timed, to a mirror or a friend |
| 19 | Whiteboard drill: draw the architecture 5 times from blank | Fluency |
| 20 | Mock interview, full 60 min | Confidence |
| 21 | Light review, teardown, rest | Ready |

---

## 6. Before you touch Azure — do this first

```bash
cd d:/Azure

# 1. Prove the application works on your machine (no Azure needed)
docker compose up -d
curl -s http://localhost:8000/healthz/ready
./scripts/smoke-test.sh http://localhost:8000     # expect 27/27 PASS
#   open http://localhost:3000  → click through the ERP UI

# 2. Prove the whole repo is valid
./scripts/validate-local.sh                        # expect ALL CHECKS PASSED
```

If both of those pass, you have a working baseline and any later breakage is
something *you* changed — which is exactly the feedback loop you want.

---

## 7. The honest advice

**What gets people hired at this level is not a longer tool list.** It is being
able to say *why*, and to describe something that went wrong and what you did.

So for every single thing you build in this project, write down in your own
words, in a file you keep:

1. What I built
2. What I chose **not** to do, and why
3. What broke, what the symptom looked like, and how I found it

That third one is the gold. "I enabled workload identity and the pod still
failed with a password authentication error. The token was being issued fine —
I checked the projected token file — but PostgreSQL had no role for the
identity. The missing step was `pgaadauth_create_principal`." That sentence is
worth more than naming twenty Azure services.

---

## 8. If something in this folder does not work

The commands here were written against azurerm provider `~> 4.14`, AKS 1.31
and Azure CLI 2.67. Azure changes. When a command fails:

1. Read the actual error — Azure errors are unusually specific
2. Check `cheatsheets/troubleshooting.md` — the 20 most likely failures are there
3. `az <command> --help` is better than searching
4. The Terraform is the source of truth for *what* should exist; the portal is
   only ever a viewer in this project

Now go to [chapter 01](01-azure-account-setup.md).
