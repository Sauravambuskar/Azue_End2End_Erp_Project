# kubectl cheatsheet

---

## Context

```bash
kubectl config get-contexts
kubectl config current-context
kubectl config use-context aks-erp-dev-cin-01
kubectl config set-context --current --namespace=erp     # stop typing -n erp

kubectl cluster-info
kubectl version --short
kubectl api-resources | head -30          # what kinds exist on this cluster
kubectl api-versions | grep -i policy
```

---

## Looking at things

```bash
kubectl -n erp get all
kubectl -n erp get pods -o wide                      # includes node and pod IP
kubectl -n erp get pods --show-labels
kubectl -n erp get pods -l app.kubernetes.io/component=api
kubectl -n erp get pods --sort-by=.status.startTime
kubectl -n erp get pods --field-selector=status.phase!=Running
kubectl -n erp get pods -w                           # watch

kubectl -n erp describe pod <pod>                    # EVENTS ARE AT THE BOTTOM
kubectl -n erp get events --sort-by=.lastTimestamp | tail -30
```

Custom columns are far more readable than full YAML:

```bash
kubectl -n erp get pods -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,NODE:.spec.nodeName'
```

One field, via jsonpath:

```bash
kubectl -n erp get pod <pod> -o jsonpath='{.spec.containers[0].image}{"\n"}'
kubectl -n erp get pod <pod> -o jsonpath='{.metadata.labels}' | jq
kubectl -n erp get deploy erp-api -o yaml | less
```

---

## Logs

```bash
kubectl -n erp logs <pod>
kubectl -n erp logs <pod> -f                         # follow
kubectl -n erp logs <pod> --previous                 # A CRASHED CONTAINER
kubectl -n erp logs <pod> --tail=100
kubectl -n erp logs <pod> --since=10m
kubectl -n erp logs <pod> -c <container>             # multi-container pod

# All pods of a component, prefixed so you can tell them apart
kubectl -n erp logs -l app.kubernetes.io/component=api --tail=50 --prefix

# Everything in the release
kubectl -n erp logs -l app.kubernetes.io/part-of=contoso-erp \
  --tail=100 --all-containers --prefix

# A completed Job
kubectl -n erp logs job/erp-migrate-3
```

> `--previous` is the single most useful flag here. A `CrashLoopBackOff` pod's
> *current* container has produced no logs yet; the dead one has the answer.

---

## Exec and debug

```bash
kubectl -n erp exec -it deploy/erp-api -- sh
kubectl -n erp exec deploy/erp-api -- env | sort
kubectl -n erp exec deploy/erp-api -- curl -s localhost:8000/healthz/ready | jq
kubectl -n erp exec deploy/erp-api -- id
kubectl -n erp exec deploy/erp-api -- ls -la /mnt/secrets/

# Port-forward
kubectl -n erp port-forward svc/erp-api 8000:8000
kubectl -n erp port-forward svc/erp-web 3000:3000
kubectl -n erp port-forward deploy/erp-api 8000:8000      # a specific pod

# Ephemeral debug container: attach tooling to a running pod without
# modifying it. Essential for a distroless image with no shell.
kubectl -n erp debug deploy/erp-api --image=nicolaka/netshoot --target=api -it -- bash

# Debug a node
kubectl debug node/<node> -it --image=busybox
```

### The network debugging pod (Pod Security Admission compliant)

```bash
kubectl -n erp run nst --rm -it --restart=Never --image=nicolaka/netshoot \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"nst","image":"nicolaka/netshoot","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["bash"],"stdin":true,"tty":true}]}}' \
  -- bash
```

The `--overrides` is required because the namespace enforces the `restricted`
Pod Security Standard. A plain `kubectl run` is rejected — which is the control
working correctly, not a problem.

Inside: `nslookup`, `dig`, `nc -zv host port`, `curl -v`, `tcpdump`,
`traceroute`, `ss -tlnp`, `openssl s_client`.

---

## Changing things

```bash
kubectl -n erp scale deploy/erp-api --replicas=3
kubectl -n erp set image deploy/erp-api api=<acr>/erp-api:v0.2.0
kubectl -n erp set env deploy/erp-api ERP_LOG_LEVEL=DEBUG
kubectl -n erp set resources deploy/erp-api --limits=memory=512Mi --requests=cpu=100m

kubectl -n erp rollout status deploy/erp-api
kubectl -n erp rollout restart deploy/erp-api          # no spec change needed
kubectl -n erp rollout history deploy/erp-api
kubectl -n erp rollout undo deploy/erp-api
kubectl -n erp rollout undo deploy/erp-api --to-revision=2
kubectl -n erp rollout pause deploy/erp-api            # for a manual canary
kubectl -n erp rollout resume deploy/erp-api
```

Patching:

```bash
kubectl -n erp patch deploy erp-api --type merge \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"api","imagePullPolicy":"Always"}]}}}}'

kubectl -n erp patch hpa erp-api --type merge -p '{"spec":{"minReplicas":5}}'

# JSON patch. Note ~1 is the JSON Pointer escape for "/" in a key name.
kubectl -n erp patch deploy erp-api --type json \
  -p '[{"op":"remove","path":"/spec/template/metadata/labels/azure.workload.identity~1use"}]'
```

---

## Resources and scheduling

```bash
kubectl top nodes
kubectl top pods -n erp
kubectl top pods -A --sort-by=memory | head -15

kubectl describe node <node> | grep -A8 "Allocated resources"
kubectl get nodes --show-labels
kubectl get nodes -l nodepool-type=user
kubectl get nodes -o jsonpath='{.items[*].spec.taints}' | jq

kubectl -n erp get resourcequota,limitrange
kubectl -n erp describe resourcequota erp-quota
```

Which pods have restarted, cluster-wide:

```bash
kubectl get pods -A -o json | jq -r '.items[]
  | select([.status.containerStatuses[]?.restartCount] | add > 0)
  | "\(.metadata.namespace)/\(.metadata.name): \([.status.containerStatuses[].restartCount] | add)"'
```

Bare pods — these block a node drain during an upgrade:

```bash
kubectl get pods -A -o json | jq -r '.items[]
  | select(.metadata.ownerReferences == null)
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

---

## RBAC

```bash
kubectl auth can-i --list -n erp
kubectl auth can-i create deployments -n erp
kubectl auth can-i get secrets -n erp
kubectl auth can-i create pods/exec -n erp

# As someone else (needs impersonate permission)
kubectl auth can-i get secrets -n erp --as-group="<entra-group-object-id>"
kubectl auth can-i '*' '*' --as-group="<oid>"

kubectl -n erp get role,rolebinding
kubectl -n erp describe rolebinding erp-developers
kubectl get clusterrole,clusterrolebinding | grep erp

# What does this ClusterRole allow?
kubectl describe clusterrole view | head -40
```

> `pods/exec` is effectively root on the pod: it lets you read every
> environment variable and mounted secret, bypassing a `secrets` denial. Our
> developer Role grants `pods/log` and `pods/portforward` but not `pods/exec`.

---

## Networking

```bash
kubectl -n erp get svc,endpoints
kubectl -n erp get endpoints erp-api          # EMPTY means no Ready pods
kubectl -n erp get ingress
kubectl -n erp describe ingress erp

kubectl -n erp get networkpolicy
kubectl -n erp describe networkpolicy default-deny-all

# Surprise public IPs
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

---

## Security posture checks

Is anything running as root?

```bash
kubectl get pods -A -o json | jq -r '.items[]
  | select(.spec.securityContext.runAsNonRoot != true)
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

Anything privileged?

```bash
kubectl get pods -A -o json | jq -r '.items[]
  | select(.spec.containers[]?.securityContext?.privileged == true)
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

hostPath mounts (a container-escape path)?

```bash
kubectl get pods -A -o json | jq -r '.items[]
  | select(.spec.volumes[]?.hostPath != null)
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

Containers with no resource limits?

```bash
kubectl get pods -A -o json | jq -r '.items[] | .metadata as $m
  | .spec.containers[] | select(.resources.limits == null)
  | "\($m.namespace)/\($m.name): \(.name)"'
```

Pod Security Standard enforcement per namespace, and Gatekeeper:

```bash
kubectl get ns -o custom-columns='NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'

kubectl get constrainttemplates
kubectl get constraints
kubectl get pods -n gatekeeper-system
```

---

## Workload identity verification

```bash
# The LABEL goes on the POD
kubectl -n erp get pod <pod> -o jsonpath='{.metadata.labels}' | jq
# must contain "azure.workload.identity/use": "true"

# The ANNOTATION goes on the SERVICE ACCOUNT
kubectl -n erp get sa erp-api-sa -o jsonpath='{.metadata.annotations}' | jq

# The webhook injected these
kubectl -n erp exec deploy/erp-api -- env | grep AZURE_

# The projected token exists
kubectl -n erp exec deploy/erp-api -- \
  wc -c < /var/run/secrets/azure/tokens/azure-identity-token

# And it actually works end to end
kubectl -n erp exec deploy/erp-api -- python -c "
from azure.identity import DefaultAzureCredential
print(DefaultAzureCredential().get_token('https://vault.azure.net/.default').expires_on)"
```

---

## Jobs and CronJobs

```bash
kubectl -n erp get cronjobs
kubectl -n erp get jobs
kubectl -n erp create job --from=cronjob/erp-worker worker-manual-1
kubectl -n erp logs job/worker-manual-1
kubectl -n erp delete job worker-manual-1

kubectl -n erp patch cronjob erp-worker -p '{"spec":{"suspend":true}}'   # pause
kubectl -n erp patch cronjob erp-worker -p '{"spec":{"suspend":false}}'
```

---

## Helm

```bash
helm -n erp list
helm -n erp status erp
helm -n erp history erp
helm -n erp get values erp
helm -n erp get values erp --all        # includes chart defaults
helm -n erp get manifest erp            # what is actually deployed

helm lint k8s/helm/erp -f k8s/helm/erp/values-dev.yaml
helm template erp k8s/helm/erp -f k8s/helm/erp/values-prod.yaml | less

helm upgrade --install erp k8s/helm/erp -n erp --create-namespace \
  -f k8s/helm/erp/values-dev.yaml --atomic --wait --timeout 10m

helm -n erp rollback erp 3
helm -n erp uninstall erp --wait

# See the diff before you apply (install the plugin once)
helm plugin install https://github.com/databus23/helm-diff
helm -n erp diff upgrade erp k8s/helm/erp -f k8s/helm/erp/values-dev.yaml
```

> `--atomic --wait` is not optional. Without them Helm reports success as soon
> as the API server accepts the manifests, even if every pod then crash-loops.

---

## Cleanup

```bash
kubectl -n erp delete pod <pod>                        # it will be recreated
kubectl -n erp delete pod --field-selector=status.phase==Succeeded
kubectl -n erp delete pod --field-selector=status.phase==Failed

# A namespace stuck Terminating is almost always a finalizer
kubectl get ns erp -o json | jq '.spec.finalizers'
kubectl -n erp get all
```

---

## Aliases worth having

Add to `~/.bashrc`:

```bash
alias k='kubectl'
alias kn='kubectl -n erp'
alias kgp='kubectl -n erp get pods -o wide'
alias kgpw='kubectl -n erp get pods -w'
alias kl='kubectl -n erp logs --tail=100'
alias klf='kubectl -n erp logs -f --tail=50'
alias kd='kubectl -n erp describe'
alias kev='kubectl -n erp get events --sort-by=.lastTimestamp | tail -25'
alias kctx='kubectl config get-contexts'

# Tab completion
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
```
