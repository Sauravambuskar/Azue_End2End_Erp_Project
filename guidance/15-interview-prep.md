# 15 — Interview preparation

**Time:** 6 hours, spread over several days · **Cost:** ₹0
**Prerequisite:** chapters 01–14, and having actually built the thing

Everything until now was building. This chapter is rehearsal. The gap between
"I built it" and "I can explain it under pressure in 90 seconds" is larger
than people expect, and it is closed only by saying things **out loud**.

---

## 1. Your 90-second opener

You will be asked "tell me about yourself" or "walk me through a recent
project". Have this memorised to the point where you do not think about it.

> I am a DevOps engineer with about four years of experience, and my focus for
> the last while has been Azure platform and security work. The project I can
> speak to in most depth is a secure Azure platform I built for an ERP system
> — products, inventory, sales and purchase orders, and a double-entry general
> ledger.
>
> On the platform side: a hub-spoke landing zone with management groups and
> Azure Policy for governance, an AKS cluster with Entra ID integration,
> Calico network policy and workload identity, and PostgreSQL Flexible Server
> VNet-injected with no public endpoint at all. The thing I am most pleased
> with is that there are no secrets in the system — the pods authenticate to
> the database and to Key Vault with Entra ID tokens through workload identity
> federation, and the CI/CD service connection is federated too, so there is
> nothing to rotate and nothing to leak.
>
> On the DevSecOps side: Azure DevOps YAML pipelines with shared templates, so
> five gates — secrets, SAST, dependency scanning, container scanning and IaC
> scanning — are available to any team by reference rather than
> reimplementation. Container images are scanned before they are pushed, not
> after, so a vulnerable image never reaches the registry. Everything is
> Terraform, with a plan-approve-apply flow where the apply consumes the
> approved plan file.
>
> And I wrote the runbook, because I think the operational half is what
> actually matters. Happy to go deep on any of it.

### Why this works

- **Specific, not generic.** Names the technologies and the design decisions.
- **Leads with the strongest differentiator** — zero secrets.
- **Shows security thinking** rather than just tool knowledge.
- **Ends with an invitation**, which puts you in control of the next question.
- **~90 seconds**, which is right. Three minutes loses the room.

### Time it

Say it out loud five times. Record it once and listen back. If it runs past
two minutes, cut the middle paragraph down.

---

## 2. The whiteboard drill

Practise until you can draw this in **under four minutes** on blank paper
while talking.

```
        Internet
            │
    ┌───────▼────────┐
    │ App Gateway    │  WAF v2, OWASP 3.2 Prevention
    │ WAF v2  :443   │  rate limit, TLS 1.2+, geo rules
    └───────┬────────┘
            │  snet-appgw 10.10.16.0/24
════════════│══════════════════════  SPOKE VNet 10.10.0.0/16
    ┌───────▼────────┐
    │  AKS ingress   │
    └───────┬────────┘
     ┌──────┴──────┬──────────────┐
  ┌──▼───┐    ┌───▼───┐     ┌────▼─────┐
  │ web  │───▶│  api  │     │  worker  │   NetworkPolicy:
  │ BFF  │only│FastAPI│     │ CronJob  │   default deny
  │ SA+MI│path│ SA+MI │     │  SA+MI   │   + 3 allowed flows
  └──────┘    └───┬───┘     └────┬─────┘
                  │ 5432, Entra ID token (no password)
          ┌───────▼─────────────┐
          │ PostgreSQL Flexible │  VNet-injected, no public endpoint
          │ pgaudit, TLS req.   │  private DNS zone, erp_app DML only
          └─────────────────────┘
   ┌────────┬──────────┬──────────────┬──────────┐
 ┌─▼──┐ ┌───▼───┐ ┌────▼──────┐ ┌─────▼────┐
 │ACR │ │  KV   │ │Log Analytx│ │  Cosmos  │  all via private endpoints
 │Pull│ │RBAC   │ │+ App Insts│ │serverless│  in prod
 └────┘ └───────┘ └───────────┘ └──────────┘

════════════════════════════════════  HUB VNet 10.0.0.0/16
  ┌──────────────────┐  ┌─────────┐
  │ Azure Firewall   │  │ Bastion │   UDR 0.0.0.0/0 → firewall
  │ FQDN allow-list  │  │         │   forces all spoke egress here
  └──────────────────┘  └─────────┘
```

### The narration, in order — do not draw silently

1. "Traffic enters at the Application Gateway, which terminates TLS and runs
   the OWASP 3.2 core rule set in Prevention mode."
2. "Its subnet NSG allows 443 from the internet and — this is the one people
   miss — 65200-65535 from the GatewayManager service tag, or the gateway
   never becomes healthy."
3. "It forwards into the spoke VNet to the AKS ingress controller."
4. "Only the web tier is published. It is a BFF, so the browser never holds a
   token and never talks to the API directly — the web pod calls the API
   server-side over ClusterIP, and that is the only allowed path because the
   namespace is default-deny with three explicit NetworkPolicy flows."
5. "The API reaches PostgreSQL on 5432. The server is VNet-injected into a
   delegated subnet, so there is no public endpoint at all, and the hostname
   resolves to a private IP through a private DNS zone linked to this VNet."
6. "Authentication is an Entra ID token the pod obtained through workload
   identity — there is no password anywhere in that path."
7. "Each component has its own managed identity. The migration job's identity
   is the only one with DDL rights, so the runtime pods cannot alter the
   schema."
8. "All egress is forced through Azure Firewall in the hub by a UDR, with an
   FQDN allow-list, so a compromised pod cannot exfiltrate."

**Practise five times on blank paper.** The fluency is the point; the drawing
is just the prop.

---

## 3. The near-certain questions

For each: a short answer you can give in 30 seconds, then the depth if they
push. The full versions are in each chapter's "interview answers" section.

| Question | Where the full answer is | One-line core |
|---|---|---|
| Managed identity vs service principal | 04 §9 | a managed identity *is* a service principal whose credential Azure holds |
| How do pods authenticate without secrets | 04 §9 | OIDC federation: SA token → Entra token |
| How do you secure an AKS cluster | 05 §11 | five layers: control plane, network, identity, workload, supply chain |
| Walk me through your pipeline | 09 §10 | build → security → images → dev → test → prod |
| Requests vs limits | 05 §11 | memory limits yes, CPU limits no — throttling is worse than OOM |
| Azure RBAC vs Kubernetes RBAC | 04 §9 | control plane vs data plane; you need both |
| Terraform vs Bicep | 02 §9 | state vs stateless; name the trade-off in both directions |
| How do you manage secrets | 07 §9 | eliminate first, then Key Vault + CSI as files |
| Deny vs Audit policy | 02 §10 | Audit to discover, Deny to enforce, DoNotEnforce to rehearse |
| Zero-downtime deployment | 05 §11 | maxUnavailable 0 + readiness + PDB + SIGTERM handling |
| What do you alert on | 11 §9 | only what needs a human; name what you *don't* alert on |
| Trace a request end to end | 03 §9 | the whiteboard narration above |
| How did you size the subnets | 03 §9 | for max nodes, not current; CNI Overlay removes the problem |
| Handle a critical CVE | 10 §11 | reachability, patch, preconditions, blast radius |
| Pod in CrashLoopBackOff | 05 §11 | describe → exit code → logs --previous |
| How do you control cost | 13 §6 | prevent, detect, optimise, operate |

### Drill method

Write each question on a card. Shuffle. Draw one, answer **out loud**, timed.
Anything over 90 seconds needs cutting. Anything under 20 seconds needs more
substance.

---

## 4. STAR stories — prepare five

Behavioural questions are where technically strong candidates lose points,
because they ramble. Use **Situation, Task, Action, Result** and keep each to
about 90 seconds.

Write these out properly. Use *your own* real experience where you have it,
and this project where you do not — being clear which is which is fine and
honest.

### Story 1 — "Tell me about a difficult technical problem"

> **Situation.** Pods in the ERP namespace could get an Entra ID token
> perfectly well, but every database connection failed with "password
> authentication failed for user id-erp-api-dev". Workload identity looked
> correct from every angle.
>
> **Task.** Work out whether the problem was identity, networking or the
> database, without guessing.
>
> **Action.** I split it into layers and tested each. I confirmed the token
> was real by decoding the projected service-account token in the pod and
> checking the `iss` and `sub` claims matched the federated credential exactly.
> I confirmed `DefaultAzureCredential` could acquire an access token from
> inside the pod. So identity was fine. Connectivity was fine too — TCP 5432
> connected. That left the database itself, and the answer was that PostgreSQL
> had no *role* for the managed identity. Entra issues the token, but the
> server still needs a principal created with `pgaadauth_create_principal`,
> which no quickstart mentions prominently.
>
> **Result.** I scripted it as `db-grant-identities.sh`, which reads the
> identity names from Terraform outputs and creates the principals with the
> right least-privilege roles, and I documented the error signature in the
> runbook. The broader lesson I took is that "the token is valid" and "the
> target will accept the token" are two different questions, and I now test
> them separately.

### Story 2 — "A time you disagreed with someone"

Use a real one if you have it. Pattern:

> **Situation.** <a design disagreement — e.g. someone wanted to store the DB
> password in a Kubernetes Secret because managed identity "was more work">
>
> **Task.** Reach a decision without it becoming a standoff.
>
> **Action.** I made sure I understood the actual objection, which was
> schedule, not disagreement about security. So I timeboxed a spike: two days
> to get workload identity working end to end, and if it was not working we
> would ship with the Secret and a rotation runbook. I had it working in a day
> and a half, and demonstrated it — including that the pod could get a token
> with nothing stored. I also wrote down what the Secret approach would have
> cost us: rotation, an etcd blast radius, and no audit trail of reads.
>
> **Result.** We went with workload identity. What I would do differently is
> lead with the timebox rather than the argument — the disagreement was about
> risk to the schedule, and I spent the first conversation arguing about
> security, which was not the real objection.

### Story 3 — "Something that went wrong because of you"

**Have a real one. Do not say "nothing comes to mind."**

> **Situation.** I left Azure Firewall enabled over a weekend after an
> egress-lockdown exercise in my lab subscription. It is roughly USD 30 a day,
> more than everything else in the project combined.
>
> **Task.** Stop the bleeding and make it not happen again.
>
> **Action.** The forecast budget alert caught it on the Sunday — the actual
> spend was still under the threshold, but the burn rate projected past it. I
> turned it off, then fixed the system rather than the instance: the firewall
> and the Application Gateway went behind Terraform feature flags defaulting
> to `false`, so the expensive resources are opt-in, and I added a nightly
> scheduled pipeline that stops AKS and PostgreSQL.
>
> **Result.** Daily cost went from about USD 33 to under USD 1 when idle. The
> general lesson is that cloud cost risk is rarely a big obvious mistake — it
> is something cheap that nobody turned off — so the control has to be
> automatic rather than a reminder. It also changed how I write Terraform: the
> expensive thing defaults to off.

### Story 4 — "Explaining something technical to a non-technical person"

> **Situation.** I needed sign-off for the extra effort to make the ERP
> database passwordless, and the person approving it was not technical.
>
> **Task.** Explain the value without jargon.
>
> **Action.** I did not talk about OIDC or token exchange. I said: today the
> application knows a password, so that password exists in a file somewhere,
> somebody has to change it every ninety days, and if it is ever copied into
> an email or a support ticket we have to change it in a hurry. The
> alternative is that the application proves who it is the way an employee
> badge does — the system checks the badge, there is nothing written down, and
> there is nothing to steal. I also gave the cost in plain terms: two extra
> days now, against a rotation task every quarter forever.
>
> **Result.** Approved. The badge analogy stuck and got reused in other
> conversations. What I learned is to lead with what disappears — the
> recurring work, the thing that can leak — rather than the mechanism.

### Story 5 — "Working under pressure / a deadline"

Use a real one. Keep it to: the constraint, what you cut, what you refused to
cut, and the outcome. The strongest version of this story names something you
deliberately **did not** compromise on, and why.

---

## 5. Questions to ask them

Asking good questions is half the interview. Prepare six; you will use three.

### About the role

1. "The JD mentions shared CI/CD templates for multiple solution teams — how
   many teams would be consuming the platform, and are they on board or will
   this be an adoption exercise?"
2. "Where is the platform today? Am I building the landing zone, or inheriting
   one and hardening it?"
3. "What does the on-call rotation look like, and does the platform team carry
   the pager for the workloads or just the platform?"

### Technical

4. "What is the split between Terraform and Bicep today, and is there an
   intent to converge?"
5. "Is the Okta integration in place already, or is that part of the work? And
   is Okta the IdP with Entra federated to it, or the other way round?"
6. "How are the AKS clusters structured — one per environment, or shared
   clusters with namespace isolation?"
7. "What does the current security gate posture look like — are the scans
   blocking or advisory today?"

### About the team and ways of working

8. "How does a change reach production today, and how long does that
   typically take?"
9. "What is the biggest operational pain point right now? If I joined
   tomorrow, what would you want me to fix first?"
10. "The role mentions working with architects, developers, security and
    operations — how are those boundaries drawn in practice? Who owns the
    Kubernetes manifests, the platform team or the app teams?"

### The one that works especially well

> "What does success look like at six months for whoever takes this role?"

It is forward-looking, it tells you what they actually care about, and the
answer gives you material for your closing statement.

### Do not ask

- anything answered on their website
- salary or leave in a first technical round
- "what does the company do?"

---

## 6. The take-home / live coding possibility

For a role at this level you may get a practical exercise. The likely shapes,
and what you already have:

| Likely task | What you can reuse |
|---|---|
| "Write Terraform for an AKS cluster with X" | `infra/terraform/modules/aks` |
| "Write a pipeline that builds and scans a container" | `pipelines/templates/job-build-image.yml` |
| "Harden this Dockerfile" | `src/erp-api/Dockerfile` — multi-stage, non-root, read-only rootfs |
| "Write a NetworkPolicy that..." | `k8s/helm/erp/templates/networkpolicy.yaml` |
| "Debug this broken manifest" | chapter 05 §9, chapter 14 §3 |
| "Write a KQL query for..." | the three memorised queries in chapter 11 §9 |
| "Review this Terraform for security issues" | everything in chapters 03, 05, 12 |

### If you get a review-the-code exercise

Work through it in this order out loud, because the order *is* the answer:

1. **Identity** — any hardcoded credentials? any wildcard role assignments?
2. **Network** — any `0.0.0.0/0` inbound? public endpoints on data services?
3. **Encryption** — TLS enforced? encryption at rest? minimum TLS version?
4. **Least privilege** — Contributor where Reader would do? admin user on ACR?
5. **Observability** — diagnostic settings? where do the logs go?
6. **Operability** — can this be destroyed and recreated? is state remote and locked?
7. **Cost** — anything that bills by the hour and did not need to?

Narrating a checklist is far more impressive than spotting findings randomly,
because it shows a repeatable method rather than luck.

---

## 7. Weak spots — be honest, have a plan

They will find the edges. The answer that works is **"not yet, here is my
plan, and here is the adjacent thing I do know."** Never bluff: a confident
wrong answer is much worse than "I have not used that."

| Likely gap | How to answer |
|---|---|
| No certifications | "AZ-400 is the one that maps to this role and I have it planned for <month>. What I have instead is a platform I built end to end — happy to walk through any part." |
| Never run this at production scale | "My experience is at lab scale on this stack. What I would want to understand on day one is your actual traffic shape and node counts, because the designs that change at scale are the IP plan and the autoscaling thresholds." |
| Have not used Okta | "I have not had an Okta tenant. I understand both federation directions and I have built the application side so one OIDC validator handles Entra or Okta with the issuer, audience and claim mapping as config. What I would need to learn is the Okta admin side." |
| No Bicep in production | "Terraform is what I have used in anger. I have deployed the same landing zone in Bicep to understand the differences — the main ones being stateless deployment and same-day feature support — so I can work in it, but I would not claim depth." |
| Limited Windows containers / legacy | "Linux containers only. I know the AKS differences — bigger images, slower pulls, a separate node pool — but I have not run them." |
| No service mesh | "Not yet. I know what problem it solves — mTLS, traffic splitting, retries — and for this platform NetworkPolicy plus the BFF covered the requirement, so adding Istio's operational weight was not justified. If you run one I would want to understand why." |

**The pattern:** acknowledge honestly → show adjacent knowledge → say what you
would do to close it. That reads as self-aware rather than lacking.

---

## 8. Red flags to avoid

| Do not | Instead |
|---|---|
| Say "we" when you mean "I" | be precise about your own contribution |
| Claim tools you have only read about | "I have not used it, but..." |
| Badmouth a previous employer | "the constraints were X, which led to Y" |
| Answer the question you wish they had asked | answer theirs, then offer the adjacent point |
| Ramble past two minutes | land the answer, then ask "want me to go deeper?" |
| Say "it just works" | nothing just works; name the failure mode |
| Give only the happy path | name the trade-off — every design has one |
| Fake certainty on a number | "roughly X, I would check" |

### The single most valuable habit

**For every design decision, state the trade-off unprompted.**

Not: "we used CNI Overlay."
But: "we used CNI Overlay because IP exhaustion is the most common
irreversible AKS mistake and Overlay removes that whole class of problem. The
cost is that a pod is not independently addressable from the VNet, which only
matters if something outside the cluster needs to dial a pod directly — and
nothing in this architecture does."

That construction — decision, reason, cost, why the cost is acceptable here —
is what senior sounds like. Use it for everything.

---

## 9. The final week

### 7 days before

- [ ] Re-read every chapter's "interview answers" section
- [ ] Draw the architecture from blank paper five times
- [ ] Say the 90-second opener out loud until it is automatic
- [ ] Write out all five STAR stories in full, then cut each to 90 seconds

### 3 days before

- [ ] Card drill: all 16 near-certain questions, out loud, timed
- [ ] Write the three KQL queries from memory, no reference
- [ ] Mock interview with someone — anyone. Even a non-technical friend
      asking "why?" after every answer is enormously useful
- [ ] Re-read [`checklists/jd-coverage-matrix.md`](checklists/jd-coverage-matrix.md)
      and confirm you can speak to every row

### 1 day before

- [ ] Light review only. No new material — it will not stick and it will
      crowd out what you know
- [ ] Re-read your own runbook, chapter 14
- [ ] Prepare your six questions for them
- [ ] Check the logistics: location, time, who you are meeting, travel
- [ ] Sleep. Genuinely the highest-leverage preparation left at this point

### The morning of

- [ ] Say the opener out loud once
- [ ] Draw the architecture once
- [ ] Skim [`checklists/pre-interview.md`](checklists/pre-interview.md)
- [ ] Do not cram

### If it is remote

- [ ] Test camera, microphone and screen share on the actual platform
- [ ] Have the repository open in an editor, ready to share
- [ ] Have a blank document ready for diagramming
- [ ] Close notifications
- [ ] Have water, and a pen and paper for taking notes

---

## 10. Closing the interview

When they ask "do you have anything else for us?", do not just say no.

> One thing I would add. The part of this I found most interesting was not any
> individual service, it was removing credentials from the system — the
> database, Key Vault, the registry and the CI/CD connection all authenticate
> with federated identity, so there is nothing stored and nothing to rotate.
> That changed how I think about security work: the strongest control is
> usually eliminating the thing rather than protecting it better.
>
> And based on what you said about <the thing they mentioned as a priority>,
> the piece I would be most keen to get into early is <the matching thing>.
>
> Is there anything about my experience you would like me to expand on, or
> anything that gives you pause?

That last sentence is worth asking. If there is a concern, you want to hear it
while you can still address it — not after the decision.

---

## Checklist

- [ ] 90-second opener memorised and timed
- [ ] Architecture drawn from memory in under 4 minutes, **with narration**
- [ ] All 16 near-certain questions answered out loud, timed
- [ ] **Five STAR stories written out and cut to 90 seconds**
- [ ] Story 3 is a **real mistake you actually made**
- [ ] Six questions prepared for them
- [ ] You can state a trade-off unprompted for every major design decision
- [ ] You have an honest answer for every gap in §7
- [ ] The three KQL queries written from memory
- [ ] At least one mock interview done out loud with another person
- [ ] You can speak to every row of the JD coverage matrix
- [ ] Logistics confirmed; kit tested if remote

---

## Last thing

You built a working platform. It has a landing zone, a hardened AKS cluster,
passwordless identity throughout, five security gates in CI, dashboards,
alerts, policy enforcement and a runbook. The tests pass, the smoke test
passes, the Terraform validates and the chart renders.

Most candidates for this role will have used these services. Fewer will have
built the whole thing and be able to say *why* for each decision — including
the things they chose not to do.

That is your edge. Lead with the reasoning, name the trade-offs, and be honest
about the gaps.

Good luck.
