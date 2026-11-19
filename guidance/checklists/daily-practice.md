# Daily practice checklist

Print this, or keep it open. Same routine every session.

---

## Start of session (5 minutes)

- [ ] `az login` and confirm the right subscription
      ```bash
      az account show --query '{sub:name, id:id}' -o table
      ```
- [ ] Start what you stopped last time
      ```bash
      az aks start -g rg-erp-dev-cin-aks -n aks-erp-dev-cin-01 --no-wait
      az postgres flexible-server start -g rg-erp-dev-cin-data -n psql-erp-dev-cin-01 --no-wait
      ```
      *(AKS takes 3–5 min, PostgreSQL about 2 — set up while they come up)*
- [ ] Check nothing unexpected is running
      ```bash
      ./scripts/cost-check.sh
      ```
- [ ] Pick **one** chapter or exercise. Not three.

---

## During the session

For every single thing you build:

- [ ] Did it work? **Prove it**, do not assume it
- [ ] Can I explain **why** this setting and not the obvious alternative?
- [ ] What is the **trade-off** I accepted?
- [ ] What breaks if this is misconfigured, and what does that look like?

Write the answers down. Three lines per item is enough. This file is what you
revise from in week three — not the chapters.

```markdown
## 2026-11-17 — workload identity
Built: federated credentials for api/worker/web/migrate identities.
Why user-assigned not system-assigned: system-assigned dies with the
  resource, and I want the identity to survive cluster rebuilds.
Trade-off: four identities instead of one is more Terraform, but a
  compromised API pod cannot reach what the migrate identity can.
Broke it: changed the FIC subject to a wrong SA name → AADSTS70021.
  That error ALWAYS means subject or issuer mismatch.
```

---

## End of session (5 minutes) — do not skip

- [ ] Write the 3-line note above for today
- [ ] Commit your work
      ```bash
      git add -A && git commit -m "chapter N: <what you did>"
      ```
- [ ] Run the local validation
      ```bash
      ./scripts/validate-local.sh
      ```
- [ ] **Stop the meter**
      ```bash
      az aks stop -g rg-erp-dev-cin-aks -n aks-erp-dev-cin-01 --no-wait
      az postgres flexible-server stop -g rg-erp-dev-cin-data -n psql-erp-dev-cin-01 --no-wait
      ```
- [ ] Confirm the expensive optional resources are off
      ```bash
      grep -E "enable_(firewall|appgw)" infra/terraform/envs/dev/terraform.tfvars
      ```
- [ ] `./scripts/cost-check.sh` one last time

> The single habit that protects your budget: **never close the laptop without
> running `cost-check.sh`.** It takes 20 seconds.

---

## Weekly (30 minutes, pick a fixed day)

- [ ] Draw the architecture from **blank paper**, no reference
- [ ] Say the 90-second opener out loud, timed
- [ ] Pick 5 cards from the question drill, answer out loud, timed
- [ ] Re-read your own notes from the week
- [ ] Update the [JD coverage matrix](jd-coverage-matrix.md) — tick what you
      have genuinely built, broken and fixed
- [ ] Check spend
      ```bash
      az consumption usage list \
        --start-date "$(date -u +%Y-%m-01)" --end-date "$(date -u +%Y-%m-%d)" \
        --query "[?tags.Workload=='erp'].pretaxCost" -o tsv \
        | awk '{s+=$1} END {printf "month to date: %.2f\n", s}'
      ```

---

## The "break it" discipline

**Never finish a chapter without doing its break-it exercises.**

Building something teaches you the happy path. Breaking it teaches you the
error message — and the error message is what you actually need, both at 2 a.m.
and in an interview when someone asks "how would you debug that?"

Keep a running log of failure signatures:

```markdown
| Error text (first line)                                | Means                          |
|--------------------------------------------------------|--------------------------------|
| AADSTS70021: No matching federated identity record     | FIC subject/issuer mismatch    |
| password authentication failed for user "id-erp-..."   | no pgaadauth principal         |
| permission denied for table product                    | principal exists, no role grant|
| RequestDisallowedByPolicy                              | an Azure Policy Deny           |
| exit code 137                                          | OOMKilled                      |
| connection timed out (not refused)                     | NetworkPolicy or NSG drop      |
| nslookup returns a public IP for a private endpoint    | private DNS zone not LINKED    |
| App Gateway backends "Unknown"                         | missing GatewayManager NSG rule|
```

That table is worth more than any single chapter.

---

## Signs you are ready to move on from a chapter

Not "I read it". All four of these:

- [ ] It is deployed and **verified working**, not just applied
- [ ] You did the break-it exercises and **recognise the error messages**
- [ ] You can explain every decision **and its trade-off**, out loud
- [ ] The chapter's own checklist is fully ticked

---

## Signs you are drifting

Watch for these and correct:

- Reading chapters without deploying → you will not retain it
- Deploying without reading the *why* → you cannot defend it
- Skipping break-it exercises → you will freeze on debugging questions
- Not writing notes → week three has nothing to revise
- Not stopping resources → an avoidable bill
- Trying to finish three chapters in one day → none of them will stick
