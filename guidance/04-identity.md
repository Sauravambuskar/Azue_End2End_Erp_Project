# 04 — Entra ID, workload identity, service principals, Okta SSO

**Time:** 4 hours · **Cost:** ₹0 (Entra ID free tier covers all of this)
**Prerequisite:** chapter 02 and 03 complete, AKS cluster exists

**This is the single most important chapter for the interview.** Identity is
where DevSecOps actually happens. Everything else — networking, policy,
scanning — is a layer around the question *who is allowed to do what, and how
do they prove who they are without a stored secret.*

If you learn one thing properly from this whole project, make it §4.

---

## 1. The vocabulary, pinned down

People use these interchangeably and then get confused. They are not the same.

| Term | What it actually is | Has credentials? |
|---|---|---|
| **Tenant** | an Entra ID directory instance | — |
| **Application registration** | the *definition* of an app: redirect URIs, API permissions, exposed scopes. Global to the tenant. | you can add them |
| **Service principal** | the *instance* of that app registration **in one tenant** — the thing that actually gets role assignments | yes: secret, certificate, or federated credential |
| **Managed identity** | a service principal whose credential Azure manages and rotates for you. You never see it. | yes, invisible to you |
| → **system-assigned** | lifecycle tied 1:1 to one resource; deleted with it | |
| → **user-assigned** | standalone resource; can be attached to many resources; survives them | |
| **Workload identity** | federation: a Kubernetes ServiceAccount token is exchanged for an Entra token. **No credential at all.** | **no** |

**The one-liner that lands well:** *"An app registration is the class, a
service principal is the instance, and a managed identity is an instance whose
password Azure holds so I never have to."*

### Which to use, decided

| Scenario | Use | Why |
|---|---|---|
| Pod needs Key Vault / DB / ACR | **workload identity + user-assigned MI** | zero secrets, per-pod blast radius |
| VM needs a storage account | system-assigned MI | simplest, dies with the VM |
| Azure DevOps pipeline → Azure | **app registration + federated credential (WIF)** | no secret to rotate or leak |
| Third-party SaaS → Azure | app registration + certificate | federation often unsupported |
| Local development | your own user via `az login` | your identity, your audit trail |
| **Anything, ever, with a client secret** | avoid | if you must: 6-month expiry, in Key Vault, with a rotation runbook |

---

## 2. Entra ID groups and the human access model

Done in chapter 02 §6. Recap of the principle, because it gets asked:

**Never assign a role to a user. Always to a group.**

Why, in one breath: a user assignment is invisible six months later, survives
the person changing teams, cannot be reviewed as a set, and has no approval
trail. A group assignment is reviewable, delegatable, and can be put behind
PIM.

```bash
source ~/.erp-lab-env

# What groups exist and who is in them
az ad group list --filter "startswith(displayName,'grp-erp')" \
  --query '[].{name:displayName, id:id}' -o table

az ad group member list --group "grp-erp-platform-admins" \
  --query '[].{name:displayName, upn:userPrincipalName}' -o table
```

### Privileged Identity Management — know what it is even if you cannot use it

PIM requires **Entra ID P2**, which the free tier does not include. You will
not demo it. You should absolutely be able to describe it:

> Standing access to production is the problem. PIM makes a user *eligible*
> for a role rather than permanently assigned. To use it they activate — with
> MFA, a business justification, optionally an approver, and a time limit,
> typically 8 hours. Every activation is logged. So production Contributor
> goes from "12 people have it permanently" to "12 people can request it, and
> we can see who used it and why."
>
> In this project I modelled that with group-based assignment so the PIM
> layer is a configuration change rather than a redesign — the groups are
> already the unit of access.

That last sentence is the valuable part: it shows you designed *for* a control
you could not deploy.

---

## 3. Service principal for CI/CD — with federated credentials, not a secret

Chapter 08 does the Azure DevOps side. The identity side is here.

### The old way (do not do this)

```bash
# A client secret. It expires, it leaks, it ends up in a variable group,
# someone screenshots it in a ticket. This is the thing we are eliminating.
az ad sp create-for-rbac --name sp-erp-cicd --role Contributor \
  --scopes "/subscriptions/$SUB_ID"
```

### The right way — Workload Identity Federation

```bash
source ~/.erp-lab-env

# 1. App registration (the definition)
APP_ID=$(az ad app create --display-name "sp-erp-dev-cicd" --query appId -o tsv)
echo "appId: $APP_ID"

# 2. Service principal (the instance that gets roles)
az ad sp create --id "$APP_ID" -o none
SP_OID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
echo "sp object id: $SP_OID"

# 3. Federated credential: trust Azure DevOps instead of holding a secret.
#    The subject must match EXACTLY what Azure DevOps sends.
#    Format: sc://<org>/<project>/<service-connection-name>
cat > /tmp/fic.json <<EOF
{
  "name": "azdo-erp-dev",
  "issuer": "https://vstoken.dev.azure.com/<your-azdo-org-guid>",
  "subject": "sc://<your-org>/ContosoERP/sc-erp-dev-wif",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "Azure DevOps service connection for the ERP dev environment"
}
EOF
az ad app federated-credential create --id "$APP_ID" --parameters @/tmp/fic.json

# 4. Role assignments - scoped to resource groups, NOT the subscription
for rg in platform data aks network; do
  RG_NAME="rg-erp-dev-cin-${rg}"
  az role assignment create \
    --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}" \
    --only-show-errors -o none && echo "  Contributor on ${RG_NAME}"
done

cat >> ~/.erp-lab-env <<EOF
export CI_APP_ID="$APP_ID"
export CI_SP_OID="$SP_OID"
EOF
```

> You get the `<your-azdo-org-guid>` from the Azure DevOps side — in practice
> you let Azure DevOps create the whole thing by choosing **Workload Identity
> federation (automatic)** when you create the service connection, and it
> writes the app registration and federated credential for you. Chapter 08 §4
> walks that path. Doing it manually once, as above, is how you understand
> what that button actually did.

### Why this matters, stated for an interviewer

> We removed client secrets from CI entirely. The service connection uses
> workload identity federation: Azure DevOps presents a short-lived OIDC token
> that Entra ID trusts because of a federated credential pinned to that exact
> organisation, project and service-connection name. There is nothing to
> rotate, nothing to store in a variable group, and nothing that can be
> exfiltrated and replayed — the token is minutes-long and audience-bound. It
> also removed a whole class of outage: pipelines failing at 2 a.m. because a
> two-year secret expired.

---

## 4. Workload identity for pods — THE core mechanism

### The chain, memorised

```
┌──────────────────────────────────────────────────────────────┐
│ 1. Pod carries the LABEL   azure.workload.identity/use: true │
│    → the mutating webhook injects env vars and a projected   │
│      token volume at /var/run/secrets/azure/tokens/          │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Pod's ServiceAccount is ANNOTATED                         │
│      azure.workload.identity/client-id: <MI client id>       │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. The managed identity has a FEDERATED CREDENTIAL:          │
│      issuer  = the AKS cluster's OIDC issuer URL             │
│      subject = system:serviceaccount:erp:erp-api-sa          │
│      audience= api://AzureADTokenExchange                    │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Azure SDK (DefaultAzureCredential) reads the projected    │
│    token, POSTs it to Entra ID, gets an ACCESS TOKEN back    │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. Token presented to Key Vault / ACR / PostgreSQL,          │
│    which authorise via RBAC on the managed identity          │
└──────────────────────────────────────────────────────────────┘
```

**LABEL on the pod, ANNOTATION on the service account.** Mixing those up is
the #1 cause of "it just does not work", and saying it correctly without
hesitating is a small but real signal.

### Where each piece lives in this repo

| Step | File |
|---|---|
| 1. pod label | [`k8s/helm/erp/templates/api-deployment.yaml`](../k8s/helm/erp/templates/api-deployment.yaml) — `azure.workload.identity/use: "true"` |
| 2. SA annotation | [`k8s/helm/erp/templates/serviceaccounts.yaml`](../k8s/helm/erp/templates/serviceaccounts.yaml) |
| 3. federated credential | [`infra/terraform/modules/identity/main.tf`](../infra/terraform/modules/identity/main.tf) — `azurerm_federated_identity_credential` |
| 4. SDK usage | [`src/erp-api/app/core/db.py`](../src/erp-api/app/core/db.py) — `DefaultAzureCredential` |
| 5. RBAC | same identity module — `Key Vault Secrets User`, `AcrPull` |

### Verify the whole chain, step by step

```bash
cd infra/terraform/envs/dev
az aks get-credentials -g "$(terraform output -raw aks_resource_group)" \
  -n "$(terraform output -raw aks_name)" --overwrite-existing

# --- Is the OIDC issuer enabled on the cluster? ---
az aks show -g "$(terraform output -raw aks_resource_group)" \
  -n "$(terraform output -raw aks_name)" \
  --query '{oidc:oidcIssuerProfile.enabled, url:oidcIssuerProfile.issuerURL, wi:securityProfile.workloadIdentity.enabled}' \
  -o json

# --- Is the webhook running? ---
kubectl get pods -n kube-system -l azure-workload-identity.io/system=true

# --- Does the service account carry the right annotation? ---
kubectl -n erp get sa erp-api-sa -o jsonpath='{.metadata.annotations}' | jq

# --- Does the federated credential subject match EXACTLY? ---
PLATFORM_RG=$(terraform output -json resource_groups | jq -r .platform)
az identity federated-credential list \
  --identity-name id-erp-api-dev -g "$PLATFORM_RG" \
  --query '[].{name:name, subject:subject, issuer:issuer}' -o json

# --- Did the pod get the injected env and the token file? ---
kubectl -n erp exec deploy/erp-api -- env | grep AZURE_
# Expect: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE,
#         AZURE_AUTHORITY_HOST

kubectl -n erp exec deploy/erp-api -- \
  sh -c 'wc -c < /var/run/secrets/azure/tokens/azure-identity-token'
# Expect a few thousand bytes. A missing file means the LABEL is wrong.

# --- Does the token actually work end to end? ---
kubectl -n erp exec deploy/erp-api -- python -c "
from azure.identity import DefaultAzureCredential
t = DefaultAzureCredential().get_token('https://ossrdbms-aad.database.windows.net/.default')
print('token acquired, expires', t.expires_on)
"
```

### Decode the projected token to see what is really in it

This is a great thing to have done once — it makes the whole mechanism
concrete rather than magical.

```bash
kubectl -n erp exec deploy/erp-api -- \
  cat /var/run/secrets/azure/tokens/azure-identity-token > /tmp/sa-token.jwt

# Decode the payload (base64url, pad it out)
python - <<'PY'
import base64, json
tok = open('/tmp/sa-token.jwt').read().strip().split('.')[1]
tok += '=' * (-len(tok) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(tok)), indent=2))
PY
```

You will see:

```json
{
  "aud": ["api://AzureADTokenExchange"],
  "iss": "https://centralindia.oic.prod-aks.azure.com/<tenant>/<cluster>/",
  "sub": "system:serviceaccount:erp:erp-api-sa",
  "exp": 1763...,
  "kubernetes.io": {
    "namespace": "erp",
    "serviceaccount": { "name": "erp-api-sa" },
    "pod": { "name": "erp-api-7d9..." }
  }
}
```

**`iss` must equal the federated credential's issuer. `sub` must equal the
federated credential's subject, character for character.** That is the whole
trust relationship, visible in one object.

---

## 5. The three failure modes you will actually hit

### A. `AADSTS70021: No matching federated identity record found`

The subject does not match. Causes, in frequency order:

```bash
# Is the namespace right? erp vs default
# Is the SA name right? erp-api-sa vs erp-api
# Did you deploy to a different namespace than the FIC was created for?

PLATFORM_RG=$(terraform output -json resource_groups | jq -r .platform)
az identity federated-credential list --identity-name id-erp-api-dev -g "$PLATFORM_RG" \
  --query '[].subject' -o tsv
# Must read exactly: system:serviceaccount:erp:erp-api-sa

kubectl -n erp get pod -l app.kubernetes.io/component=api \
  -o jsonpath='{.items[0].spec.serviceAccountName}{"\n"}'
```

### B. No `AZURE_CLIENT_ID` in the pod's environment

The **pod label** is missing, so the webhook never mutated the pod.

```bash
kubectl -n erp get pod -l app.kubernetes.io/component=api \
  -o jsonpath='{.items[0].metadata.labels}' | jq
# Must contain: "azure.workload.identity/use": "true"
```

Note: adding the label to the Deployment's `spec.template.metadata.labels`
requires a **pod restart** to take effect. The webhook only runs at pod
admission.

### C. `password authentication failed for user "id-erp-api-dev"`

The token is fine. **PostgreSQL has no role for the identity.** This is the
step everybody forgets, including the Azure docs quickstarts.

```bash
./scripts/db-grant-identities.sh dev
```

Chapter 06 covers it fully. Remember the function name:
**`pgaadauth_create_principal`**.

---

## 6. Okta SSO/MFA integration

The JD explicitly asks for "integrating Microsoft Entra ID with Okta for
SSO/MFA". You will not have an Okta tenant, so understand the pattern and be
able to draw it.

### The two directions — know which one you are being asked about

**Direction 1: Okta as the identity provider, Entra ID as the service
provider.** Okta holds the workforce identities; Azure trusts Okta.

```
User ──► Azure portal / your app
              │ redirects to
              ▼
       Entra ID ("federated domain contoso.com")
              │ SAML/WS-Fed redirect
              ▼
           Okta  ──► MFA (Okta Verify / FIDO2)
              │ SAML assertion back
              ▼
       Entra ID issues its own token ──► app
```

Set up with:
```powershell
# Entra ID side: mark the domain as federated to Okta
Update-MgDomainFederationConfiguration `
  -DomainId "contoso.com" `
  -IssuerUri "http://www.okta.com/exk1a2b3c4d5" `
  -PassiveSignInUri "https://contoso.okta.com/app/.../sso/saml" `
  -SigningCertificate "<base64 cert from Okta>" `
  -PreferredAuthenticationProtocol Saml
```

**Direction 2: Entra ID as IdP, Okta as SP.** Rarer; Okta-protected apps
trust Azure.

**Direction 3 (the modern answer): Okta as an external authentication
method.** Entra ID stays the IdP and the token issuer, but delegates the MFA
step to Okta via the External Authentication Methods API. This is usually the
right design now because you keep Conditional Access, Identity Protection and
Entra audit logs, and only outsource the factor.

### How our application handles it

Look at [`src/erp-api/app/core/security.py`](../src/erp-api/app/core/security.py).

The key insight: **both Entra ID and Okta are plain OIDC**, so one validator
handles both. What differs is three config values and one claim name:

| | Entra ID | Okta |
|---|---|---|
| issuer | `https://login.microsoftonline.com/<tid>/v2.0` | `https://<org>.okta.com/oauth2/default` |
| JWKS | `<issuer>/discovery/v2.0/keys` | `<issuer>/v1/keys` |
| audience | the API's app id URI, e.g. `api://erp-api` | the Okta API's audience |
| roles claim | `roles` (app roles) | `groups` |

```python
self.roles = list(claims.get("roles") or claims.get("groups") or [])
```

One line, both providers. **That is the answer to "how would you support
both?"** — not two code paths, one OIDC validator with configurable issuer,
audience and claim mapping.

### Test it without an Okta tenant

Use Entra ID as the issuer and prove the code path works:

```bash
source ~/.erp-lab-env

# Expose the API as an Entra application with an app role
API_APP_ID=$(az ad app create --display-name "erp-api" \
  --identifier-uris "api://erp-api" --query appId -o tsv)

# Define an app role so the roles claim is populated
cat > /tmp/roles.json <<'EOF'
[{
  "allowedMemberTypes": ["User", "Application"],
  "description": "Full ERP administration",
  "displayName": "ERP Admin",
  "id": "8a1f3d2e-0000-4000-8000-000000000001",
  "isEnabled": true,
  "value": "erp.admin"
}]
EOF
az ad app update --id "$API_APP_ID" --app-roles @/tmp/roles.json

# Turn auth on in the deployment and watch unauthenticated calls get 401
helm upgrade erp k8s/helm/erp -n erp --reuse-values \
  --set config.authEnabled=true \
  --set config.oidcIssuer="https://login.microsoftonline.com/${TENANT_ID}/v2.0" \
  --set config.oidcAudience="api://erp-api"

kubectl -n erp port-forward svc/erp-api 8000:8000 &
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/api/v1/products
# 401 - correct, no token

TOKEN=$(az account get-access-token --resource "api://erp-api" --query accessToken -o tsv)
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/products
# 200 - the OIDC path works
```

---

## 7. AKS and Entra ID — two RBAC systems, not one

This confuses almost everyone, so be crisp about it.

```
┌─────────────────────────────────────────────────────────────┐
│ AZURE RBAC  (control plane)                                 │
│   Can I call the ARM API about this cluster?                 │
│   e.g. "Azure Kubernetes Service Cluster User Role"          │
│        → lets you run `az aks get-credentials`               │
│   e.g. "Contributor" on the cluster                          │
│        → lets you scale node pools, change cluster config    │
└─────────────────────────────────────────────────────────────┘
                            ↓ gives you a kubeconfig
┌─────────────────────────────────────────────────────────────┐
│ KUBERNETES RBAC  (data plane)                               │
│   Can I get/list/create this Kubernetes object?              │
│   Option A: in-cluster Role/RoleBinding → Entra GROUP        │
│   Option B: Azure RBAC for Kubernetes ("AKS RBAC Writer")    │
└─────────────────────────────────────────────────────────────┘
```

**You need BOTH.** `Cluster User Role` alone gets you a kubeconfig and then
`Error from server (Forbidden)` on every command. That exact symptom is a
good interview anecdote.

### The two integration modes

| | **Entra-integrated with K8s RBAC** | **Azure RBAC for Kubernetes** |
|---|---|---|
| Permissions defined in | `Role`/`RoleBinding` YAML, in git | Azure role assignments |
| Subject | Entra group **object id** | Entra group/user/SP |
| Granularity | full Kubernetes RBAC | 4 built-in roles + custom |
| Works offline from ARM | yes | no, needs ARM reachable |
| Reviewable with `az role assignment list` | no | yes |

Our cluster enables **both** (`azure_rbac_enabled = true` plus
`k8s/base/rbac.yaml`), which is the realistic enterprise setup: Azure RBAC for
coarse roles, in-cluster RBAC for the fine-grained namespace permissions.

### The group-binding syntax that catches people

```yaml
subjects:
  - kind: Group
    name: "00000000-0000-0000-0000-000000000001"   # the OBJECT ID
    apiGroup: rbac.authorization.k8s.io            # required
```

Not the display name. **The object id.** Kubernetes has no idea what
`grp-erp-developers` means; the token contains group object ids in the `groups`
claim, and that is what the binding matches.

```bash
# Get the object id to paste in
az ad group show -g "grp-erp-developers" --query id -o tsv
```

### Verify effective permissions

```bash
# What can I do?
kubectl auth can-i --list -n erp

# What can a developer do? (impersonation needs cluster-admin)
kubectl auth can-i get pods -n erp \
  --as-group="00000000-0000-0000-0000-000000000001"
kubectl auth can-i get secrets -n erp \
  --as-group="00000000-0000-0000-0000-000000000001"   # should be "no"
kubectl auth can-i create pods/exec -n erp \
  --as-group="00000000-0000-0000-0000-000000000001"   # should be "no"
```

That last one matters: **`pods/exec` is effectively root on the pod.** A
developer with exec can read every environment variable and mounted secret,
bypassing the fact that you denied them `secrets`. Granting `pods/log` but not
`pods/exec` is a deliberate, defensible line — and explaining *why* is a
strong answer.

---

## 8. Break it on purpose

**Exercise A — the subject mismatch (the #1 real-world failure)**

```bash
PLATFORM_RG=$(cd infra/terraform/envs/dev && terraform output -json resource_groups | jq -r .platform)

# Break the federated credential subject
az identity federated-credential create \
  --identity-name id-erp-api-dev -g "$PLATFORM_RG" \
  --name fic-broken \
  --issuer "$(cd infra/terraform/envs/dev && terraform output -raw aks_oidc_issuer_url)" \
  --subject "system:serviceaccount:erp:WRONG-NAME" \
  --audiences api://AzureADTokenExchange

# Delete the good one
az identity federated-credential delete \
  --identity-name id-erp-api-dev -g "$PLATFORM_RG" \
  --name fic-api-erp --yes

kubectl -n erp rollout restart deploy/erp-api
kubectl -n erp logs -l app.kubernetes.io/component=api --tail=40
```

You will see `AADSTS70021: No matching federated identity record found for
presented assertion`. **Burn that error message into memory** — it means
"subject or issuer mismatch", always.

Restore:
```bash
cd infra/terraform/envs/dev && terraform apply -auto-approve
kubectl -n erp rollout restart deploy/erp-api
```

**Exercise B — remove the pod label**

```bash
kubectl -n erp patch deploy erp-api --type json \
  -p '[{"op":"remove","path":"/spec/template/metadata/labels/azure.workload.identity~1use"}]'

kubectl -n erp rollout status deploy/erp-api
kubectl -n erp exec deploy/erp-api -- env | grep AZURE_ || echo "NO AZURE ENV - webhook did not fire"
kubectl -n erp exec deploy/erp-api -- ls /var/run/secrets/azure/tokens/ || echo "NO TOKEN FILE"
```

Note the `~1` — that is JSON Pointer escaping for `/` in the label key. A
small thing that will save you five minutes one day.

Restore:
```bash
helm upgrade erp k8s/helm/erp -n erp -f k8s/helm/erp/values-dev.yaml --reuse-values
```

**Exercise C — over-privileged identity, and why least privilege matters**

```bash
KV_NAME=$(cd infra/terraform/envs/dev && terraform output -raw key_vault_name)
API_PRINCIPAL=$(az identity show -n id-erp-api-dev -g "$PLATFORM_RG" --query principalId -o tsv)

# Upgrade the API from "Secrets User" to "Secrets Officer"
az role assignment create --assignee-object-id "$API_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets Officer" \
  --scope "$(az keyvault show -n "$KV_NAME" --query id -o tsv)"

sleep 30
# The API pod can now WRITE and DELETE secrets.
kubectl -n erp exec deploy/erp-api -- python -c "
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
c = SecretClient('https://${KV_NAME}.vault.azure.net/', DefaultAzureCredential())
c.set_secret('proof-of-overprivilege', 'a compromised pod wrote this')
print('WROTE A SECRET - this is why Secrets User is the right role')
"
```

Revert immediately:
```bash
az role assignment delete --assignee-object-id "$API_PRINCIPAL" \
  --role "Key Vault Secrets Officer" \
  --scope "$(az keyvault show -n "$KV_NAME" --query id -o tsv)"
```

The lesson, stated for an interview: *"The API reads secrets, so it has
Secrets User, not Secrets Officer. The difference is whether a single
application-level RCE becomes a secret-tampering incident."*

---

## 9. Interview answers this chapter gives you

**"Explain managed identity versus service principal."** *(near-certain question)*

> A service principal is the identity object an application uses in a tenant.
> By default it authenticates with a credential you manage — a client secret
> or a certificate — which means you have a rotation problem and a storage
> problem. A managed identity is a service principal whose credential Azure
> creates, stores and rotates; you never see it and there is nothing to leak.
> There are two kinds: system-assigned, which is bound to one resource's
> lifecycle, and user-assigned, which is a standalone resource you can attach
> to several things. In this platform every workload has its own user-assigned
> identity — separate identities for the API, the worker and the migration
> job — so a compromise of one does not give access to what the others can
> reach. The migration job's identity is the only one with DDL rights on the
> database, which is the whole point of splitting them.

**"How do pods authenticate to Azure services without secrets?"** *(the one to
nail)*

> Workload identity, which is OIDC federation rather than a stored credential.
> The AKS cluster exposes an OIDC issuer. Each managed identity has a
> federated credential that trusts that issuer for one exact subject:
> `system:serviceaccount:<namespace>:<serviceaccount>`. A pod labelled
> `azure.workload.identity/use: "true"` gets a projected service-account token
> mounted by a mutating webhook, plus the client id and tenant id as
> environment variables. `DefaultAzureCredential` reads that token and
> exchanges it with Entra ID for an access token, which it then presents to
> Key Vault or PostgreSQL. Nothing is stored, nothing is rotated, and the
> token lives for minutes. The two details people get wrong: the label goes on
> the *pod*, the annotation goes on the *service account*; and for PostgreSQL
> you still have to create a database principal for the identity with
> `pgaadauth_create_principal`, or you get a password authentication error
> even though the token is perfectly valid.

**"How would you integrate Okta with Entra ID?"**

> It depends which way the trust goes, and I would clarify that first. The
> common enterprise case is Okta as the identity provider with Entra ID as a
> federated service provider: you mark the domain as federated in Entra and
> point it at Okta's SAML endpoint, so authentication and MFA happen in Okta
> and Entra issues its own token afterwards. The modern alternative, and the
> one I would usually recommend now, is to keep Entra as the IdP and configure
> Okta as an external authentication method — you delegate only the MFA factor
> and keep Conditional Access, Identity Protection and the Entra audit trail.
> On the application side it barely matters: both are OIDC, so our API uses
> one validator with configurable issuer, audience and JWKS URI, and the only
> real difference is the claim carrying authorisation — `roles` for Entra app
> roles, `groups` for Okta. That is a config change, not a code change.

**"What is the difference between Azure RBAC and Kubernetes RBAC on AKS?"**

> They answer different questions and you need both. Azure RBAC controls the
> ARM API: can I get credentials for this cluster, can I scale a node pool,
> can I change the cluster configuration. Kubernetes RBAC controls the
> Kubernetes API: can I list pods in this namespace, can I read a secret. The
> classic symptom of getting it wrong is a user who can run
> `az aks get-credentials` successfully and then gets Forbidden on every
> `kubectl` command — they have the control-plane role but no data-plane
> binding. Our cluster is Entra-integrated with Azure RBAC enabled, so coarse
> roles come from Azure role assignments and fine-grained namespace
> permissions come from in-cluster Roles bound to Entra group object ids. And
> one deliberate detail in those Roles: developers get `pods/log` and
> `pods/portforward` but not `pods/exec` and not `secrets`, because exec is
> effectively root on the pod and would make the secrets restriction
> meaningless.

**"A pipeline's credentials expired over the weekend. How do you prevent
that?"**

> Remove the credential. That failure mode only exists because something is
> holding a secret with an expiry date. With workload identity federation the
> pipeline presents a short-lived OIDC token that Entra trusts because of a
> federated credential pinned to the organisation, project and service
> connection — there is no secret and nothing to expire. If federation is
> genuinely not possible, then: certificate rather than secret, stored in Key
> Vault, with an expiry alert at 30 days and a documented rotation runbook,
> and the expiry date tracked as an asset rather than discovered by an outage.

---

## Checklist

- [ ] You can define tenant / app registration / service principal / managed identity without hesitating
- [ ] You know when to use system-assigned vs user-assigned
- [ ] CI service principal created with a **federated credential**, no secret
- [ ] You can recite the 5-step workload identity chain
- [ ] **LABEL on pod, ANNOTATION on service account** — said without pausing
- [ ] You decoded the projected SA token and saw `iss` and `sub`
- [ ] Verified `AZURE_CLIENT_ID` and the token file inside a running pod
- [ ] Acquired a real Azure token from inside a pod
- [ ] You have seen `AADSTS70021` and know it means subject/issuer mismatch
- [ ] You can draw both Okta federation directions
- [ ] You can explain why one OIDC validator handles Entra and Okta
- [ ] You can explain Azure RBAC vs Kubernetes RBAC and the Forbidden symptom
- [ ] Entra group bindings use **object ids**, and you know why
- [ ] `kubectl auth can-i` used to prove a developer cannot read secrets or exec
- [ ] All three "break it" exercises done and reverted

Next: [chapter 05 — Secure AKS platform](05-aks-platform.md)
