# Pre-interview checklist

Work backwards from the interview date.

---

## 7 days before

### Technical consolidation
- [ ] Re-read the "Interview answers" section of every chapter (01–14)
- [ ] Draw the architecture from blank paper — **5 times**, narrating out loud
- [ ] Write the three KQL queries from memory (chapter 11 §9)
- [ ] Confirm you can speak to every row of the
      [JD coverage matrix](jd-coverage-matrix.md)
- [ ] Identify your three weakest areas and spend a session on each

### Stories
- [ ] Write all five STAR stories out in full (chapter 15 §4)
- [ ] Cut each to 90 seconds
- [ ] **Confirm story 3 is a real mistake you actually made**

---

## 3 days before

### Drill
- [ ] Card drill: all 16 near-certain questions, out loud, timed
      — anything over 90 seconds gets cut
      — anything under 20 seconds needs more substance
- [ ] 90-second opener: say it 10 times, until you are not thinking about it
- [ ] Mock interview with another person. Anyone. A non-technical friend
      asking "why?" after each answer is surprisingly effective

### Verify the project still works
```bash
cd /d/Azure
./scripts/validate-local.sh
docker compose up -d && ./scripts/smoke-test.sh http://localhost:8000
```
- [ ] All local checks pass
- [ ] Smoke test passes 27/27
- [ ] If you plan to demo live Azure resources, bring them up and confirm

### Prepare your materials
- [ ] Repository open in an editor, ready to show
- [ ] The files you would most want to show, bookmarked:
      - `infra/terraform/modules/identity/main.tf` — the identity chain
      - `k8s/helm/erp/templates/networkpolicy.yaml` — default deny + IMDS block
      - `pipelines/templates/job-build-image.yml` — scan before push
      - `guidance/14-runbook.md` — the operational half
- [ ] One page of notes, handwritten. Writing it is the revision; you will
      barely look at it

---

## 1 day before

- [ ] **Light review only.** No new material — it will not stick and it
      crowds out what you know
- [ ] Re-read your own runbook (chapter 14)
- [ ] Re-read your own session notes from `daily-practice.md`
- [ ] Finalise your six questions for them (chapter 15 §5)
- [ ] Research: the company, the product, who you are meeting, recent news
- [ ] Logistics
      - [ ] Address and route confirmed; travel time + 30 minutes
      - [ ] Time zone double-checked if remote
      - [ ] Interviewer names and roles noted
      - [ ] Contact number in case something goes wrong
- [ ] **Sleep.** Genuinely the highest-leverage thing left.

### If remote
- [ ] Test camera, microphone and screen share **on the actual platform** they
      are using
- [ ] Close every notification source
- [ ] Charge everything; have the charger plugged in
- [ ] Tethering or a backup connection ready
- [ ] Background tidy, lighting in front of you not behind
- [ ] Water, pen, paper

---

## The morning of

- [ ] Eat something
- [ ] Say the 90-second opener out loud, once
- [ ] Draw the architecture, once
- [ ] Skim your one page of notes
- [ ] **Do not cram.** It raises anxiety and lowers recall
- [ ] Arrive or log in 10 minutes early

---

## The 60-second recall card

Glance at this immediately before you go in.

```
OPENER      4 yrs DevOps, Azure platform + security focus.
            ERP platform: landing zone, AKS, zero secrets, DevSecOps
            pipeline, runbook. "Happy to go deep on any of it."

ARCHITECTURE
  Internet → AppGW WAF v2 (OWASP 3.2) → AKS ingress → web BFF → api
           → PostgreSQL (VNet-injected, no public endpoint, Entra tokens)
  Hub: Azure Firewall, FQDN allow-list, UDR forces all spoke egress
  Spoke 10.10.0.0/16, hub 10.0.0.0/16, AKS subnets /22, CNI Overlay

IDENTITY CHAIN (the one to get right)
  K8s ServiceAccount → annotated with MI client id
  → federated credential trusts AKS OIDC issuer for
    system:serviceaccount:erp:erp-api-sa
  → projected SA token exchanged for an Entra access token
  → Key Vault / ACR / PostgreSQL
  LABEL on the POD. ANNOTATION on the SERVICE ACCOUNT.

PIPELINE
  build (test+lint+coverage) → security (secrets/SAST/SCA/IaC)
  → images (build→SCAN→SBOM→push) → dev auto → test 1 approval
  → prod 2 approvals + window + change ticket
  Secrets = HARD FAIL. Scan BEFORE push. Same image promoted, not rebuilt.

NUMBERS
  exit 137 = OOMKilled  |  exit 143 = SIGTERM
  AppGW NSG needs GatewayManager 65200-65535
  Azure reserves 5 IPs per subnet
  AADSTS70021 = FIC subject/issuer mismatch
  timeout = policy drop | refused = nothing listening

TRADE-OFF HABIT
  decision → reason → cost → why the cost is acceptable here

THREE HONEST GAPS
  no cross-region DR test | change gate validates format not approval
  | no progressive delivery (canary)

MY QUESTIONS
  1. Where is the platform today — building or hardening?
  2. How many teams consume the templates, and is adoption agreed?
  3. What would you want me to fix first?
  4. What does success look like at six months?
```

---

## During the interview

- [ ] Answer the question **they** asked, then offer the adjacent point
- [ ] State the **trade-off** unprompted for every design decision
- [ ] Say "I" not "we" when it was you; be precise when it was the team
- [ ] If you do not know: "I have not used that — here is the adjacent thing
      I do know, and here is how I would approach it"
- [ ] Land answers in under 90 seconds, then: "want me to go deeper?"
- [ ] Take notes — it shows engagement and helps your follow-up
- [ ] Ask your questions
- [ ] Close with chapter 15 §10, including *"anything that gives you pause?"*

---

## Immediately after

- [ ] Write down every question you were asked, while it is fresh
- [ ] Note which answers felt weak — that is your study list either way
- [ ] Send a short thank-you note within 24 hours, referencing one specific
      thing from the conversation
- [ ] Note anything you promised to follow up on, and do it

---

## If it does not go well

The notes you just took are the most valuable thing you will get out of it.
Every question that landed badly is a specific, known gap — which is far more
useful than a vague sense of not being ready.

The platform is still built. The next interview starts from a stronger place.
