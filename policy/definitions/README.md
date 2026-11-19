# Custom Azure Policy definitions

| File | Effect (default) | What it stops |
|---|---|---|
| `require-mandatory-tags.json` | Deny | Untagged resources that break cost reporting |
| `allowed-regions-and-skus.json` | Deny | Wrong-region deployments and expensive VM sizes |
| `deny-public-ip-on-nic.json` | Deny | A NIC with a public IP bypassing AppGW/Firewall |
| `deny-public-network-access.json` | Audit (dev) / Deny (prod) | PaaS data services reachable from the internet |

## Why custom policies at all?

Most of what this platform needs already exists as a **built-in** policy or
initiative. Reach for built-ins first:

- `Kubernetes cluster pods should only use allowed capabilities`
- `Azure Kubernetes Service clusters should have Defender profile enabled`
- `Key Vault should use RBAC permission model`
- `Azure Policy Add-on for Kubernetes should be installed`

The four custom definitions here cover things no built-in expresses exactly:
the specific tag set this organisation bills on, the specific region/SKU
allow-list, and the "no public IP except on these three subnets" rule.

**Interview answer:** "I used built-in initiatives for the baseline -
specifically the CIS Kubernetes benchmark and the Microsoft cloud security
benchmark - and wrote four custom definitions only where the requirement was
organisation-specific. Writing a custom policy that duplicates a built-in is
maintenance debt."

## Gatekeeper / Pod Security

Pod-level enforcement comes from two layers, in this order:

1. **Pod Security Admission** (`k8s/base/namespace.yaml`) - the namespace is
   labelled `pod-security.kubernetes.io/enforce: restricted`. Free, built into
   the API server, no add-on. Blocks root, privileged, hostPath, hostNetwork.
2. **Azure Policy for Kubernetes** (Gatekeeper) - gives you *reporting* in the
   Azure portal plus rules PSA cannot express, such as "images must come from
   our ACR" and "every pod must set resource limits".

Assign the built-in initiative rather than hand-rolling Rego:

```bash
az policy assignment create \
  --name "erp-aks-baseline" \
  --display-name "ERP - Kubernetes cluster pod security restricted standards" \
  --policy-set-definition "42b8ef37-b724-4e24-bbc8-7a7708edfe00" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/rg-erp-dev-cin-aks" \
  --params '{"excludedNamespaces":{"value":["kube-system","gatekeeper-system","calico-system"]}}'
```

## Deploy these definitions

```bash
# At a management group (preferred - definitions are inherited by all subs)
MG=mg-contoso-platform
for f in definitions/*.json; do
  name=$(basename "$f" .json)
  az policy definition create \
    --name "erp-$name" \
    --management-group "$MG" \
    --rules  "$(jq -c .properties.policyRule   "$f")" \
    --params "$(jq -c .properties.parameters   "$f")" \
    --mode   "$(jq -r .properties.mode         "$f")" \
    --display-name "$(jq -r .properties.displayName "$f")" \
    --description  "$(jq -r .properties.description "$f")"
done
```

Then assign the initiative in `initiatives/erp-landing-zone-baseline.json`.

## Checking compliance

```bash
# Summary for the subscription
az policy state summarize --subscription "$SUB_ID" -o table

# Everything currently non-compliant, newest first
az policy state list \
  --filter "complianceState eq 'NonCompliant'" \
  --query "[].{res:resourceId, policy:policyDefinitionName}" -o table
```

A policy assignment can take **up to 30 minutes** to evaluate existing
resources. New deployments are evaluated immediately at the control plane,
which is why `Deny` works instantly but the compliance dashboard lags.
