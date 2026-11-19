# 05 — Secure AKS platform

**Time:** 6 hours (do it over two sessions) · **Cost:** ~₹12/hour with 2 nodes
**Prerequisite:** chapters 02–04 complete

This is the biggest chapter and the deepest likely interview dive. The goal is
not "I can create a cluster" — it is being able to justify every setting, and
to debug the cluster when it misbehaves.

---

## 1. The cluster configuration, line by line

Open [`infra/terraform/modules/aks/main.tf`](../infra/terraform/modules/aks/main.tf)
and keep it beside you. Every setting below is in there.

| Setting | Our value | Why — the answer to "why that?" |
|---|---|---|
| `private_cluster_enabled` | `false` dev / `true` prod | prod API server has no public IP; dev stays public but IP-restricted so you cannot lock yourself out |
| `api_server_authorized_ip_ranges` | your `/32` | even a public API server should not be reachable from the whole internet |
| `local_account_disabled` | `false` dev / `true` prod | removes the static cluster-admin certificate; Entra ID becomes the only way in |
| `azure_rbac_enabled` | `true` | Kubernetes authz decisions driven by Azure role assignments |
| `admin_group_object_ids` | `grp-erp-platform-admins` | cluster-admin via a **group**, never a user |
| `oidc_issuer_enabled` | `true` | prerequisite for workload identity |
| `workload_identity_enabled` | `true` | the whole secretless story |
| `network_plugin` | `azure` | real VNet integration, NSGs and UDRs apply |
| `network_plugin_mode` | `overlay` | pods from a non-routable CIDR; removes IP exhaustion |
| `network_policy` | `calico` | pod-to-pod firewalling; Azure NPM is less capable |
| `outbound_type` | `loadBalancer` dev / `userDefinedRouting` prod | prod egress forced through Azure Firewall |
| `azure_policy_enabled` | `true` | Gatekeeper admission control + portal compliance reporting |
| `microsoft_defender` | enabled | runtime threat detection on nodes and containers |
| `key_vault_secrets_provider` | rotation on, 2m | CSI driver; secrets as files, auto-refreshed |
| `only_critical_addons_enabled` | `true` (system pool) | taints the system pool so app pods cannot land on it |
| `os_sku` | `AzureLinux` | smaller attack surface and faster boot than Ubuntu |
| `os_disk_type` | `Ephemeral` | faster, free (uses VM cache), and nodes are cattle |
| `automatic_upgrade_channel` | `patch` | CVE patches applied automatically |
| `node_os_upgrade_channel` | `NodeImage` | node images refreshed weekly |
| `maintenance_window_*` | Sun/Sat 02:00 IST | upgrades happen when nobody is working |
| `image_cleaner_enabled` | `true`, 48h | removes unused images from nodes — disk *and* CVE surface |
| `run_command_enabled` | `false` in prod | `az aks command invoke` bypasses network restrictions; that is a backdoor in prod |
| `sku_tier` | `Free` dev / `Standard` prod | Free has no SLA and a weaker control plane under load |

### The two node pools, and why

```
system pool   1-2 × Standard_D2s_v5   taint: CriticalAddonsOnly=true:NoSchedule
              └─ CoreDNS, metrics-server, CSI drivers, Calico, the
                 workload-identity webhook, the OMS agent

user pool     1-4 × Standard_D2s_v5   label: nodepool-type=user
              └─ erp-api, erp-web, erp-worker
```

**The reasoning:** if application pods and platform add-ons share nodes, a
memory-hungry app can evict CoreDNS, and then *everything* in the cluster
fails DNS resolution simultaneously. That is a cluster-wide outage caused by
one badly-behaved deployment. Separating them bounds the damage. It also means
you can drain, resize or upgrade application capacity without touching the
control-plane-adjacent components.

The Helm chart pins app pods to the user pool with
`nodeSelector: {nodepool-type: user}`.

---

## 2. Connect and look around

```bash
cd infra/terraform/envs/dev
AKS_RG=$(terraform output -raw aks_resource_group)
AKS_NAME=$(terraform output -raw aks_name)

az aks get-credentials -g "$AKS_RG" -n "$AKS_NAME" --overwrite-existing

# Entra-enabled clusters need kubelogin to avoid an interactive device-code
# prompt. In a pipeline this step is mandatory.
kubelogin convert-kubeconfig -l azurecli

kubectl cluster-info
kubectl get nodes -o wide
kubectl get nodes --show-labels | tr ',' '\n' | grep nodepool-type

# What is running on the system pool?
kubectl get pods -A -o wide --field-selector spec.nodeName="$(kubectl get nodes -l nodepool-type=system -o jsonpath='{.items[0].metadata.name}')"

# Confirm the taint is really there
kubectl get nodes -l nodepool-type=system \
  -o jsonpath='{.items[*].spec.taints}' | jq
```

---

## 3. Deploy the ERP

### Build and push the images

```bash
cd /d/Azure
ACR=$(cd infra/terraform/envs/dev && terraform output -raw acr_login_server)
ACR_NAME=$(cd infra/terraform/envs/dev && terraform output -raw acr_name)

az acr login --name "$ACR_NAME"
./scripts/build-and-push.sh "$ACR" v0.1.0
```

The script builds all four images, **verifies none of them runs as root**,
scans with Trivy, and only then pushes. If you have not installed Trivy yet it
warns and continues; install it before chapter 10.

### Apply the cluster baseline

```bash
kubectl apply -f k8s/base/namespace.yaml

# Check the Pod Security Standard label took effect
kubectl get ns erp -o jsonpath='{.metadata.labels}' | jq

kubectl -n erp get resourcequota,limitrange
```

### Grant the identities database access

```bash
./scripts/db-grant-identities.sh dev
```

(If this fails because the server is unreachable, that is expected — chapter 06
§4 covers running it from inside the cluster.)

### Deploy with Helm

```bash
cd infra/terraform/envs/dev
CLIENT_IDS=$(terraform output -json workload_identity_client_ids)
TENANT=$(az account show --query tenantId -o tsv)
PG_FQDN=$(terraform output -raw postgres_fqdn)
cd /d/Azure

helm upgrade --install erp k8s/helm/erp \
  --namespace erp --create-namespace \
  -f k8s/helm/erp/values-dev.yaml \
  --set image.registry="$ACR" \
  --set image.tag=v0.1.0 \
  --set azure.tenantId="$TENANT" \
  --set azure.workloadIdentity.api.clientId="$(echo "$CLIENT_IDS" | jq -r .api)" \
  --set azure.workloadIdentity.web.clientId="$(echo "$CLIENT_IDS" | jq -r .web)" \
  --set azure.workloadIdentity.worker.clientId="$(echo "$CLIENT_IDS" | jq -r .worker)" \
  --set azure.workloadIdentity.migrate.clientId="$(echo "$CLIENT_IDS" | jq -r .migrate)" \
  --set config.db.host="$PG_FQDN" \
  --atomic --wait --timeout 10m
```

### What `--atomic --wait` buys you

Without them, `helm upgrade` returns success as soon as the API server accepts
the manifests — even if every pod then crash-loops. With them, Helm waits for
readiness and, on failure, **rolls back to the previous revision
automatically**. In a pipeline that is the difference between "the deploy
failed and prod is broken" and "the deploy failed and prod is still on the
last good version".

### Verify

```bash
kubectl -n erp get all
kubectl -n erp get pods -o wide
helm -n erp status erp
helm -n erp history erp

# Reach the UI
kubectl -n erp port-forward svc/erp-web 3000:3000 &
# open http://localhost:3000

# Run the business-level smoke test
kubectl -n erp port-forward svc/erp-api 8000:8000 &
./scripts/smoke-test.sh http://localhost:8000
# Expect: ALL SMOKE TESTS PASSED (27 checks)
```

---

## 4. Pod security — the layers, in order of who stops you first

```
1. Pod Security Admission  (API server, free, built in)
     namespace labelled pod-security.kubernetes.io/enforce: restricted
     → rejects privileged, hostPath, hostNetwork, root, added capabilities

2. Azure Policy / Gatekeeper  (admission webhook)
     → rules PSA cannot express: "images only from our ACR",
       "every container must set resource limits"
     → plus compliance reporting in the Azure portal

3. The manifest itself  (securityContext in the Helm chart)
     → runAsNonRoot, readOnlyRootFilesystem, drop ALL capabilities,
       seccompProfile RuntimeDefault

4. The image  (Dockerfile)
     → non-root USER, multi-stage so no compilers ship,
       no package manager left in the final layer
```

**Defence in depth means a manifest applied by hand still gets stopped.**
Layer 3 alone is a convention; layers 1 and 2 are controls.

### Prove PSA is enforcing

```bash
# Try to run a privileged pod in the erp namespace
kubectl -n erp run evil --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"evil","image":"busybox","securityContext":{"privileged":true}}]}}' \
  -- sleep 300
```

Expected:

```
Error from server (Forbidden): pods "evil" is forbidden: violates PodSecurity
"restricted:latest": privileged (container "evil" must not set
securityContext.privileged=true), allowPrivilegeEscalation != false, ...
```

That error lists **every** violation at once, which is genuinely helpful.

```bash
# Try hostPath - also blocked
kubectl -n erp run hostmount --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"h","hostPath":{"path":"/"}}],"containers":[{"name":"c","image":"busybox","volumeMounts":[{"name":"h","mountPath":"/host"}]}]}}' \
  -- sleep 300

# And a plain root container
kubectl -n erp run rootpod --image=nginx --restart=Never
```

### Prove the running pods are actually hardened

```bash
# Can the API pod write to its root filesystem?
kubectl -n erp exec deploy/erp-api -- sh -c 'touch /evil 2>&1' || echo "read-only rootfs confirmed"

# /tmp IS writable - that is the deliberate tmpfs mount
kubectl -n erp exec deploy/erp-api -- sh -c 'touch /tmp/ok && echo "/tmp writable, as designed"'

# What uid?
kubectl -n erp exec deploy/erp-api -- id
# uid=10001 gid=10001

# What capabilities?
kubectl -n erp exec deploy/erp-api -- sh -c 'cat /proc/1/status | grep Cap'
# CapEff should be 0000000000000000
```

> **Why `readOnlyRootFilesystem` needs a tmpfs mount:** Python writes
> `__pycache__`, and uvicorn writes nothing but many libraries expect a
> writable `/tmp`. The chart mounts an `emptyDir` with `medium: Memory` and a
> 64Mi `sizeLimit` — in memory so it is fast and never touches the node disk,
> and size-limited so a runaway log cannot fill node memory.

---

## 5. NetworkPolicy — zero trust inside the cluster

Read [`k8s/helm/erp/templates/networkpolicy.yaml`](../k8s/helm/erp/templates/networkpolicy.yaml).

The model: **default deny everything, then allow exactly three flows.**

```bash
kubectl -n erp get networkpolicy
```

| Policy | Allows |
|---|---|
| `default-deny-all` | nothing (both directions) |
| `allow-dns-egress` | every pod → CoreDNS in kube-system, port 53 only |
| `allow-ingress-to-web` | ingress-controller namespace → web:3000 |
| `allow-web-to-api` | web pods → api:8000 |
| `allow-web-egress-to-api` | web → api, and web → internet:443 for Entra tokens |
| `allow-api-worker-egress-to-data` | api/worker/migrate → 10.10.0.0/16:5432 and internet:443 |

### Prove it works

```bash
# Launch a test pod that is NOT labelled as web or api
kubectl -n erp run netshoot --rm -it --restart=Never \
  --image=nicolaka/netshoot \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"netshoot","image":"nicolaka/netshoot","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["sh"],"stdin":true,"tty":true}]}}' \
  -- sh

# Inside the pod:
#   DNS works (allowed for all pods)
nslookup erp-api

#   But connecting to the API is DENIED - it hangs, then times out
nc -zv -w 5 erp-api 8000      # expect: timed out

#   And reaching the database is denied too
nc -zv -w 5 psql-erp-dev-cin-01.postgres.database.azure.com 5432
exit
```

A **timeout, not a connection refused**, is the signature of a NetworkPolicy
drop. `Connection refused` means the packet arrived and nothing was listening;
a hang means it was silently dropped. Knowing that distinction is how you tell
a policy problem from an application problem in ten seconds.

### The IMDS block worth explaining

```yaml
except:
  - 169.254.169.254/32   # Instance Metadata Service
```

Without this, a compromised pod can query IMDS and obtain a token for the
**kubelet's** managed identity — which has `AcrPull` and more. Blocking IMDS
egress from application pods closes a well-known container-escape-adjacent
privilege escalation path. Workload identity does not need IMDS; it uses the
projected token file. **This is an excellent detail to raise unprompted.**

---

## 6. Scaling — all three kinds

### Horizontal Pod Autoscaler

```bash
kubectl -n erp get hpa
kubectl -n erp describe hpa erp-api

# Generate load and watch it scale
kubectl -n erp run load --rm -it --restart=Never --image=williamyeh/hey -- \
  -z 180s -c 50 http://erp-api:8000/api/v1/products

# In another terminal
watch kubectl -n erp get hpa,pods
```

Note the `behavior` block in
[`autoscaling.yaml`](../k8s/helm/erp/templates/autoscaling.yaml):
**scale up fast (100% in 30s), scale down slowly (1 pod per 60s, 5-minute
stabilisation).** The asymmetry is deliberate — flapping replicas cause more
incidents than briefly over-provisioned ones.

### Cluster Autoscaler

```bash
# Force more pods than the nodes can hold
kubectl -n erp scale deploy/erp-api --replicas=20
kubectl -n erp get pods | grep Pending

# Watch the autoscaler react (2-5 minutes for a new node)
kubectl -n erp describe pod <a-pending-pod> | tail -20
kubectl get nodes -w

# Check the autoscaler's own reasoning
kubectl -n kube-system describe configmap cluster-autoscaler-status | head -40

kubectl -n erp scale deploy/erp-api --replicas=1
```

### KEDA — event-driven, the one worth mentioning

HPA scales on CPU and memory. Real workloads scale on **queue depth**. For the
`erp-worker` consuming Service Bus, the right trigger is "how many messages
are waiting", and HPA cannot see that.

```bash
# Install KEDA (not in the Terraform: it is an optional exercise)
az aks update -g "$AKS_RG" -n "$AKS_NAME" --enable-keda
kubectl get pods -n kube-system -l app.kubernetes.io/name=keda-operator
```

```yaml
# A ScaledObject for the worker - scale 0→20 on Service Bus queue depth
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: erp-worker-queue
  namespace: erp
spec:
  scaleTargetRef:
    name: erp-worker-consumer
  minReplicaCount: 0          # scale to ZERO when the queue is empty
  maxReplicaCount: 20
  triggers:
    - type: azure-servicebus
      metadata:
        queueName: erp-events
        namespace: sb-erp-dev-cin
        messageCount: "20"     # one replica per 20 queued messages
      authenticationRef:
        name: keda-wi-auth     # uses workload identity, no connection string
```

**Scale to zero is the headline.** HPA's minimum is 1. KEDA can run no pods at
all until a message arrives — for a batch workload that is a large cost saving
and a point worth making.

### Vertical Pod Autoscaler — and why we do *not* use it

VPA adjusts requests and limits, which means it **restarts pods** to apply
them. For a stateless API that is survivable but disruptive; combined with HPA
on the same metric the two fight each other. The honest answer: use VPA in
`recommendation` mode to *inform* your requests, and set them yourself.

---

## 7. Zero-downtime deployment — prove it, do not claim it

The chart already has the four ingredients:

| Ingredient | Where | What it prevents |
|---|---|---|
| `maxUnavailable: 0` | strategy | dropping below the desired replica count |
| `readinessProbe` | container | traffic to a pod that is not ready |
| `PodDisruptionBudget` | separate object | node drain taking all replicas |
| `terminationGracePeriodSeconds: 30` | pod spec | killing in-flight requests |

### Prove it

```bash
kubectl -n erp scale deploy/erp-api --replicas=3
kubectl -n erp rollout status deploy/erp-api

# Terminal 1 - continuous requests, counting failures
kubectl -n erp port-forward svc/erp-api 8000:8000 &
while true; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:8000/healthz/ready)
  [ "$code" = "200" ] && printf '.' || printf "\n[FAIL %s]\n" "$code"
  sleep 0.2
done

# Terminal 2 - roll the deployment
kubectl -n erp set image deploy/erp-api api="${ACR}/erp-api:v0.1.0"
kubectl -n erp rollout restart deploy/erp-api
kubectl -n erp rollout status deploy/erp-api
```

You should see an unbroken line of dots. **If you see failures**, the usual
causes are: no readiness probe, `maxUnavailable > 0`, or the application not
handling SIGTERM — our Node server explicitly drains on SIGTERM, see
[`src/erp-web/src/server.js`](../src/erp-web/src/server.js).

### Rollback

```bash
helm -n erp history erp
helm -n erp rollback erp 1
kubectl -n erp rollout status deploy/erp-api

# Or at the Kubernetes level
kubectl -n erp rollout undo deploy/erp-api
kubectl -n erp rollout history deploy/erp-api
```

---

## 8. Upgrades — the thing people have never actually done

```bash
# What upgrades are available?
az aks get-upgrades -g "$AKS_RG" -n "$AKS_NAME" -o table

# Control plane first, nodes after - NEVER both in one command in prod
az aks upgrade -g "$AKS_RG" -n "$AKS_NAME" \
  --kubernetes-version 1.32.0 --control-plane-only

# Then each node pool, one at a time
az aks nodepool upgrade -g "$AKS_RG" --cluster-name "$AKS_NAME" \
  -n user --kubernetes-version 1.32.0 --max-surge 33%
```

### The rules that matter

1. **Control plane first, nodes after.** Kubernetes supports a control plane
   up to two minor versions ahead of nodes, never behind.
2. **One minor version at a time.** 1.30 → 1.32 is not allowed; you go
   1.30 → 1.31 → 1.32.
3. **`--max-surge`** controls blast radius and speed. 33% adds a third more
   nodes temporarily, cordons and drains the old ones. `max-surge: 1` is
   slowest and safest; 100% is fastest and needs double the quota.
4. **PDBs can block a drain forever.** A PDB of `minAvailable: 1` with one
   replica means the drain can never evict that pod. The upgrade hangs. This
   is why `values-dev.yaml` disables the PDB at 1 replica — and it is an
   excellent "something that went wrong" story.

```bash
# Check nothing will block a drain before you start
kubectl get pdb -A
kubectl get pods -A -o json | jq -r '
  .items[] | select(.metadata.ownerReferences == null) |
  "\(.metadata.namespace)/\(.metadata.name) - bare pod, will block a drain"'
```

---

## 9. Break it on purpose

**Exercise A — CrashLoopBackOff, and how you actually diagnose it**

```bash
# Point the API at a database that does not exist
kubectl -n erp set env deploy/erp-api ERP_DB_HOST=nope.invalid
kubectl -n erp get pods -w
```

The pod stays `Running` but **not `Ready`** — because liveness does not touch
the database and readiness does. That is the design from
[`health.py`](../src/erp-api/app/routers/health.py) working as intended: a DB
outage removes the pod from service without killing healthy processes.

```bash
kubectl -n erp describe pod -l app.kubernetes.io/component=api | tail -30
kubectl -n erp logs -l app.kubernetes.io/component=api --tail=30
kubectl -n erp get endpoints erp-api    # should have NO addresses
```

Now make it a real crash:

```bash
kubectl -n erp set env deploy/erp-api ERP_LOG_LEVEL=NOT_A_LEVEL
kubectl -n erp get pods
kubectl -n erp logs -l app.kubernetes.io/component=api --previous --tail=30
```

`--previous` is the flag that matters: a crash-looping pod's *current*
container has no logs yet. Restore:

```bash
helm upgrade erp k8s/helm/erp -n erp -f k8s/helm/erp/values-dev.yaml --reuse-values
```

**Exercise B — OOMKilled**

```bash
kubectl -n erp set resources deploy/erp-api --limits=memory=32Mi
kubectl -n erp get pods -w
kubectl -n erp describe pod -l app.kubernetes.io/component=api | grep -A3 "Last State"
# Reason: OOMKilled, Exit Code: 137
```

**137 = 128 + 9 (SIGKILL).** Memorise that: exit 137 is always OOMKilled or an
external kill, never an application error. Exit 143 is 128 + 15 (SIGTERM), a
graceful shutdown.

```bash
kubectl -n erp set resources deploy/erp-api --limits=memory=512Mi
```

**Exercise C — pod stuck Pending**

```bash
kubectl -n erp scale deploy/erp-api --replicas=50
kubectl -n erp get pods | grep Pending | head -3
kubectl -n erp describe pod <pending-pod> | tail -15
```

Read the `Events`. It will say either "Insufficient cpu" (needs a bigger node
/ autoscaler) or "exceeded quota" (the `ResourceQuota` in
`k8s/base/namespace.yaml` is doing its job). Both are good to have seen.

```bash
kubectl -n erp scale deploy/erp-api --replicas=1
```

**Exercise D — ImagePullBackOff**

```bash
kubectl -n erp set image deploy/erp-api api="${ACR}/erp-api:does-not-exist"
kubectl -n erp describe pod -l app.kubernetes.io/component=api | grep -A5 Events
```

Distinguish the two causes from the message: `manifest unknown` means the tag
does not exist; `401 Unauthorized`/`403` means the kubelet identity lacks
`AcrPull`.

```bash
kubectl -n erp set image deploy/erp-api api="${ACR}/erp-api:v0.1.0"
```

---

## 10. Cost control for this chapter

```bash
# Stopping the cluster stops node billing but keeps all configuration
az aks stop -g "$AKS_RG" -n "$AKS_NAME"

# Next session
az aks start -g "$AKS_RG" -n "$AKS_NAME"

# Or keep the control plane and drop app capacity to zero
az aks nodepool scale -g "$AKS_RG" --cluster-name "$AKS_NAME" -n user --node-count 0
```

**Do `az aks stop` at the end of every session.** It takes about three minutes
and saves roughly ₹280/day.

---

## 11. Interview answers this chapter gives you

**"How do you secure an AKS cluster?"** *(expect this; answer in layers)*

> I think about it as five layers. **Control plane:** private cluster so the
> API server has no public IP, local accounts disabled so the static
> cluster-admin certificate does not exist, and Entra ID integration with
> Azure RBAC so authentication and authorisation both go through the
> directory. **Network:** Azure CNI Overlay so NSGs and route tables apply,
> Calico NetworkPolicy with a default-deny in the workload namespace and three
> explicit allowed flows, and egress forced through Azure Firewall with an
> FQDN allow-list. **Identity:** workload identity, so no pod holds a secret
> — each component has its own managed identity with only the roles it needs,
> and application pods are explicitly blocked from reaching IMDS so they
> cannot steal the kubelet's identity. **Workload:** Pod Security Admission at
> restricted level on the namespace, plus Azure Policy with Gatekeeper for the
> rules PSA cannot express, and every container is non-root with a read-only
> root filesystem, all capabilities dropped and the RuntimeDefault seccomp
> profile. **Supply chain:** images built multi-stage so no compilers ship,
> scanned with Trivy before push with a hard fail on fixable criticals, pulled
> from a private ACR with no admin user, and Defender for Containers for
> runtime detection. On top of all that, patch-channel auto-upgrade in a
> maintenance window, and kube-audit-admin logs going to Log Analytics so I
> can answer "who deleted that".

**"Why two node pools?"**

> Isolation of failure. The system pool is tainted `CriticalAddonsOnly`, so
> only platform components land there — CoreDNS, metrics-server, the CSI
> drivers, Calico, the workload identity webhook. Application pods go on the
> user pool. Without that split, a memory leak in an application pod can evict
> CoreDNS, and then every pod in the cluster fails DNS at once — one bad
> deployment becomes a cluster-wide outage. It also lets me upgrade, resize or
> drain application capacity independently of the components that keep the
> cluster itself working.

**"Requests versus limits — how do you set them?"**

> Requests are what the scheduler reserves; limits are what the kernel
> enforces. I always set memory requests and limits, and usually set a CPU
> request but **no CPU limit**. The reason is the mechanism: exceeding a memory
> limit gets the container OOMKilled, which is an abrupt but clean failure and
> protects the node. Exceeding a CPU limit gets you *throttled* by the CFS
> quota — the pod is not killed, it just becomes mysteriously slow, with
> latency spikes that are extremely hard to diagnose. For a latency-sensitive
> API I would rather it use idle CPU than be throttled to meet a number I
> guessed. I set the values from observed usage — App Insights p95 plus
> `kubectl top` — not from a default. And the namespace has a LimitRange so a
> deployment that forgets resources still gets sane defaults rather than
> unbounded ones.

**"A pod is in CrashLoopBackOff. Walk me through it."**

> `kubectl describe pod` first, and I read the Events and the `Last State`
> block — that gives me the exit code immediately. 137 is OOMKilled, so it is
> a limits problem, and `describe` confirms it. 143 is SIGTERM, a graceful
> shutdown, which usually means something external is evicting it. Any other
> non-zero exit is the application, so `kubectl logs --previous` — the
> `--previous` matters because the current container has not produced logs
> yet. If the logs are empty the process is dying before it can log, which
> points at a missing environment variable or a config parse failure, and I
> check the ConfigMap and the injected env. If it is a dependency — the
> database, Key Vault — I exec into a sibling pod and test connectivity
> directly rather than guessing. And if the container will not start at all I
> override the command to `sleep 3600` so I can get a shell inside the real
> image and look around.

**"How do you achieve zero-downtime deployments?"**

> Four things together, and all four are necessary. A rolling update with
> `maxUnavailable: 0`, so the replica count never dips. A readiness probe that
> genuinely checks the dependencies, so a new pod gets traffic only when it
> can serve it — ours checks the database, while liveness deliberately does
> not. A PodDisruptionBudget, so a node drain during an upgrade cannot evict
> every replica at once. And a termination grace period with the application
> handling SIGTERM to drain in-flight requests. Then I verify it rather than
> assume it: I run a request loop during a rollout and count failures. And the
> PDB has a sharp edge worth knowing — `minAvailable: 1` on a single-replica
> deployment makes a node drain hang forever, which is why dev disables it.

---

## Checklist

- [ ] You can justify every setting in the table in §1
- [ ] You can explain the two-node-pool design and the CriticalAddonsOnly taint
- [ ] ERP deployed with Helm, `--atomic --wait`, and you know what they do
- [ ] Smoke test passes 27/27 against the cluster
- [ ] PSA blocked a privileged pod, a hostPath pod and a root pod
- [ ] Verified read-only rootfs, uid 10001 and zero capabilities in a live pod
- [ ] NetworkPolicy proven with netshoot: DNS works, api:8000 times out
- [ ] You can explain why a **timeout** (not refused) means NetworkPolicy
- [ ] You can explain the IMDS egress block and what it prevents
- [ ] HPA scaled under load; you can explain the asymmetric behaviour block
- [ ] Cluster autoscaler added a node for Pending pods
- [ ] You can explain KEDA vs HPA and why scale-to-zero matters
- [ ] Zero-downtime rollout verified with a request loop, zero failures
- [ ] `helm rollback` performed successfully
- [ ] You know the upgrade rules: control plane first, one minor at a time, max-surge
- [ ] You know PDBs can block a drain forever
- [ ] All four "break it" exercises done; you know exit 137 and 143 by heart
- [ ] **`az aks stop` run at the end of the session**

Next: [chapter 06 — Database](06-database.md)
