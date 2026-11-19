            # JD coverage matrix

            Every requirement from the job description, mapped to the artefact in this
            repository that proves it and the chapter that teaches it.

            > Source: the original requirement email is kept at
            > [`plan.md`](../../plan.md) in the repository root, so this mapping stays
            > checkable against what was actually asked for.

            Tick the "Done" box only when you have **built it, broken it, and fixed it** —
            not when you have read about it.

            ---

            ## Key Responsibilities

            | # | JD requirement | Where it lives in this repo | Chapter | Done |
            |---|---|---|---|---|
            | 1 | Design and implement Azure Landing Zones, management groups, subscription structure, resource groups, policies and RBAC model | `scripts/create-management-groups.sh`, `infra/terraform/modules/naming`, `policy/`, `infra/terraform/modules/identity` | 02, 12 | ☐ |
            | 2 | Build and manage secure AKS platforms for microservices and containerized applications | `infra/terraform/modules/aks`, `k8s/helm/erp`, `k8s/base` | 05 | ☐ |
            | 3 | Configure Azure Firewall, Application Gateway WAF, VNets, private endpoints, NSGs and hub-spoke networking | `modules/network`, `modules/network/nsg.tf`, `modules/firewall`, `modules/appgw` | 03 | ☐ |
            | 4 | Implement Microsoft Entra ID integration, Okta SSO/MFA, managed identities, service principals and access controls | `modules/identity`, `app/core/security.py`, `k8s/base/rbac.yaml` | 04 | ☐ |
            | 5 | Develop and maintain Azure DevOps CI/CD pipelines using YAML, shared templates, approvals and environment promotion | `pipelines/azure-pipelines.yml`, `pipelines/templates/*` | 08, 09 | ☐ |
            | 6 | Create Infrastructure as Code using Terraform and/or Bicep | `infra/terraform/` (11 modules), `infra/bicep/` | 02–06 | ☐ |
            | 7 | Integrate DevSecOps controls: SAST, DAST, dependency scanning, container image scanning, secrets scanning | `pipelines/templates/job-sast.yml`, `job-dependency-scan.yml`, `job-secret-scan.yml`, `job-build-image.yml`, `steps-iac-scan.yml`, `security/` | 10 | ☐ |
            | 8 | Implement Azure Key Vault, Microsoft Defender for Cloud, Azure Policy and security posture monitoring | `modules/keyvault`, `k8s/helm/erp/templates/secretproviderclass.yaml`, `policy/` | 07, 12 | ☐ |
            | 9 | Set up Azure Monitor, Application Insights, Log Analytics, alerts and operational dashboards | `modules/monitor` (incl. `dashboard.tf`), `app/core/telemetry.py` | 11 | ☐ |
            | 10 | Collaborate with architects, developers, security and operations teams | `guidance/14-runbook.md`, `k8s/base/rbac.yaml` (per-team RBAC), PR/approval flow | 09, 14 | ☐ |

            ---

            ## Required Skills — by skill area

            ### Azure Platform
            | Skill | Artefact | Done |
            |---|---|---|
            | Azure Landing Zones | `scripts/create-management-groups.sh`, chapter 02 | ☐ |
            | Management Groups | management group hierarchy with policy inheritance | ☐ |
            | Subscriptions | subscription-per-environment model, chapter 02 §3 | ☐ |
            | Azure Policy | 4 custom definitions + initiative in `policy/` | ☐ |
            | RBAC | `modules/identity` group assignments, `k8s/base/rbac.yaml` | ☐ |
            | Resource groups | `modules/naming` → rg_platform / rg_data / rg_aks / rg_network | ☐ |
            | Tagging standards | `modules/naming` tags output + `require-mandatory-tags.json` enforcing it | ☐ |

            ### Networking & Security
            | Skill | Artefact | Done |
            |---|---|---|
            | Azure Firewall | `modules/firewall` with the real AKS FQDN allow-list + UDR | ☐ |
            | Application Gateway WAF | `modules/appgw` — OWASP 3.2, rule overrides, custom rules, rate limit | ☐ |
            | VNets | hub 10.0.0.0/16 + spoke 10.10.0.0/16, peered, `modules/network` | ☐ |
            | NSGs | `modules/network/nsg.tf` — 3 NSGs, explicit deny-all last | ☐ |
            | Private Endpoints | 7 private DNS zones + PEs for ACR/KV/PG/Blob/Cosmos/SB | ☐ |
            | Key Vault | `modules/keyvault` RBAC mode, purge protection, PE | ☐ |
            | Defender for Cloud | `microsoft_defender` block in `modules/aks`, chapter 12 | ☐ |

            ### AKS & Containers
            | Skill | Artefact | Done |
            |---|---|---|
            | AKS | `modules/aks` — private cluster, Entra RBAC, workload identity | ☐ |
            | Docker | 4 hardened multi-stage Dockerfiles, non-root, read-only rootfs | ☐ |
            | Kubernetes | Deployments, Services, CronJob, Job hook, HPA, PDB, quotas | ☐ |
            | Helm | `k8s/helm/erp` — helpers, hooks, per-env values, `--atomic` | ☐ |
            | ACR | `modules/acr` — no admin user, AcrPull only, retention, quarantine | ☐ |
            | Kubernetes RBAC | `k8s/base/rbac.yaml` bound to Entra **groups** by object id | ☐ |
            | Ingress | `templates/ingress.yaml` + AGIC add-on | ☐ |
            | Autoscaling | HPA (v2, with behaviour) + cluster autoscaler + `auto_scaler_profile` | ☐ |
            | Container security | PSA restricted, seccomp, dropped caps, Trivy gate, image cleaner | ☐ |

            ### DevOps & IaC
            | Skill | Artefact | Done |
            |---|---|---|
            | Azure DevOps | org/project/repo/environments, chapter 08 | ☐ |
            | Git | branch policy, PR validation trigger, forward-only migrations | ☐ |
            | YAML pipelines | `pipelines/` — 3 pipelines, 9 reusable templates | ☐ |
            | Terraform | 11 modules + dev root module, remote state with locking | ☐ |
            | Bicep | `infra/bicep/` — the same landing zone, for comparison | ☐ |
            | Release approvals | Environment checks on `erp-test` / `erp-prod` | ☐ |
            | Environment promotion | dev (auto) → test (approval) → prod (approval + change ticket) | ☐ |

            ### DevSecOps
            | Skill | Artefact | Done |
            |---|---|---|
            | SAST | Bandit + Semgrep, `job-sast.yml`, hard fail on HIGH, **plus 9 custom rules in `security/sast/semgrep-erp.yml`** | ☐ |
            | DAST | OWASP ZAP baseline post-deploy, `security/dast/zap-rules.tsv` | ☐ |
            | OWASP Top 10 | mapping table in chapter 10 §7, control per item | ☐ |
            | Dependency scanning | pip-audit + npm audit + Trivy fs, expiring accepted-risk register | ☐ |
            | Vulnerability management | `security/sca-accepted-risks.txt` with enforced expiry dates | ☐ |
            | Secret scanning | Gitleaks, custom Azure rules, full-history scan on main | ☐ |
            | Container scanning | Trivy before push, SBOM generated and retained | ☐ |

            ### Monitoring
            | Skill | Artefact | Done |
            |---|---|---|
            | Azure Monitor | `modules/monitor`, diagnostic settings on every resource | ☐ |
            | Application Insights | workspace-based, OTel in `app/core/telemetry.py` | ☐ |
            | Log Analytics | LAW with a daily cap, kube-audit-admin, ContainerLogV2 | ☐ |
            | Alerts | 2 metric alerts + 3 KQL alerts incl. a business-integrity alert | ☐ |
            | Dashboards | `modules/monitor/dashboard.tf` — dashboard as code | ☐ |
            | Platform observability | probes, `/metrics`, request ids correlated across tiers | ☐ |

            ---

            ## Nice to Have

            | Item | Artefact | Done |
            |---|---|---|
            | Enterprise manufacturing domain | ContosoERP: products, BOM-style components, warehouses, plant store | ☐ |
            | IoT / video analytics / AI-ML | Cosmos `device_telemetry` container, chapter 06 §8 extension | ☐ |
            | Asset management platform | inventory + reorder point + plant-store warehouse model | ☐ |
            | PostgreSQL | primary system of record, Flexible Server, pgaudit | ☐ |
            | Cosmos DB | `modules/cosmos` — serverless, audit trail + telemetry, data-plane RBAC | ☐ |
            | Azure Digital Twins | chapter 06 §8 — how it would slot in (not deployed: cost) | ☐ |
            | Azure OpenAI | chapter 06 §8 — reorder-forecast extension sketch | ☐ |
            | Event-driven architecture | Service Bus publisher in `erp-worker`, KEDA notes in chapter 05 | ☐ |
            | Shared CI/CD templates for multiple teams | `pipelines/templates/` designed for cross-team reuse, chapter 09 §6 | ☐ |
            | Entra ID + Okta SSO/MFA | `app/core/security.py` validates both issuers; chapter 04 §6 | ☐ |

            ---

            ## Evidence the platform actually works

            A JD matrix full of ticks proves nothing on its own. These are the artefacts
            that make the claims checkable, and the things to offer to show in an
            interview:

            | Evidence | Command | What it proves |
            |---|---|---|
            | 47 unit tests across three services | `./scripts/validate-local.sh` | the business logic is correct, including that the general ledger balances |
            | 27-check business smoke test | `./scripts/smoke-test.sh <url>` | a full purchase → receive → sell → invoice transaction works against a live deployment |
            | 20 CI gates, all green | `./scripts/validate-local.sh` | the same gates the pipeline runs, reproducible locally |
            | 0 secret-scanning findings | `gitleaks dir . --config security/secrets/gitleaks.toml` | no credential anywhere in the tree |
            | 132 checkov checks passed, 99 documented skips | `checkov -d infra/terraform` | every IaC exception has a written, checkable reason |
            | dev/prod delta in ~80 lines each | `diff infra/terraform/envs/{dev,prod}/main.tf` | prod is the same architecture, hardened by values |

            ## Key Deliverables (the JD's own list)

            | Deliverable | Where | Done |
            |---|---|---|
            | Azure Landing Zone | `infra/terraform/envs/dev` + management groups | ☐ |
            | Secure AKS Platform | `modules/aks` + `k8s/` | ☐ |
            | DevSecOps Pipelines | `pipelines/` | ☐ |
            | IaC Repository | `infra/` (this repo *is* the deliverable) | ☐ |
            | Monitoring & Alerts | `modules/monitor` | ☐ |
            | Security Controls | `policy/`, `security/`, NSGs, WAF, NetworkPolicy, PSA | ☐ |
            | Subscription Governance | `policy/initiatives/erp-landing-zone-baseline.json` | ☐ |
            | Platform Runbook | `guidance/14-runbook.md` | ☐ |

            ---

            ## Certifications mentioned

            You are **not** expected to hold these for the interview, but knowing which
            exam covers what lets you answer "how would you learn X" credibly.

            | Cert | Covers the parts of this project | Priority for you |
            |---|---|---|
            | AZ-104 Administrator | VNets, RBAC, storage, monitoring basics | Do first if you hold none |
            | AZ-400 DevOps Expert | pipelines, IaC, release strategy, security gates | **Most aligned with this JD** |
            | AZ-500 Security Engineer | Entra ID, Key Vault, Defender, Policy, network security | Second priority |
            | AZ-305 Solutions Architect | landing zones, resiliency, cost design | Later |
            | CKA / CKS | everything in chapter 05 | CKS maps almost 1:1 to chapter 05's security work |

            **If asked "do you have these certifications?"** and you do not: *"Not yet —
            AZ-400 is booked for <month>. What I do have is a platform I built end to end:
            landing zone, AKS, the DevSecOps pipeline and the runbook. Happy to walk
            through any part of it."* Then do exactly that.
