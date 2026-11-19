# 10 — DevSecOps gates: SAST, DAST, SCA, secrets, containers, IaC

**Time:** 5 hours · **Cost:** ₹0 (all the tooling is free/open source)
**Prerequisite:** chapter 09 complete

Six scanner types, each answering a different question. The interview value is
not naming the tools — anyone can — it is knowing **what each one cannot see**,
and what you do with a finding.

---

## 1. The six gates and what each one actually catches

| Gate | Question it answers | Tool here | Catches | **Blind to** |
|---|---|---|---|---|
| **Secrets** | is a credential in the repo? | Gitleaks | keys, tokens, connection strings, in history | a secret in a runtime env var; a secret with no recognisable pattern |
| **SAST** | is *our* code insecure? | Bandit, Semgrep | injection, weak crypto, `shell=True`, hardcoded paths | anything requiring runtime context; business-logic flaws |
| **SCA** | are our *dependencies* vulnerable? | pip-audit, npm audit, Trivy fs | known CVEs in declared packages | a vulnerability with no CVE yet; a vendored copy |
| **Container** | is the *image* vulnerable? | Trivy image | OS packages, language packages, misconfig, embedded secrets | a vulnerability in your own code |
| **IaC** | is the *infrastructure* misconfigured? | Checkov | public endpoints, missing encryption, open NSGs | drift after deployment |
| **DAST** | is the *running system* exploitable? | OWASP ZAP | missing headers, reflected XSS, auth bypass, SSRF | anything behind authentication it cannot reach |

**The point to make in an interview:** these are complementary, not
redundant. SAST reads code and cannot know the WAF blocks that path. DAST
probes the running app and cannot see the dead code path with the SQL
injection in it. SCA knows your dependency has a CVE but not whether you call
the vulnerable function. **You need all six, and none of them is sufficient.**

---

## 2. The gate policy — what blocks, what warns, and why

```
Secrets          → HARD FAIL, always, no exceptions
SAST HIGH+       → FAIL
SAST MEDIUM      → warn
Dependency CRIT  → FAIL
Dependency HIGH  → warn + entry in the accepted-risk register with an expiry
Container CRIT   → FAIL (fixable only)
Container HIGH   → warn
IaC policy       → FAIL on the defined check set
DAST             → warn, triaged by a human
```

### Defend each decision

**Secrets are a hard fail, always.** A leaked credential is compromised the
moment it is pushed. You cannot "fix it in the next sprint" — you have to
rotate. So the gate must block the merge. A warning gets merged and then you
are rotating a production credential at 11 p.m.

**Container criticals use `--ignore-unfixed`.** A CVE with no upstream patch
cannot be remediated by this build. Blocking on it does not improve security;
it teaches the team to add `--skip` flags, and then the gate stops working for
real findings. It is still *reported* in the full table above the gate, and it
belongs in the risk register, not in a blocker.

**DAST warns rather than fails.** Against an authenticated API, false
positives are common and a flaky gate destroys trust in all the others. DAST
output is triaged, and a confirmed finding becomes a work item with an SLA.

> *"The hardest part of a security gate is not adding it, it is keeping it
> credible. A gate that fires false positives gets bypassed within two
> sprints, and then you have the ceremony without the control. So I am
> deliberately strict where the signal is unambiguous — secrets, fixable
> criticals — and advisory where it is noisy."*

---

## 3. Secret scanning in depth

Config: [`security/secrets/gitleaks.toml`](../security/secrets/gitleaks.toml)

### Run it locally

```bash
# Working tree
gitleaks dir . --config security/secrets/gitleaks.toml --redact --verbose

# Full history - this is what the main-branch build does
gitleaks git . --config security/secrets/gitleaks.toml --redact --verbose

# Just this PR's commits - what the PR build does
gitleaks git . --log-opts="origin/main..HEAD" \
  --config security/secrets/gitleaks.toml --redact
```

### The custom rules, and why each exists

Beyond Gitleaks' defaults we added eight Azure-specific patterns. Each one
corresponds to a credential type that has actually caused incidents:

| Rule | Why it was added |
|---|---|
| `azure-storage-connection-string` | the single most-leaked Azure credential |
| `azure-sql-connection-string` | password inline in a connection string |
| `postgres-uri-with-password` | `postgresql://user:pass@host` in a config file |
| `azure-sas-token` | a SAS with a long expiry is a durable credential |
| `azure-ad-client-secret` | the thing workload identity exists to eliminate |
| `appinsights-connection-string` | low severity but it is a write key |
| `kubeconfig-client-certificate` | embedded cert = cluster admin |
| `terraform-state-inline-secret` | a literal password in a `.tf` or `.tfvars` |

### The allowlist discipline

```toml
[allowlist]
paths = [
  '''\.example$''',
  '''(^|/)guidance/''',        # the guide shows placeholders on purpose
]
regexes = [
  '''ChangeMeLocally123!''',
  '''password\s*=\s*var\.''',  # Terraform interpolation, not a literal
]
```

**Every allowlist entry is a hole you deliberately cut.** Keep them narrow and
reviewed. A path exclusion for `guidance/` is justifiable; one for `src/` is
not. Reviewing allowlist changes with the same seriousness as code is the
difference between a tuned scanner and a disabled one.

### A real worked example from this repository

The first time this config was run against the whole repo it reported **461
findings**. The repository contains no secrets. Three separate bugs, all in
the config rather than the code:

1. **`gitleaks dir` does not reliably honour `.gitignore`**, so it was
   scanning `.venv/` and `node_modules/` — 457 of the 461 findings were in
   third-party dependencies. Fixed by excluding those paths explicitly.
2. **The path patterns were written with `/` only.** Gitleaks reports paths
   using the host OS separator, so `(^|/)guidance/` matched nothing on
   Windows and the documented placeholders in this guide were all reported.
   Fixed by using `(^|[/\\])guidance[/\\]`.
3. **A custom rule had a bad negated character class.** The
   `terraform-state-inline-secret` regex excluded `$` to skip interpolation,
   but not `\` — so `TF_VAR_postgres_admin_password="\$(openssl rand ...)"`
   inside a heredoc matched. Fixed by excluding `\` and `v` (for `var.`) too.

After the fixes: **0 findings, and the scan time dropped from 75 seconds to
5 seconds.**

> **This is the single most useful thing in this chapter**, and it is worth
> telling as a story in an interview. A gate reporting 461 false positives is
> not a strict gate — it is a *disabled* gate, because the first thing anyone
> does is stop reading the output, and then the one real finding goes through
> with the noise. And the only way to discover the bugs was to run the
> scanner against a repository whose contents I already knew were clean.
> **Always validate a detection rule against a known-good and a known-bad
> input.** A rule you have never seen produce zero findings is a rule you
> cannot trust when it produces one.

### Remediation — the order matters

1. **Rotate the credential.** Now. It is compromised.
2. Remove it from history: `git filter-repo --invert-paths --path <file>`,
   force-push, everyone re-clones.
3. Check the audit logs for use of the credential between commit and rotation.
4. Fix the process: was the pattern missing, was the scan only on a diff, did
   somebody bypass the branch policy?

Deleting the line in a new commit removes nothing. It is still in history,
still in every clone, still reachable by SHA from any fork.

---

## 4. SAST in depth

### Why two tools

| | Bandit | Semgrep |
|---|---|---|
| Languages | Python only | 30+, incl. our Python and JS |
| Model | AST pattern matching with Python-specific knowledge | generic pattern language with maintained rulesets |
| Strength | understands Python idioms: `subprocess`, `pickle`, `yaml.load`, `assert` in prod | cross-language, OWASP ruleset, custom rules are easy |
| Weakness | Python only | less deep on language-specific idioms |

Running two overlapping *linters* would be waste. These have genuinely
different detection models, which is the justification.

### Run them

```bash
cd /d/Azure
BANDIT=src/erp-api/.venv/Scripts/bandit.exe   # or just `bandit` on PATH

# Report everything
"$BANDIT" -r src/erp-api/app src/erp-worker/app -f txt

# The gate: high severity only
"$BANDIT" -r src/erp-api/app src/erp-worker/app -lll

# Semgrep
pip install semgrep
semgrep scan --config p/owasp-top-ten --config p/secrets --config p/dockerfile src/
semgrep scan --config p/owasp-top-ten --severity ERROR --error src/
```

### The Bandit findings you will see in real code, and the right response

| ID | Finding | Usually the right fix |
|---|---|---|
| B101 | `assert` used | fine in tests (we exclude them); never rely on it in prod — `python -O` removes it |
| B105/B106 | hardcoded password string | real finding, always investigate |
| B108 | insecure `/tmp` usage | use `tempfile.mkstemp` |
| B201 | Flask debug mode | real finding |
| B324 | weak hash (md5, sha1) | if it is for a checksum, `usedforsecurity=False`; if for auth, fix it |
| B501 | `verify=False` on requests | real finding, fix it |
| B602 | `subprocess` with `shell=True` | pass a list, not a string |
| B608 | SQL built by string concatenation | parameterise |

### Writing a custom Semgrep rule — worth doing once

```yaml
# security/sast/semgrep-erp.yml
rules:
  - id: erp-no-raw-sql-fstring
    pattern: |
      $DB.execute(text(f"..."))
    message: >-
      SQL built with an f-string. Use bound parameters:
      db.execute(text("SELECT ... WHERE id = :id"), {"id": value})
    languages: [python]
    severity: ERROR
    metadata:
      cwe: "CWE-89: SQL Injection"
      owasp: "A03:2021 Injection"

  - id: erp-no-wildcard-cors-in-prod
    pattern: |
      CORSMiddleware(..., allow_origins=["*"], ...)
    message: Wildcard CORS with credentials is an A05 misconfiguration.
    languages: [python]
    severity: WARNING
```

The real file is [`security/sast/semgrep-erp.yml`](../security/sast/semgrep-erp.yml),
which has nine rules including an append-only-ledger rule and an SSRF rule for
the BFF.

```bash
semgrep scan --config security/sast/semgrep-erp.yml --error src/
```

**A custom rule encodes a lesson from your own incident history**, which is a
much better thing to describe than "we run the default ruleset".

### Validate a rule against known-good AND known-bad input

The first version of `erp-no-password-in-connection-string` was:

```yaml
- pattern-regex: 'postgres(ql)?(\+\w+)?://[^:/\s"]+:[^@/\s"]{4,}@'
```

It immediately fired on `app/core/config.py`:

```python
f"postgresql+psycopg://{self.db_user}:{pwd}@{self.db_host}:{self.db_port}"
```

That is a **template**, not a literal password — exactly the parameterised
form the rule is meant to encourage. A rule that flags the correct code is
worse than no rule: the team deletes it rather than fixing it. The fix was to
exclude `{` and `}` from the character classes so only a literal matches:

```yaml
- pattern-regex: 'postgres(ql)?(\+\w+)?://[^:/\s"{}]+:[^@/\s"{}]{4,}@'
```

Then verify **both** directions, which takes thirty seconds:

```bash
# Known-good: the real codebase must be clean
semgrep scan --config security/sast/semgrep-erp.yml --error --quiet src/

# Known-bad: the rule must still catch an actual literal
cat > /tmp/tc.py <<'EOF'
BAD = "postgresql://erpadmin:SuperSecret123@psql-prod.postgres.database.azure.com/erp"
EOF
semgrep scan --config security/sast/semgrep-erp.yml /tmp/tc.py   # must find 1
```

> A detection rule you have only ever seen produce *zero* findings, or only
> ever *non-zero* findings, is untested. You need both, every time. This is
> the same lesson as the Gitleaks worked example above, and it is the single
> most transferable idea in this chapter.

---

## 5. Dependency scanning and the accepted-risk register

```bash
# Python
pip install pip-audit
pip-audit -r src/erp-api/requirements.txt --format columns
pip-audit -r src/erp-worker/requirements.txt --format columns

# Node - production dependencies only, because a dev-only advisory
# never reaches the running container
cd src/erp-web && npm audit --audit-level=high --omit=dev; cd /d/Azure

# Everything at once, plus Dockerfile misconfiguration
trivy fs . --scanners vuln,misconfig,secret --severity HIGH,CRITICAL
```

### The register, and why it is the interesting part

[`security/sca-accepted-risks.txt`](../security/sca-accepted-risks.txt):

```
# <advisory-id>  <expiry YYYY-MM-DD>  <reason>
GHSA-xxxx-yyyy  2026-03-31  No upstream fix; exploit needs local file write
                            which the read-only rootfs prevents.
```

The pipeline enforces two rules:

1. **Every entry must have an expiry date.**
2. **When the date passes, the build fails** until the entry is renewed with a
   fresh justification or the dependency is patched.

> *"Finding CVEs is the easy part — the scanner does it. The hard part is
> stopping the exception list growing without bound, which is how
> organisations end up with a four-year-old Log4j. So every acceptance has an
> expiry date and the build fails when it lapses. The decision to accept is
> still a human one, but it cannot be a permanent one by accident."*

### A real triage walkthrough

Not every CVE needs action. The questions, in order:

1. **Is the vulnerable code path reachable from our application?** A CVE in a
   library's CLI entry point we never invoke is different from one in the
   function we call on every request.
2. **Is there a fix?** No patch means remediation is mitigation, not upgrade.
3. **What does an exploit require?** Local file write? We have a read-only
   root filesystem. Network access to an internal port? NetworkPolicy
   default-denies it.
4. **What is the blast radius if exploited?** The API has `erp_app`, which is
   DML only and cannot touch the GL.

That reasoning — reachability, patch availability, preconditions, blast radius
— is what distinguishes vulnerability *management* from vulnerability
*scanning*, and it is a strong answer.

---

## 6. Container scanning and image hardening

### Scan

```bash
ACR=$(cd infra/terraform/envs/dev && terraform output -raw acr_login_server)

trivy image "${ACR}/erp-api:v0.1.0" --scanners vuln,secret,misconfig
trivy image "${ACR}/erp-api:v0.1.0" --severity CRITICAL --ignore-unfixed --exit-code 1
trivy image "${ACR}/erp-api:v0.1.0" --format cyclonedx --output sbom.cdx.json
```

### What makes our Dockerfiles hard — and the measurable effect

Read [`src/erp-api/Dockerfile`](../src/erp-api/Dockerfile).

| Technique | Effect |
|---|---|
| Multi-stage build | `build-essential` and compilers are in the builder stage only; the final image cannot compile an exploit |
| Non-root `USER 10001` | required by the Gatekeeper constraint; a container escape starts unprivileged |
| `apt-get upgrade` in final stage | picks up base-image CVEs patched since the tag was published |
| `rm -rf /var/lib/apt/lists/*` | smaller image, and no package index to work from |
| OCI labels | version and git SHA traceable from a running container |
| `HEALTHCHECK` | Docker-level health independent of Kubernetes probes |
| `--proxy-headers` on uvicorn | correct client IP behind App Gateway, so rate limiting and logs are accurate |
| No shell in the entrypoint | `ENTRYPOINT ["uvicorn", ...]` is exec form; signals reach PID 1, so SIGTERM works |

```bash
# Compare base image choices yourself
for img in python:3.12 python:3.12-slim python:3.12-alpine; do
  docker pull -q "$img" >/dev/null
  size=$(docker image inspect "$img" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}')
  crit=$(trivy image "$img" --severity CRITICAL,HIGH --quiet --format json 2>/dev/null \
          | jq '[.Results[].Vulnerabilities // [] | length] | add // 0')
  printf '%-24s %-10s %s HIGH+CRITICAL\n' "$img" "$size" "$crit"
done
```

You will see `slim` is dramatically smaller and cleaner than the full image.
Alpine is smaller still but uses musl libc, which breaks some Python wheels and
forces source builds — a real trade-off, not a free win. **Being able to say
"we chose slim over alpine because musl broke our binary wheels" is better
than "we use alpine because it's smaller".**

### The next level — distroless, and why we did not

```dockerfile
FROM gcr.io/distroless/python3-debian12:nonroot
```

No shell, no package manager, no `ls`. Enormous attack-surface reduction. The
cost: you cannot `kubectl exec` in to debug, which matters a lot while
learning. The honest answer: **distroless for production, slim for
development**, and use `kubectl debug --image` with an ephemeral container when
you need to inspect a distroless pod.

### Registry-side controls

```bash
ACR_NAME=$(cd infra/terraform/envs/dev && terraform output -raw acr_name)

# Confirm the admin user is off - no shared username/password exists
az acr show -n "$ACR_NAME" --query '{admin:adminUserEnabled, anon:anonymousPullEnabled, public:publicNetworkAccess}' -o json

# ACR's own scanning, via Defender for Containers
az acr repository show-tags -n "$ACR_NAME" --repository erp-api -o table
```

On Premium you also get **quarantine**: a pushed image is unpullable until a
scanner marks it passed. That moves the gate from "the pipeline should scan" to
"the registry will not serve an unscanned image" — a control rather than a
convention.

---

## 7. IaC scanning

```bash
pip install checkov

# Terraform
checkov -d infra/terraform --framework terraform --compact --quiet

# Rendered Helm - scanning raw templates produces noise from the {{ }}
helm template erp k8s/helm/erp -f k8s/helm/erp/values-prod.yaml \
  --set azure.workloadIdentity.api.clientId=00000000-0000-0000-0000-000000000000 \
  --set azure.tenantId=00000000-0000-0000-0000-000000000000 \
  --set config.keyVault.name=placeholder > /tmp/rendered.yaml
checkov -f /tmp/rendered.yaml --framework kubernetes --compact

# Dockerfiles
checkov -d src --framework dockerfile --compact

# Bicep compiles to ARM, which Checkov also understands
bicep build infra/bicep/landing-zone.bicep --outfile /tmp/lz.json
checkov -f /tmp/lz.json --framework arm --compact
```

### Suppressions with justification — the reviewable way

**The comment must be INSIDE the resource block, not above it.** A skip
comment above the `resource` line is silently ignored — Checkov reports
`Skipped checks: 0` and you think your suppressions worked when they did not.
This is the single most common Checkov mistake:

```hcl
# WRONG - silently ignored
# checkov:skip=CKV_AZURE_110:reason
resource "azurerm_key_vault" "this" {
  name = var.name
}

# RIGHT - inside the block
resource "azurerm_key_vault" "this" {
  # checkov:skip=CKV_AZURE_110:Purge protection is controlled by
  #   var.purge_protection. envs/prod sets it true. It is deliberately false
  #   in dev because it is irreversible and would lock the vault name for up
  #   to 90 days after every teardown.
  name = var.name
}
```

Always verify a suppression took effect by reading the summary line:

```bash
checkov -d infra/terraform --framework terraform --compact --quiet
# Passed checks: 132, Failed checks: 0, Skipped checks: 99
#                                                      ^^ this number must
#                                                         match what you wrote
```

Put the reason in the comment, not in a CLI `--skip-check` flag, where nobody
reviewing the Terraform will ever see it. **A bare skip with no written reason
should fail code review** — and the reason should name the *variable or
control* that makes the finding acceptable, so a reviewer can verify it rather
than take it on trust:

```hcl
# Good: a reviewer can check that envs/prod actually sets this
# checkov:skip=CKV_AZURE_115:Controlled by var.private_cluster. envs/prod sets true.

# Bad: unfalsifiable
# checkov:skip=CKV_AZURE_115:Not needed for our use case.
```

### What this repository's suppressions look like

Running Checkov over `infra/terraform` initially gave **30 failures**. Working
through them produced three categories, which is typical:

| Category | Count | Action |
|---|---|---|
| **Genuine gaps** | 4 | **Fixed.** Three subnets had no NSG at all (`CKV2_AZURE_31`) — the Bastion, shared-services and PostgreSQL subnets. Added, including the full Microsoft-required Bastion rule set. Plus host encryption on the AKS node pools. |
| **Dev-vs-prod posture, already parameterised** | ~20 | **Skipped**, each naming the variable that controls it, because `envs/prod` already sets it correctly. Private cluster, local accounts, purge protection, public network access, geo-redundant backups, Cosmos key auth. |
| **False positives and genuine trade-offs** | ~6 | **Skipped with reasoning.** PostgreSQL uses VNet injection rather than a private endpoint, which Checkov does not recognise but which is a *stronger* posture. Port 80 on the App Gateway exists only to issue a 301. Firewall IDPS is Premium-only. |

Final state: **132 passed, 0 failed, 99 skipped** — and every skip is a
sentence a reviewer can check.

---

## 8. DAST

```bash
# Start the app locally
docker compose up -d
sleep 20

mkdir -p security/dast/out
docker run --rm --network host \
  -v "$(pwd)/security/dast:/zap/wrk/:rw" \
  ghcr.io/zaproxy/zaproxy:stable \
  zap-baseline.py \
    -t http://localhost:3000 \
    -c zap-rules.tsv \
    -r out/zap-report.html \
    -J out/zap-report.json \
    -I

# Read it
start security/dast/out/zap-report.html   # Windows
```

### baseline vs full vs API scan

| Script | What it does | Runtime | Use when |
|---|---|---|---|
| `zap-baseline.py` | spider + passive only; no attacks | 1–2 min | **every PR** |
| `zap-full-scan.py` | spider + active attacks | 20–60 min | nightly, non-prod only |
| `zap-api-scan.py` | driven by an OpenAPI spec | 5–15 min | APIs — **ideal for us** |

The API scan is the interesting one for this project, because we publish an
OpenAPI document:

```bash
docker run --rm --network host \
  -v "$(pwd)/security/dast:/zap/wrk/:rw" \
  ghcr.io/zaproxy/zaproxy:stable \
  zap-api-scan.py \
    -t http://localhost:8000/openapi.json \
    -f openapi \
    -c zap-rules.tsv \
    -r out/zap-api-report.html \
    -I
```

With an OpenAPI spec, ZAP knows every endpoint, every parameter and every
type — so it attacks the real surface instead of whatever a spider happened to
find. **"We feed ZAP the OpenAPI spec so it tests the whole API surface rather
than only what the spider discovers" is a notably better answer than "we run
ZAP".**

### Rule tuning

[`security/dast/zap-rules.tsv`](../security/dast/zap-rules.tsv) — note that
each `IGNORE` carries a reason, and the genuinely important rules are set to
`FAIL`:

```
10021  FAIL    X-Content-Type-Options missing
40018  FAIL    SQL injection
90020  FAIL    Remote OS command injection
10096  IGNORE  Timestamp disclosure - ERP responses contain order dates legitimately
10202  WARN    Anti-CSRF tokens - the BFF is token-based, not cookie-based
```

### The DAST limitation to raise unprompted

**DAST cannot test what it cannot reach.** Our API requires a bearer token in
prod, so an unauthenticated baseline scan tests perhaps 10% of the surface.
The fix is to give ZAP a token:

```bash
# Authenticated API scan
TOKEN=$(az account get-access-token --resource "api://erp-api" --query accessToken -o tsv)
docker run --rm --network host \
  -v "$(pwd)/security/dast:/zap/wrk/:rw" \
  ghcr.io/zaproxy/zaproxy:stable \
  zap-api-scan.py -t http://localhost:8000/openapi.json -f openapi \
    -z "-config replacer.full_list\(0\).description=auth \
        -config replacer.full_list\(0\).enabled=true \
        -config replacer.full_list\(0\).matchtype=REQ_HEADER \
        -config replacer.full_list\(0\).matchstr=Authorization \
        -config replacer.full_list\(0\).replacement=Bearer\ ${TOKEN}" \
    -r out/zap-authed.html -I
```

---

## 9. OWASP Top 10 — the mapping table

Have this ready. Being able to name the control *in your own system* for each
item is much stronger than reciting the list.

| OWASP 2021 | Our control | Where |
|---|---|---|
| **A01 Broken Access Control** | role-based deps on every route; Entra app roles; K8s RBAC without `pods/exec`; BFF allow-list | `app/core/security.py`, `k8s/base/rbac.yaml`, `src/erp-web/src/server.js` |
| **A02 Cryptographic Failures** | TLS 1.2+ everywhere; `require_secure_transport=ON`; HSTS; no secrets at rest | App Gateway `ssl_policy`, postgres params |
| **A03 Injection** | SQLAlchemy bound parameters only; Pydantic validation with regex patterns; WAF SQLi rules; Bandit B608 + a custom Semgrep rule | `app/schemas.py`, `app/services.py` |
| **A04 Insecure Design** | explicit state machine for order transitions; GL append-only at the DB permission level; stock check before shipment | `app/services.py` `ALLOWED_TRANSITIONS`, `V002` |
| **A05 Security Misconfiguration** | security headers middleware; `/docs` disabled in prod; generic 500s with no stack traces; Checkov; Azure Policy | `app/main.py`, `policy/` |
| **A06 Vulnerable Components** | pip-audit, npm audit, Trivy; SBOM per image; expiring accepted-risk register | `pipelines/templates/job-dependency-scan.yml` |
| **A07 Auth Failures** | OIDC with JWKS validation; issuer and audience checked; MFA at the IdP; no local accounts on the cluster | `app/core/security.py` |
| **A08 Integrity Failures** | pinned tool versions; `.terraform.lock.hcl` committed; `npm ci` not `npm install`; image digests; ACR content trust available | `variables-common.yml` |
| **A09 Logging Failures** | structured JSON logs; request ids across tiers; kube-audit-admin; Key Vault AuditEvent; pgaudit; KQL alerts | `modules/monitor`, `app/main.py` |
| **A10 SSRF** | the BFF proxies only an **allow-list** of upstream paths, with a sub-path regex; egress NetworkPolicy; IMDS blocked | `src/erp-web/src/server.js`, `networkpolicy.yaml` |

> A01 and A10 are the two where our architecture is genuinely interesting —
> the BFF allow-list is a deliberate SSRF control, and blocking IMDS egress
> closes a privilege-escalation path. Lead with those.

---

## 10. Break it on purpose

All four gate-failure exercises are in [chapter 09 §5](09-cicd-pipelines.md).
Here are two more that are specific to the scanners.

**Exercise A — introduce every OWASP category and see which gate catches it**

```bash
git checkout -b test/owasp-sampler
cat > src/erp-api/app/vulnerable.py <<'EOF'
"""Deliberately vulnerable. Tests which gate catches which class."""
import hashlib
import os
import pickle
import subprocess

import requests
from sqlalchemy import text


def a03_injection(db, user_input):
    # SQL built from a format string -> Bandit B608, Semgrep OWASP A03
    return db.execute(text(f"SELECT * FROM product WHERE sku = '{user_input}'")).all()


def a02_weak_crypto(password: str) -> str:
    # MD5 for a password -> Bandit B324
    return hashlib.md5(password.encode()).hexdigest()


def a08_insecure_deserialization(blob: bytes):
    # pickle on untrusted input -> Bandit B301
    return pickle.loads(blob)


def a05_tls_disabled(url: str):
    # verify=False -> Bandit B501
    return requests.get(url, verify=False, timeout=5)


def a03_command_injection(filename: str):
    # shell=True with interpolation -> Bandit B602
    return subprocess.run(f"cat {filename}", shell=True, check=False)


def a07_hardcoded_credential():
    # -> Bandit B105, and Gitleaks if it matches a pattern
    return os.environ.get("TOKEN", "sk_live_EXAMPLE_KEY_NOT_REAL_1234567890")
EOF

# Run every scanner against it and compare
src/erp-api/.venv/Scripts/bandit.exe -r src/erp-api/app/vulnerable.py -f txt
semgrep scan --config p/owasp-top-ten src/erp-api/app/vulnerable.py
gitleaks dir src/erp-api/app --config security/secrets/gitleaks.toml --redact
```

**Make a table of which tool caught which function.** You will find Bandit
catches six, Semgrep catches a different subset, and Gitleaks catches only the
hardcoded token. That table is the concrete evidence for "these tools are
complementary, not redundant".

```bash
rm src/erp-api/app/vulnerable.py
git checkout main && git branch -D test/owasp-sampler
```

**Exercise B — prove the WAF catches what SAST cannot, and vice versa**

```bash
# A request that SAST cannot evaluate (it is runtime input) but the WAF blocks
FQDN=$(cd infra/terraform/envs/dev && terraform output -raw appgw_fqdn 2>/dev/null)
curl -s -o /dev/null -w "WAF: %{http_code}\n" \
  "http://${FQDN}/api/v1/products?category=1'%20UNION%20SELECT%20NULL--"

# A vulnerability SAST catches but the WAF never sees: a dead code path
# with injection in it, never reached by any request.
```

That pair of observations is the clearest possible demonstration of why you
need both layers.

---

## 11. Interview answers this chapter gives you

**"What DevSecOps controls did you implement?"**

> Six scanner classes, each answering a different question, all in the
> pipeline before anything is deployable. Secret scanning with Gitleaks, with
> eight custom Azure patterns on top of the defaults, scanning the diff on PRs
> and full history on main — that one is a hard fail. SAST with two tools
> deliberately: Bandit because it understands Python idioms like `shell=True`
> and `pickle`, and Semgrep for the OWASP ruleset across both Python and
> JavaScript. SCA with pip-audit, npm audit and Trivy filesystem, failing on
> critical, with an accepted-risk register where every entry must carry an
> expiry date and the build fails when it lapses. Container scanning with
> Trivy, positioned *before* the push so a vulnerable image never reaches the
> registry, and every image gets a CycloneDX SBOM retained as a build
> artefact. IaC scanning with Checkov over the Terraform, the rendered Helm
> chart and the Dockerfiles. And DAST with ZAP post-deploy against dev, driven
> by the OpenAPI spec so it tests the whole API surface rather than whatever a
> spider finds. On top of those, the runtime layers: WAF in prevention mode,
> Pod Security Admission, Gatekeeper, and Defender for Containers.

**"How do you decide what blocks a build versus what warns?"**

> By whether the signal is unambiguous and whether the finding is actionable
> by this build. Secrets are unambiguous and urgent, so they are a hard fail
> with no exceptions — a leaked credential has to be rotated, it cannot wait a
> sprint. Fixable criticals block, because by definition there is a patch. But
> I pass `--ignore-unfixed` on container criticals, because a CVE with no
> upstream patch cannot be remediated by this build, and blocking on it just
> teaches people to add skip flags until the gate is decorative. DAST warns,
> because against an authenticated API the false-positive rate is high enough
> that a blocking gate would be bypassed within two sprints. The principle is
> that a gate's value comes from being credible: I would rather have four
> strict gates people trust than eight that everyone has learned to skip.

**"How do you handle a critical CVE in a dependency?"**

> Triage before panic, in four questions. Is the vulnerable code path
> reachable from our application — a CVE in a CLI entry point we never invoke
> is not the same as one in the function we call per request, and the SBOM
> tells me which version we actually ship. Is there a patch — if yes, upgrade
> and ship, that is the end of it. If not, what does exploitation require, and
> do our other controls already prevent it: we have a read-only root
> filesystem, so a local-file-write precondition is already blocked, and
> default-deny egress, so a callback is blocked. And what is the blast radius
> — the API's database role is DML only and cannot touch the general ledger.
> Then it is a documented decision with an expiry date in the register, so it
> comes back for re-assessment rather than quietly becoming permanent. And the
> reason I can answer any of this quickly is the SBOM: when the next Log4j
> lands, "are we affected" is a `jq` query, not a week of archaeology.

**"Your SAST tool reports 200 findings. What now?"**

> I do not start fixing. First I sort by severity and confidence, because most
> of 200 will be low-severity or informational, and I look at what the gate
> actually blocks on — high severity — which is usually a handful. Then I
> triage the blockers properly: real finding, false positive, or accepted risk
> with a reason. False positives get a narrow, justified suppression *in the
> code* with a comment, not a CLI skip flag, so the next reviewer sees the
> reasoning. The rest become work items. Then the important step people skip:
> I baseline. A new tool on an existing codebase will always produce a backlog,
> and if the gate blocks on all of it from day one, the team's first action is
> to disable the gate. So I set the threshold to block on *new* findings and
> burn the existing backlog down on a schedule. The goal is a gate the team
> trusts, not a report nobody reads.

---

## Checklist

- [ ] You can name all six gate types and what each is **blind to**
- [ ] You can defend each block/warn decision, especially `--ignore-unfixed`
- [ ] Gitleaks run on working tree and full history
- [ ] You can explain why the allowlist is a reviewed artefact
- [ ] You can give the remediation order for a leaked secret (rotate first)
- [ ] Bandit and Semgrep both run; you know why two tools
- [ ] **You wrote at least one custom Semgrep rule**
- [ ] pip-audit, npm audit and Trivy fs all run
- [ ] Accepted-risk register understood, including enforced expiry
- [ ] You can give the four-question CVE triage
- [ ] Container scanned; you compared base image sizes and CVE counts
- [ ] You can explain slim vs alpine vs distroless with the real trade-offs
- [ ] Checkov run over Terraform, rendered Helm, Dockerfiles and ARM
- [ ] You know suppressions belong inline with a reason
- [ ] ZAP baseline **and** API scan run; you read the HTML report
- [ ] You know the DAST authentication limitation and how to fix it
- [ ] **OWASP Top 10 mapping table: you can name our control for each item**
- [ ] The OWASP sampler exercise done; you made the "which tool caught what" table

Next: [chapter 11 — Monitoring](11-monitoring.md)
