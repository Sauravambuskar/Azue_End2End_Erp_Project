# 09 — CI/CD pipelines, shared templates, environment promotion

**Time:** 5 hours · **Cost:** ₹0 (free tier covers it)
**Prerequisite:** chapter 08 complete

You will be asked to **walk through your pipeline**. This chapter makes sure
you can do it from memory, in order, explaining why each stage exists and why
it is in that position.

---

## 1. The shape, and why the order matters

```
┌─ BUILD ─────────────────────────────────────────────────────────┐
│  api_quality     ruff, mypy, pytest + 70% coverage gate         │
│  web_quality     eslint-security, npm audit, SBOM               │  parallel
│  sql_review      migration sequence, destructive-DDL check      │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─ SECURITY ──────────────────────────────────────────────────────┐
│  secrets         gitleaks           → HARD FAIL                 │
│  sast            bandit + semgrep   → fail on HIGH              │  parallel
│  sca             pip-audit + trivy  → fail on CRITICAL          │
│  iac_scan        checkov            → fail on policy            │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─ IMAGES ────────────────────────────────────────────────────────┐
│  for each of api / web / worker / migrate:                      │
│     build → trivy scan → SBOM → push                            │  parallel
│            (a vulnerable image never reaches the registry)      │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─ DEPLOY DEV ────────────────── automatic ───────────────────────┐
│  helm upgrade --atomic → smoke test (27 checks) → DAST          │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼  main branch only
┌─ DEPLOY TEST ───────────── 1 approver ──────────────────────────┐
│  helm upgrade --atomic → smoke test                             │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼  main branch only
┌─ DEPLOY PROD ───── 2 approvers + change ticket + window ────────┐
│  change_control → helm upgrade --atomic → smoke test            │
└─────────────────────────────────────────────────────────────────┘
```

### Four ordering decisions to be able to defend

**1. Fast feedback first.** Unit tests and linting run before the security
scans because they are faster and catch more day-to-day problems. A developer
should learn about a syntax error in 90 seconds, not after a six-minute
Semgrep run.

**2. Security gates before image build.** There is no point spending four
minutes building and pushing four images if the code has a hardcoded secret in
it. The stage dependency means a failed scan produces **no artefact at all**.

**3. Scan the image before pushing it.** Build locally, scan, *then* push.
A pipeline that pushes first and scans after has already published the
vulnerable image — anything watching the registry can pull it, and in a
GitOps setup it may already be deploying.

**4. Smoke test after every deploy, including prod.** Readiness probes tell
you a process is listening. Only a business-level test tells you the system is
correct. Ours creates a purchase order, receives it, sells the stock, invoices
it and asserts the general ledger balances.

---

## 2. Walk the real files

Read them in this order:

| Order | File | What to notice |
|---|---|---|
| 1 | [`pipelines/azure-pipelines.yml`](../pipelines/azure-pipelines.yml) | the stage graph and how templates are called |
| 2 | [`templates/variables-common.yml`](../pipelines/templates/variables-common.yml) | **pinned tool versions**, no secrets |
| 3 | [`templates/job-python-quality.yml`](../pipelines/templates/job-python-quality.yml) | caching, the explicit coverage gate |
| 4 | [`templates/job-secret-scan.yml`](../pipelines/templates/job-secret-scan.yml) | PR scans the diff, main scans full history |
| 5 | [`templates/job-build-image.yml`](../pipelines/templates/job-build-image.yml) | build → scan → SBOM → push |
| 6 | [`templates/stage-deploy.yml`](../pipelines/templates/stage-deploy.yml) | deployment jobs, `on: failure`, diagnostics |
| 7 | [`azure-pipelines-infra.yml`](../pipelines/azure-pipelines-infra.yml) | plan → approve → apply **the saved plan** |

### The detail in `variables-common.yml` worth calling out

```yaml
- name: trivyVersion
  value: "0.58.1"
```

**Every tool version is pinned.** Not `latest`. Two reasons:

1. **Reproducibility.** A build that passed yesterday and fails today with no
   code change is the worst kind of failure to debug.
2. **Supply chain.** `latest` means you automatically execute whatever was
   published to that tag an hour ago. A compromised release goes straight into
   your pipeline. Pinning means an upgrade is a reviewed PR.

> *"The pipeline pins every tool version, so upgrading a scanner is a pull
> request with a diff rather than something that happens to you overnight."*

---

## 3. The plan/apply split in the infra pipeline

This is the control worth the most in an interview, because it is the one that
prevents a pipeline from deleting a production database.

```yaml
# PLAN stage
terraform plan -out=tfplan -detailed-exitcode
terraform show -no-color tfplan > tfplan.txt

- publish: $(workingDirectory)/tfplan       # the BINARY plan is the artefact
  artifact: tfplan-dev

# APPLY stage, after approval
- download: current
  artifact: tfplan-dev
terraform apply -auto-approve tfplan        # applies THE SAVED PLAN
```

**Why applying the saved plan matters.** If `apply` ran a fresh `plan`, the
approver signed off on *a* plan and the pipeline executed *a different* one —
the state could have changed, someone could have merged, a data source could
have returned something new. Consuming the binary plan file means what was
approved is byte-for-byte what runs. If the state has moved on, Terraform
refuses the stale plan rather than silently doing something else.

### `-detailed-exitcode` — the flag people miss

| Exit code | Meaning |
|---|---|
| 0 | success, **no changes** |
| 1 | error |
| 2 | success, **changes present** |

That lets you skip the approval and the apply entirely when there is nothing
to do — no 2 a.m. approval request for a no-op run.

---

## 4. Run it and read the output

```bash
az pipelines run --name "ContosoERP-CI" --branch main
az pipelines runs list --pipeline-name "ContosoERP-CI" --top 3 \
  --query '[].{id:id, status:status, result:result, branch:sourceBranch}' -o table

RUN_ID=<the id>
az pipelines runs show --id "$RUN_ID" --query '{status:status, result:result}' -o json

# Download the artefacts the security stages produced
az pipelines runs artifact download --run-id "$RUN_ID" \
  --artifact-name sast-reports --path ./artifacts
az pipelines runs artifact download --run-id "$RUN_ID" \
  --artifact-name container-scan-erp-api --path ./artifacts
```

**Read the SBOM.** It is the thing most people generate and never look at:

```bash
jq '.components | length' artifacts/erp-api.cdx.json
jq -r '.components[] | "\(.name) \(.version)"' artifacts/erp-api.cdx.json | head -25
```

That is the complete inventory of what is inside your running container. When
the next Log4j-class CVE drops, this file is how you answer "are we affected"
in minutes instead of days.

---

## 5. Making the gates fail — do all four

A gate you have never seen fail is a gate you do not understand.

### Gate 1 — secrets (hard fail)

```bash
git checkout -b test/leak-secret
cat >> src/erp-api/app/core/config.py <<'EOF'

# Deliberate test of the secret scanning gate
AZURE_STORAGE = "DefaultEndpointsProtocol=https;AccountName=stleaktest;AccountKey=aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcd==;EndpointSuffix=core.windows.net"
EOF
git commit -am "test: secret scanning gate" && git push -u origin test/leak-secret
```

Expected: the `secrets` job fails with `azure-storage-connection-string`,
redacted in the log. Note that the **PR build scans only the diff** while a
main build scans **full history** — see the branch logic in the template.

```bash
git reset --hard HEAD~1 && git push -f
git checkout main && git branch -D test/leak-secret
git push origin --delete test/leak-secret
```

### Gate 2 — SAST

```bash
git checkout -b test/sast
cat >> src/erp-api/app/services.py <<'EOF'


def unsafe_report(db, table_name: str):
    """Deliberate SQL injection to test the SAST gate."""
    import subprocess
    from sqlalchemy import text
    # Bandit B608: hardcoded_sql_expressions
    rows = db.execute(text(f"SELECT * FROM {table_name}")).all()
    # Bandit B602: subprocess with shell=True
    subprocess.run(f"echo exported {table_name}", shell=True)
    return rows
EOF
git commit -am "test: SAST gate" && git push -u origin test/sast
```

Expected: Bandit flags **B608** (string-built SQL) and **B602**
(`shell=True`), Semgrep flags the OWASP injection rules, and the job fails at
HIGH severity.

### Gate 3 — dependency scan

```bash
git checkout -b test/sca
# A version with known critical CVEs
sed -i 's/^fastapi==.*/fastapi==0.65.0/' src/erp-api/requirements.txt
git commit -am "test: SCA gate" && git push -u origin test/sca
```

Expected: pip-audit reports the advisories and the job fails.

Now practise the **accepted-risk** path:

```bash
cat >> security/sca-accepted-risks.txt <<EOF
GHSA-8h2j-cgx8-6xv7  $(date -u -d '+30 days' +%Y-%m-%d)  Testing the accepted-risk mechanism only. Not a real acceptance.
EOF
git commit -am "test: accepted risk register" && git push
```

The build passes. Now prove the expiry is enforced:

```bash
sed -i "s|GHSA-8h2j-cgx8-6xv7.*|GHSA-8h2j-cgx8-6xv7  2020-01-01  Expired on purpose.|" \
  security/sca-accepted-risks.txt
git commit -am "test: expired accepted risk" && git push
```

The build **fails** with "Accepted risk ... expired on 2020-01-01". That
mechanism is the answer to "how do you stop the exception list growing
forever", and it is worth describing.

### Gate 4 — container scan

```bash
git checkout -b test/container
sed -i 's|^FROM python:3.12-slim AS final|FROM python:3.9-slim AS final|' src/erp-api/Dockerfile
git commit -am "test: container scan gate" && git push -u origin test/container
```

Expected: Trivy finds fixable criticals in the older base image and the push
never happens. Note `--ignore-unfixed` in the gate — a CVE with no available
patch cannot be fixed by this build, so blocking on it just teaches people to
bypass the gate. It is still reported in the full table above the gate.

Clean up all four:

```bash
git checkout main
for b in test/leak-secret test/sast test/sca test/container; do
  git branch -D "$b" 2>/dev/null
  git push origin --delete "$b" 2>/dev/null
done
git checkout -- .
```

---

## 6. Shared templates for multiple teams — the JD asks for this explicitly

### The problem

Five solution teams. Each writes its own pipeline. Each implements SAST
slightly differently; two forget secret scanning; one pins no tool versions.
When the security team tightens a rule, five PRs are needed and two never
happen.

### The pattern, in three levels

```
Level 1 — step templates    reusable step sequences
          steps-iac-scan.yml

Level 2 — job templates     a complete job with parameters
          job-sast.yml, job-secret-scan.yml, job-build-image.yml,
          job-dependency-scan.yml, job-python-quality.yml, job-node-quality.yml

Level 3 — stage templates   a whole stage with environments and approvals
          stage-deploy.yml
```

A consuming team writes very little:

```yaml
# Another team's pipeline, in their own repository
resources:
  repositories:
    - repository: platform
      type: git
      name: ContosoERP/erp-platform
      ref: refs/tags/pipeline-templates-v1.4.0   # PINNED, not a branch

stages:
  - stage: security
    jobs:
      - template: pipelines/templates/job-secret-scan.yml@platform
      - template: pipelines/templates/job-sast.yml@platform
        parameters:
          failOnSeverity: HIGH
      - template: pipelines/templates/job-dependency-scan.yml@platform
```

### The three things that make this actually work

**1. Pin to a tag, not a branch.** `ref: refs/heads/main` means the platform
team can break every team's pipeline with one merge. A tag means consumers
upgrade deliberately. Then you communicate changes with a changelog, and
deprecate with a warning step before removing anything.

**2. Make the template opinionated but parameterised.** `failOnSeverity` is a
parameter so a legacy app can start at CRITICAL and tighten over time. But
there is no parameter to *disable* the scan — the gate is not optional, only
its threshold is.

**3. Enforce it with the required-template check.** Chapter 08 §5. Without
that, teams can simply not use your templates. With it, a pipeline that does
not extend the approved template cannot deploy to prod. **Templates make the
right thing easy; the required-template check makes the wrong thing
impossible.** Both halves are needed.

> *"Shared templates give you leverage: when we added SBOM generation it
> appeared in every team's next build with no action from them. The two things
> that make it work rather than become a liability are versioning via tags,
> so we cannot break five teams with one merge, and the required-template
> check on the production environment, so using the templates is not
> optional."*

---

## 7. Environment promotion

### The flow

```
feature branch → PR → CI only (no deploy)
merge to main  → CI → dev (auto) → test (approval) → prod (approval + ticket)
```

**The same image artefact is promoted**, not rebuilt. `imageTag` is
`1.0.$(Build.BuildId)`, computed once in the CI stage and passed to every
deploy stage. If each environment rebuilt, you would be testing a different
binary than you ship — a different base-image digest, a different transitive
dependency resolution.

> *"What is tested in test is bit-for-bit what reaches production. Only the
> configuration changes between environments, and that comes from a different
> values file."*

### What differs between environments

| | dev | test | prod |
|---|---|---|---|
| Values file | `values-dev.yaml` | `values-dev.yaml` | `values-prod.yaml` |
| Replicas | 1 | 1 | 3 |
| Auth enabled | no | no | **yes** |
| Key Vault CSI | no | yes | yes |
| Ingress | port-forward | internal | App Gateway + TLS |
| PDB | off (1 replica) | off | on, minAvailable 2 |
| Approval | none | 1 | 2 + ticket + window |
| DAST | yes | no | no |

### The change-ticket gate

```yaml
if ! echo "$TICKET" | grep -Eq '^(CHG|RFC)-[0-9]{4,}$'; then
  echo "##vso[task.logissue type=error]CHANGE_TICKET is not of the form CHG-1234"
  exit 1
fi
```

In a real organisation this calls ServiceNow or Jira to verify the change is
approved and in window. Here it validates the format, which demonstrates the
control point. Be honest about that distinction if asked.

### Run a promotion

```bash
az pipelines run --name "ContosoERP-CI" --branch main \
  --variables CHANGE_TICKET=CHG-20260117

# Then approve in the UI: Pipelines → the run → Review → Approve
```

---

## 8. Rollback — have an answer ready

### Three levels, fastest first

```bash
# 1. Helm rollback (seconds) - the first thing you do
helm -n erp history erp
helm -n erp rollback erp 3
kubectl -n erp rollout status deploy/erp-api

# 2. Redeploy the previous image tag (minutes) - no rebuild
helm upgrade erp k8s/helm/erp -n erp --reuse-values \
  --set image.tag=1.0.1247 --atomic --wait

# 3. Re-run the previous successful pipeline run (the auditable path)
az pipelines runs list --pipeline-name "ContosoERP-CI" \
  --result succeeded --top 5 --query '[].{id:id, num:buildNumber}' -o table
```

### What `--atomic` already did for you

If a deploy fails readiness, Helm rolls back **automatically** before the
pipeline stage even reports failure. So the common case needs no human action
— the stage goes red and production is still on the last good revision. That
is a much better answer than "we would roll back manually".

### The rollback that does not work — say this unprompted

**A database migration cannot be rolled back by Helm.** If `V004` added a
NOT NULL column and you roll the application back to code that does not
populate it, inserts fail.

The answer is **backward-compatible migrations**:

- add columns nullable, never NOT NULL in the same release
- never rename or drop a column in the release that stops using it; do that
  two releases later
- deploy the schema change first, the code that uses it second

That is the expand/contract pattern, and knowing that the rollback story
breaks at the database is a mark of someone who has actually done it.

---

## 9. Break it on purpose

**Exercise A — a deploy that fails readiness**

```bash
git checkout -b test/bad-deploy
# Point the config at a database that does not exist
sed -i 's|host: psql-.*|host: nonexistent.postgres.database.azure.com|' k8s/helm/erp/values-dev.yaml
git commit -am "test: failing deployment" && git push -u origin test/bad-deploy
az pipelines run --name "ContosoERP-CI" --branch test/bad-deploy
```

Watch: pods start but never become ready → `helm --wait` times out →
`--atomic` rolls back → the `on: failure` block collects events, describes
pods and dumps logs into the pipeline log. **Read that diagnostic output** —
it is what you would read at 2 a.m., and it is why the block exists.

```bash
git checkout main && git branch -D test/bad-deploy
git push origin --delete test/bad-deploy
```

**Exercise B — a migration that fails**

```bash
cat > db/migrations/V006__will_fail.sql <<'EOF'
BEGIN;
-- References a table that does not exist
ALTER TABLE nonexistent_table ADD COLUMN x INT;
INSERT INTO schema_version(version) VALUES ('V006') ON CONFLICT DO NOTHING;
COMMIT;
EOF
```

Deploy it and observe: the Helm **pre-upgrade hook** fails, so the upgrade
never proceeds and the old pods keep serving. The application is never exposed
to a half-migrated schema.

```bash
kubectl -n erp get jobs
kubectl -n erp logs -l app.kubernetes.io/component=migrate --tail=20
rm db/migrations/V006__will_fail.sql
```

**Exercise C — the coverage gate**

```bash
git checkout -b test/coverage
cat >> src/erp-api/app/services.py <<'EOF'


def completely_untested_function_a(x): return x * 2
def completely_untested_function_b(x): return x * 3
def completely_untested_function_c(x): return x * 4
def completely_untested_function_d(x): return x * 5
def completely_untested_function_e(x): return x * 6
EOF
git commit -am "test: coverage gate" && git push -u origin test/coverage
```

If coverage drops below 70% the gate fails with the actual percentage. The
point of enforcing it in the pipeline *as well as* in `pyproject.toml` is that
the threshold is visible to anyone reading the pipeline, not buried in a
config file.

---

## 10. Interview answers this chapter gives you

**"Walk me through your CI/CD pipeline."** *(have this ready verbatim)*

> Six stages. **Build** runs in parallel: Python lint, type-check and unit
> tests with a 70% coverage gate; ESLint with the security plugin plus
> `npm audit` for the Node tier; and a SQL review job that checks the migration
> sequence has no gaps and blocks destructive DDL unless it carries an explicit
> marker. **Security** also runs in parallel: Gitleaks, which is a hard fail
> because a leaked credential is already compromised; Bandit and Semgrep for
> SAST, failing on HIGH; pip-audit and Trivy filesystem for dependencies,
> failing on CRITICAL with an expiring accepted-risk register; and Checkov for
> the Terraform and the rendered Helm chart. **Images** builds all four
> containers, and the order inside that job is deliberate — build locally,
> Trivy scan, generate a CycloneDX SBOM, and only then push, so a vulnerable
> image never reaches the registry. Then three **deploy** stages: dev
> automatically, test behind one approval, prod behind two approvers, a
> business-hours window, an exclusive lock and a change-ticket check. Each
> deploy uses `helm upgrade --atomic --wait`, so a failed rollout rolls itself
> back, and each is followed by a smoke test that drives a real business
> transaction and asserts the general ledger balances. Dev also gets a ZAP
> baseline DAST scan. The same image tag is promoted through all three
> environments — nothing is rebuilt — and everything reusable is a template in
> `pipelines/templates` so other teams get the same gates by reference.

**"How do you share pipeline logic across teams?"**

> Templates at three levels: step templates for a reusable sequence, job
> templates for a complete job with parameters, and stage templates for a
> whole deployment stage including the environment and its approvals. Teams
> reference them from a central repository pinned to a **tag**, not a branch —
> pinning to a branch means the platform team can break five teams' pipelines
> with one merge. The templates are opinionated but parameterised: a legacy
> app can start with `failOnSeverity: CRITICAL` and tighten over time, but
> there is no parameter that disables a scan. And the piece that makes it real
> rather than optional is the required-template check on the production
> environment, so a pipeline that does not extend the approved template simply
> cannot deploy there. Templates make the right thing easy; the check makes the
> wrong thing impossible.

**"A deployment broke production. What is your process?"**

> First, is it already fixed — we deploy with `helm upgrade --atomic`, so a
> rollout that fails readiness rolls itself back before the stage even reports
> failure, and production is still on the last good revision. If the deploy
> succeeded but the behaviour is wrong, `helm rollback` to the previous
> revision takes seconds, and I do that before investigating: restore service
> first, diagnose second. Then I look at what the pipeline captured — the
> `on: failure` hook dumps namespace events, pod descriptions and container
> logs into the run, so I am not starting from nothing. Then App Insights for
> the failure signature and Log Analytics for the kube-audit trail. The one
> case where this does not work is a database migration: Helm cannot roll that
> back, so migrations have to be backward compatible — columns added nullable,
> nothing renamed or dropped in the same release that stops using it, schema
> first and code second. If a migration is genuinely incompatible, the recovery
> is a point-in-time restore, which is a much more serious event, and that is
> precisely why migrations get reviewed separately and the pipeline blocks
> destructive DDL.

**"How long does your pipeline take, and would you change anything?"**

> Roughly eight to ten minutes to dev: about two for build and test, two for
> the security stages running in parallel, three for four image builds, and
> two for the deploy and smoke test. The things that keep it there are
> parallelism within stages, pip and npm caching, and Docker layer caching. If
> I needed it faster I would add path filters so a change under `src/erp-web`
> does not rebuild the Python images — that is real waste today. What I would
> *not* do is move the security gates to a nightly scheduled scan to speed up
> the main run. That is a common suggestion and it inverts the control: by the
> time the nightly scan finds the secret, it has been merged and deployed.

---

## Checklist

- [ ] You can draw the stage graph from memory
- [ ] You can justify all four ordering decisions, especially scan-before-push
- [ ] You know why every tool version is pinned
- [ ] You can explain why `apply` consumes the **saved** plan
- [ ] You know `-detailed-exitcode` returns 2 for "changes present"
- [ ] Pipeline run green end to end
- [ ] **You read an SBOM** and know why it exists
- [ ] **All four gates deliberately failed**: secrets, SAST, SCA, container
- [ ] Accepted-risk register tested, including the expiry failure
- [ ] You can explain the three template levels and tag pinning
- [ ] You can explain why templates alone are insufficient without the required-template check
- [ ] You know the same image is promoted, not rebuilt
- [ ] You can explain all three rollback levels, and that `--atomic` usually acts first
- [ ] **You can explain why a migration cannot be rolled back, and expand/contract**
- [ ] All three "break it" exercises done; you read the failure diagnostics

Next: [chapter 10 — DevSecOps gates](10-devsecops-gates.md)
