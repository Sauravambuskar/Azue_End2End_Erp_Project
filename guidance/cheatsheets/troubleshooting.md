# Troubleshooting cheatsheet — the 25 failures you will actually hit

Organised by **symptom**, because that is what you have at 2 a.m.

Work through this list deliberately once (chapter 14 §6 calls it "break-it
day"). Having *seen* a failure is worth ten times having read about it.

---

## Terraform

### 1. `Error: building account: could not acquire access token`
```
Cause: not logged in, or the wrong subscription is selected.
Fix:   az login && az account set --subscription "<name>"
```

### 2. `AuthorizationPermissionMismatch` on the state backend
```
Cause: the storage account has shared-key access disabled (correct!) but
       Terraform is not using Entra ID auth.
Fix:   export ARM_USE_AZUREAD=true
       and confirm you have "Storage Blob Data Contributor" on the account:
       az role assignment list --scope <sa-id> --assignee <your-oid> -o table
```

### 3. `Error acquiring the state lock`
```
Cause: a previous run died and left the blob lease held.
Fix:   terraform force-unlock <LOCK_ID>        # the id is IN the error message
       Verify nobody else is actually running first - force-unlocking a live
       apply is how state gets corrupted.
```

### 4. `MissingSubscriptionRegistration`
```
Cause: the resource provider is not registered on this subscription.
Fix:   az provider register --namespace Microsoft.ContainerService
       Takes a few minutes. Chapter 01 §4 registers everything up front.
```

### 5. The identity module fails with an empty OIDC issuer URL
```
Cause: the federated credential needs the AKS OIDC issuer, which does not
       exist until the cluster does. Genuine first-run ordering wrinkle.
Fix:   terraform apply        # just run it again
```

### 6. `A resource with the ID ... already exists`
```
Cause: the resource exists in Azure but not in state - usually a partially
       failed apply, or someone created it in the portal.
Fix:   terraform import <address> <azure-resource-id>
       e.g. terraform import module.acr.azurerm_container_registry.this \
              /subscriptions/.../registries/acrerpdev123
```

### 7. State and reality have diverged badly
```bash
terraform plan -refresh-only              # see the drift without changing code
terraform state list
terraform state rm <address>              # forget a resource
terraform state show <address>            # inspect what state thinks
# Nuclear: delete the RGs in Azure, then empty the state
terraform state list | while read -r r; do terraform state rm "$r"; done
```

---

## AKS and Kubernetes

### 8. `kubectl` returns `Forbidden` on everything, right after `get-credentials`
```
Cause: you have the Azure control-plane role but no Kubernetes RBAC binding.
       These are two separate systems.
Fix:   Either be in an admin group (admin_group_object_ids), or have an Azure
       RBAC role: "Azure Kubernetes Service RBAC Reader/Writer/Admin".
Check: kubectl auth can-i --list
```

### 9. `kubectl` hangs, or opens a device-code prompt
```
Cause: Entra-integrated cluster without kubelogin converting the kubeconfig.
Fix:   kubelogin convert-kubeconfig -l azurecli
       In a pipeline this is mandatory, or the run hangs until timeout.
```

### 10. Pod `Pending`
```bash
kubectl -n erp describe pod <pod> | tail -20   # READ THE EVENTS
```
| Event text | Cause | Fix |
|---|---|---|
| `Insufficient cpu`/`memory` | no node has room | wait for the autoscaler (2–5 min), or raise max-count |
| `exceeded quota` | the namespace ResourceQuota | `kubectl -n erp describe resourcequota` |
| `node(s) had untolerated taint` | targeting the tainted system pool | check `nodeSelector` |
| `didn't match Pod's node affinity` | nodeSelector matches no node | `kubectl get nodes --show-labels` |
| `0/2 nodes are available: 2 node(s) had volume node affinity conflict` | PVC is zone-pinned to a zone with no node | recreate the PVC, or add a node in that zone |

### 11. `CrashLoopBackOff`
```bash
kubectl -n erp logs <pod> --previous --tail=50    # --previous is essential
kubectl -n erp describe pod <pod> | grep -A5 "Last State"
```
| Exit code | Meaning |
|---|---|
| **137** | 128+9 SIGKILL → **OOMKilled**, or an external kill |
| **143** | 128+15 SIGTERM → graceful shutdown; something evicted it |
| 1, 2 | application error — read the logs |
| 126 | the command is not executable |
| 127 | the command was not found (wrong entrypoint path) |

If logs are empty, the process dies before logging — usually a missing env var
or a config parse failure. Check the ConfigMap keys actually exist.

### 12. `ImagePullBackOff`
```bash
kubectl -n erp describe pod <pod> | grep -A5 Events
```
| Message | Cause | Fix |
|---|---|---|
| `manifest unknown` / `not found` | the tag does not exist | `az acr repository show-tags -n <acr> --repository erp-api` |
| `401 Unauthorized` / `403` | kubelet identity lacks AcrPull | grant AcrPull to the kubelet identity on the ACR |
| `no such host` | ACR private endpoint DNS not resolving | check the private DNS zone VNet link |
| `x509: certificate signed by unknown authority` | corporate proxy MITM | add the CA to the node trust store |

### 13. Pod `Running` but never `Ready`
```bash
kubectl -n erp get endpoints erp-api    # empty = no Ready pods
kubectl -n erp exec deploy/erp-api -- curl -s localhost:8000/healthz/ready | jq
```
By design in this project, readiness touches the database and liveness does
not — so a `Running`/not-`Ready` pod means a **dependency** is down, not the
app. Go to §15–18.

### 14. Pod stuck `ContainerCreating`
```bash
kubectl -n erp describe pod <pod> | grep -A10 Events
kubectl -n kube-system logs -l app=secrets-store-provider-azure --tail=50
```
Almost always the Key Vault CSI driver. The pod event says "FailedMount"; the
**provider log** says why — usually a 403 from Key Vault or an identity
mismatch. Check all three: the `SecretProviderClass` clientID, the identity's
`Key Vault Secrets User` role, and the pod label + SA annotation.

---

## Identity

### 15. `AADSTS70021: No matching federated identity record found`
```
Cause: the federated credential's subject or issuer does not match.
Check: az identity federated-credential list --identity-name id-erp-api-dev \
         -g <platform-rg> --query '[].{sub:subject,iss:issuer}'
       Must be EXACTLY: system:serviceaccount:<namespace>:<sa-name>
       And the issuer must equal the cluster's oidcIssuerProfile.issuerURL.
```

### 16. No `AZURE_CLIENT_ID` in the pod environment
```
Cause: the pod is missing the LABEL azure.workload.identity/use: "true", so
       the mutating webhook never fired.
Check: kubectl -n erp get pod <pod> -o jsonpath='{.metadata.labels}'
Note:  LABEL on the pod, ANNOTATION on the service account. Adding the label
       requires a pod restart - the webhook only runs at admission.
```

### 17. `password authentication failed for user "id-erp-api-dev"`
```
Cause: the token is fine; PostgreSQL has no principal for the identity.
Fix:   ./scripts/db-grant-identities.sh dev
       The function is pgaadauth_create_principal().
```

### 18. `permission denied for table product`
```
Cause: the principal EXISTS but the role was not granted. Different from §17.
Fix:   GRANT erp_app TO "id-erp-api-dev";
```

---

## Networking

### 19. A private endpoint resolves to a **public** IP
```
Cause: the private DNS zone exists but is not LINKED to the VNet asking.
       This is the single most common private-endpoint failure.
Check: az network private-dns link vnet list -g <rg> \
         --zone-name privatelink.postgres.database.azure.com -o table
Test from a POD, not your laptop:
       kubectl run dns --rm -it --restart=Never --image=nicolaka/netshoot -- \
         nslookup <host>
```

### 20. Connection **times out** vs **connection refused**
```
Timeout  → the packet was DROPPED. NetworkPolicy, NSG, or no route.
Refused  → the packet ARRIVED and nothing was listening. App problem.
```
That distinction tells you which half of the stack to look at, in seconds.

```bash
# Ask Azure which rule decided, instead of guessing
az network watcher test-ip-flow -g <rg> --vm <node-vm> \
  --direction Inbound --protocol TCP --local 10.10.4.5:8000 --remote 10.10.16.4:50000
```

### 21. Application Gateway backends `Unknown` or `Unhealthy`
```bash
az network application-gateway show-backend-health -g <rg> -n <agw> -o table
```
| State | Cause |
|---|---|
| `Unknown` | the NSG is missing `GatewayManager` 65200-65535 inbound. **Required.** |
| `Unhealthy`, timeout | the NSG blocks appgw-subnet → AKS, or no pod is Ready |
| `Unhealthy`, 404 | the probe path is wrong; must be `/healthz/ready` |
| no servers at all | AGIC has not reconciled: `kubectl -n kube-system logs -l app=ingress-appgw` |

### 22. VNet peering shows `Initiated`, not `Connected`
```
Cause: peering only created on one side. It must exist on both.
Fix:   create the reverse peering.
Also:  peeringSyncLevel "RemoteNotInSync" → az network vnet peering sync
```

---

## Pipelines

### 23. `This pipeline needs permission to access a resource`
```
Cause: the pipeline has not been authorised for the service connection,
       environment or variable group.
Fix:   click View → Permit in the run, or pre-authorise in
       Service connections → Security → Pipeline permissions.
```

### 24. The deploy stage cannot reach the cluster
```
Cause: Microsoft-hosted agent + private AKS API server. By design.
Fix:   self-hosted agent in the VNet, Managed DevOps Pools, or
       az aks command invoke (which is a deliberate network bypass -
       do not use it in prod).
Also:  missing `kubelogin convert-kubeconfig -l azurecli` → the task hangs.
```

### 25. Helm reports success but the application is broken
```
Cause: missing --wait --atomic. Helm returns as soon as the API server
       accepts the manifests, not when pods are healthy.
Fix:   helm upgrade ... --atomic --wait --timeout 10m
```

---

## Quick diagnostic one-liners

```bash
# What is unhealthy anywhere in the cluster?
kubectl get pods -A --field-selector=status.phase!=Running

# Recent events, most recent last
kubectl get events -A --sort-by=.lastTimestamp | tail -30

# Which pods have restarted?
kubectl get pods -A -o json | jq -r '.items[]
  | select([.status.containerStatuses[]?.restartCount] | add > 0)
  | "\(.metadata.namespace)/\(.metadata.name): \([.status.containerStatuses[].restartCount] | add) restarts"'

# Resource pressure
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -15

# What am I allowed to do?
kubectl auth can-i --list -n erp

# Everything about one deployment, in one go
kubectl -n erp describe deploy erp-api
kubectl -n erp get rs -l app.kubernetes.io/component=api
kubectl -n erp logs -l app.kubernetes.io/component=api --tail=50 --prefix

# Is it Azure's fault?
az rest --method get --url "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01" \
  --query "value[0:5].{title:properties.title, status:properties.status, impact:properties.impactStartTime}" -o table

# What changed in Azure in the last 6 hours?
az monitor activity-log list --offset 6h \
  --query "[?contains(operationName.value,'write')||contains(operationName.value,'delete')].{t:eventTimestamp, who:caller, what:operationName.localizedValue}" \
  -o table

# What changed in the cluster?
helm -n erp history erp
```

---

## The debugging pod you will use constantly

```bash
kubectl -n erp run nst --rm -it --restart=Never --image=nicolaka/netshoot \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"nst","image":"nicolaka/netshoot","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["bash"],"stdin":true,"tty":true}]}}' \
  -- bash
```

> The `--overrides` is needed because the namespace enforces the `restricted`
> Pod Security Standard — a plain `kubectl run` is rejected. That is the
> control working, and having this command saved is genuinely useful.

Inside: `nslookup`, `dig`, `nc`, `curl`, `traceroute`, `tcpdump`, `iftop`,
`ss`, `openssl`.

```bash
# Inspect a pod that has no shell (distroless) without changing it
kubectl -n erp debug deploy/erp-api --image=nicolaka/netshoot --target=api -it -- bash
```

---

## The method, when nothing above matches

1. **What changed?** `helm history`, `az monitor activity-log`, git log. Most
   incidents are the last change.
2. **Narrow the layer.** DNS → TCP → TLS → HTTP → application → database. Test
   each boundary, do not guess which one it is.
3. **Read the actual error.** Azure errors are unusually specific and name the
   policy, the rule or the missing permission. People skim them.
4. **Timeout or refused?** It halves the search space immediately.
5. **Check both sides.** "The app says auth failed" and "the database says
   permission denied" are different problems with the same user-facing symptom.
6. **Reproduce smaller.** A `netshoot` pod in the same namespace removes the
   application from the equation entirely.
