# 03 — Hub-spoke networking, NSGs, private endpoints, firewall

**Time:** 4 hours · **Cost:** ~₹0 with the firewall off; ~₹100/hour with it on
**Prerequisite:** chapter 02, `terraform apply` succeeded

Networking is where most candidates get exposed, because you cannot bluff it.
The questions are concrete: *what CIDR did you use and why, what happens to a
packet from a pod to the internet, why is there no public IP on the database.*
This chapter makes those answerable from memory.

---

## 1. The IP plan — decide this before anything else

Subnets **cannot be resized while resources are in them**. An AKS subnet that
is too small is a cluster rebuild. So the plan comes first.

```
Corporate space:        10.0.0.0/8      (reserved, never route it elsewhere)

HUB   10.0.0.0/16       shared services, one per region
  AzureFirewallSubnet   10.0.0.0/26     (/26 minimum, Azure requires it)
  AzureBastionSubnet    10.0.0.64/26    (/26 minimum, Azure requires it)
  snet-shared-services  10.0.2.0/24     jump hosts, DNS forwarders
  (10.0.3.0 - 10.0.255.255 free for future shared services)

SPOKE 10.10.0.0/16      one /16 per workload, ERP gets this one
  snet-aks-system       10.10.0.0/22    1022 usable - system node pool
  snet-aks-user         10.10.4.0/22    1022 usable - application node pool
  snet-appgw            10.10.16.0/24   Application Gateway (needs its own)
  snet-private-endpoints 10.10.17.0/24  PEs for ACR, KV, Blob, Cosmos
  snet-postgres         10.10.19.0/24   delegated to Flexible Server
  (10.10.20.0 - 10.10.255.255 free)

Kubernetes internal (NOT routable, must not overlap the VNet):
  service CIDR          172.16.0.0/16   ClusterIP addresses
  DNS service IP        172.16.0.10     must be inside the service CIDR
  pod CIDR              172.17.0.0/16   only with CNI Overlay
```

### How to size an AKS subnet — the actual arithmetic

With **Azure CNI (non-overlay)**, every pod takes a real VNet IP:

```
IPs needed = max_nodes × (max_pods_per_node + 1)
           = 10 nodes × (50 + 1)
           = 510   →  a /23 (510 usable) is already tight; use /22
```

With **Azure CNI Overlay** (what we use), pods get addresses from the pod
CIDR, so the subnet only needs one IP per node:

```
IPs needed = max_nodes + 1   →  a /27 would do
```

We still use /22 because subnets are free and resizing is not. **That is the
answer to "how did you size it": you size for the maximum node count you will
ever scale to, not the current one, because the cost of being wrong is
asymmetric.**

Azure also reserves **5 addresses per subnet** (network, broadcast, and three
for the platform), so a /24 gives you 251 usable, not 256. Knowing this is a
small but reliable credibility signal.

### Why Overlay here

| | CNI (non-overlay) | **CNI Overlay** | kubenet (legacy) |
|---|---|---|---|
| Pod gets a VNet IP | yes | no, from pod CIDR | no |
| VNet IPs consumed | huge | one per node | one per node |
| Pod directly reachable from VNet | yes | no (via node SNAT) | no |
| NSG applies to pod traffic | yes | at node level | at node level |
| Max pods per cluster | limited by subnet | ~1M | limited |
| Windows node support | yes | yes | no |

**The decision:** Overlay, because IP exhaustion is the most common
irreversible AKS mistake and Overlay removes the whole class of problem. The
trade-off is that a pod is not independently addressable from the VNet, which
matters only if something outside the cluster needs to dial a pod directly —
and nothing in this architecture does.

---

## 2. Why hub-spoke at all

```
   spoke-erp ──┐
   spoke-crm ──┼──► HUB ──► Firewall ──► Internet
   spoke-hr  ──┘        └──► ExpressRoute/VPN ──► on-prem
```

The point is **shared services are shared once**. One firewall, one Bastion,
one set of DNS forwarders, one ExpressRoute circuit — not one per workload.
And the spokes are isolated from each other: peering is non-transitive, so
`spoke-erp` cannot reach `spoke-hr` unless you deliberately route it through
the hub.

Three facts about peering that come up:

1. **Peering is not transitive.** A↔B and B↔C does not give A↔C. To get it you
   need either a UDR through an NVA in the hub, or Azure Virtual WAN.
2. **Peering must be created on both sides.** One-sided peering sits in
   `Initiated` state and passes no traffic. Terraform creates both
   (`hub_to_spoke` and `spoke_to_hub`).
3. **Address spaces must not overlap.** Peering fails outright. This is why
   the /16-per-spoke allocation is written down before anyone builds.

---

## 3. Build it

Already done by chapter 02's apply. Inspect what you got:

```bash
cd infra/terraform/envs/dev
source ~/.erp-lab-env
RG_NET=$(terraform output -json resource_groups | jq -r .network)

# VNets and their address spaces
az network vnet list -g "$RG_NET" \
  --query '[].{name:name, cidr:addressSpace.addressPrefixes[0]}' -o table

# Every subnet, with its NSG and delegation
az network vnet subnet list -g "$RG_NET" --vnet-name "vnet-spoke-erp-dev-cin" \
  --query '[].{name:name, cidr:addressPrefix, nsg:networkSecurityGroup.id, deleg:delegations[0].serviceName}' \
  -o table

# Peering state - BOTH sides must say "Connected"
az network vnet peering list -g "$RG_NET" --vnet-name "vnet-hub-dev-cin" \
  --query '[].{name:name, state:peeringState, sync:peeringSyncLevel}' -o table
az network vnet peering list -g "$RG_NET" --vnet-name "vnet-spoke-erp-dev-cin" \
  --query '[].{name:name, state:peeringState, sync:peeringSyncLevel}' -o table
```

`peeringSyncLevel` should be `FullyInSync`. If it says
`RemoteNotInSync`, someone changed an address space after peering — fix with
`az network vnet peering sync`.

---

## 4. NSGs — the layer-4 firewall

Read [`infra/terraform/modules/network/nsg.tf`](../infra/terraform/modules/network/nsg.tf).

### The rules that matter

**Rule evaluation:** lowest priority number wins, first match stops
evaluation. Azure has implicit rules at 65000–65500:
`AllowVnetInBound`, `AllowAzureLoadBalancerInBound`, `DenyAllInBound`.

We write an **explicit** `Deny-All-Inbound` at 4096 anyway. Why, when 65500
already denies? Three reasons, and this is a genuinely good interview answer:

1. **Intent is reviewable.** A reader sees the deny without knowing Azure's
   defaults.
2. **It is above the implicit allows.** `AllowVnetInBound` sits at 65000; our
   4096 deny takes precedence over it, so we are *not* implicitly trusting
   the whole VNet.
3. **Compliance scanners check for it.** CIS and several Azure Policy
   definitions look for an explicit deny.

### The one rule you must never get wrong

```hcl
resource "azurerm_network_security_rule" "appgw_gwm" {
  name                       = "Allow-GatewayManager-Inbound"
  priority                   = 100
  source_address_prefix      = "GatewayManager"   # a service tag
  destination_port_range     = "65200-65535"
}
```

Application Gateway v2 **will not work** without this. The health of the
gateway's own infrastructure is managed over those ports from the
`GatewayManager` service tag. The failure mode is cruel: the gateway deploys
successfully, then reports all backends unhealthy with no useful error.

**Service tags** (`GatewayManager`, `AzureLoadBalancer`, `Internet`,
`VirtualNetwork`, `AzureCloud.centralindia`, `Storage.centralindia`) are
Microsoft-maintained IP groups. Using a tag instead of an IP range is the
right answer every time — Microsoft updates the ranges, you do not.

```bash
# See what is actually behind a tag
az network list-service-tags --location centralindia \
  --query "values[?name=='AzureKubernetesService'].properties.addressPrefixes[0:5]" -o tsv
```

### Verify your NSGs

```bash
RG_NET=$(terraform output -json resource_groups | jq -r .network)

az network nsg list -g "$RG_NET" --query '[].name' -o tsv

az network nsg rule list -g "$RG_NET" --nsg-name "nsg-aks-erp-dev-cin" \
  --query "sort_by([].{p:priority, name:name, dir:direction, access:access, src:sourceAddressPrefix, ports:destinationPortRange}, &p)" \
  -o table
```

### The debugging tool nobody uses

```bash
# Will this packet actually get through? Ask Azure, do not guess.
az network watcher test-ip-flow \
  --resource-group "$RG_AKS" \
  --vm "<a node vm name>" \
  --direction Inbound \
  --protocol TCP \
  --local 10.10.4.5:8000 \
  --remote 10.10.16.4:50000
```

It returns `Allow`/`Deny` **and the name of the rule that decided**. That is
the single fastest way to settle an NSG argument, and mentioning
`test-ip-flow` in an interview immediately separates you from people who
debug connectivity by deleting rules.

---

## 5. Private endpoints and private DNS — the part people get wrong

### The problem

By default, `psql-erp-dev-cin-01.postgres.database.azure.com` resolves to a
**public IP**. Your pod would reach the database over the internet, through
the service's own firewall. That is not acceptable for an ERP database.

### The mechanism

A **private endpoint** is a NIC in your subnet with a private IP, mapped to a
specific PaaS resource. The resource becomes reachable at that private IP.

But a private IP is useless if DNS still hands out the public one. That is
where the **private DNS zone** comes in:

```
Pod asks for:  psql-erp-dev-cin-01.postgres.database.azure.com
                              │
            ┌─────────────────▼──────────────────┐
            │ Is there a private DNS zone named  │
            │ privatelink.postgres.database...   │
            │ LINKED TO THIS VNET?               │
            └──────┬──────────────────────┬──────┘
                 yes                      no
                   │                      │
          returns 10.10.19.4      returns the public IP
          (the private endpoint)   (and your traffic leaves the VNet)
```

**Three things must all be true.** Miss any one and you silently get the
public IP:

1. the private endpoint exists
2. the private DNS zone exists **with the exact right name**
3. the zone is **linked to the VNet doing the asking**

Number 3 is the one that gets missed. The zone exists, the A record is in it,
and nothing resolves — because no VNet link.

### The exact zone names (get these wrong and nothing works)

| Service | Private DNS zone |
|---|---|
| PostgreSQL Flexible Server | `privatelink.postgres.database.azure.com` |
| Key Vault | `privatelink.vaultcore.azure.net` |
| Container Registry | `privatelink.azurecr.io` |
| Blob Storage | `privatelink.blob.core.windows.net` |
| Cosmos DB (SQL API) | `privatelink.documents.azure.com` |
| Service Bus | `privatelink.servicebus.windows.net` |
| AKS private cluster | `privatelink.<region>.azmk8s.io` |

Note Key Vault: the public name is `vault.azure.net` but the private zone is
`vaultcore.azure.net`. That inconsistency is a classic trap.

### Verify resolution from inside the cluster

This is the real test — not `nslookup` from your laptop.

```bash
kubectl run dnstest --rm -it --restart=Never --image=nicolaka/netshoot -- \
  sh -c '
    echo "--- PostgreSQL ---"
    nslookup psql-erp-dev-cin-01.postgres.database.azure.com
    echo "--- Key Vault ---"
    nslookup kv-erp-dev-a1b2c3.vault.azure.net
    echo "--- ACR ---"
    nslookup acrerpdeva1b2c3.azurecr.io
  '
```

A correct result looks like:

```
Name:   psql-erp-dev-cin-01.privatelink.postgres.database.azure.com
Address: 10.10.19.4          ← private. Correct.
```

A wrong result gives you a `20.x` or `4.x` address — a public IP. Then check,
in order: does the zone exist, is it linked to the spoke VNet, does the
private endpoint have a DNS zone group.

```bash
RG_NET=$(terraform output -json resource_groups | jq -r .network)

# All zones
az network private-dns zone list -g "$RG_NET" --query '[].name' -o tsv

# Is it linked to the VNet? (the step people forget)
az network private-dns link vnet list -g "$RG_NET" \
  --zone-name "privatelink.postgres.database.azure.com" \
  --query '[].{name:name, vnet:virtualNetwork.id, state:provisioningState}' -o table

# What A records are registered?
az network private-dns record-set a list -g "$RG_NET" \
  --zone-name "privatelink.postgres.database.azure.com" \
  --query '[].{name:name, ip:aRecords[0].ipv4Address}' -o table
```

### VNet injection vs private endpoint — know the difference

PostgreSQL Flexible Server offers two private models, and they are not the
same thing:

| | **VNet injection** (what we use) | Private endpoint |
|---|---|---|
| Where the server lives | *inside* your delegated subnet | in Microsoft's network |
| Needs a delegated subnet | yes (`Microsoft.DBforPostgreSQL/flexibleServers`) | no |
| Public endpoint | none at all | exists but can be disabled |
| Can you change later | **no** — it is chosen at creation | yes |
| Cross-region/peering reach | needs peering + DNS | simpler |

We chose injection because "there is no public endpoint to misconfigure" is a
stronger posture than "the public endpoint is disabled". The cost is that it
is **irreversible** — you cannot convert an injected server to a
private-endpoint one, you have to recreate it. Being able to state that
trade-off, including the irreversibility, is a strong answer.

---

## 6. Exercise: Azure Firewall and forced egress

> **COST WARNING.** Azure Firewall Basic is roughly **₹100/hour** (~USD 1.20).
> Do this exercise in one sitting, then turn it off. Set a timer.

### Why force egress through a firewall

Default AKS egress is a load balancer doing SNAT — a pod can reach anything on
the internet. For an ERP system holding financial data, that is a data
exfiltration path. Forced tunnelling plus an FQDN allow-list means a
compromised pod cannot phone home.

### Turn it on

```bash
cd infra/terraform/envs/dev

terraform apply \
  -var enable_firewall=true \
  -auto-approve
```

That creates the firewall, the policy with the AKS allow-list, a route table
with `0.0.0.0/0 → firewall private IP`, and associates it with both AKS
subnets.

**You must also switch the cluster's outbound type**, which is a
*recreate* operation on AKS — so for the exercise, just observe the route
table rather than rebuilding the cluster:

```bash
RG_NET=$(terraform output -json resource_groups | jq -r .network)

az network route-table route list -g "$RG_NET" \
  --route-table-name "rt-spoke-egress-dev" \
  --query '[].{name:name, prefix:addressPrefix, hop:nextHopType, ip:nextHopIpAddress}' -o table
```

### The AKS egress allow-list — know roughly what is on it

This is a favourite question. AKS needs these to function at all:

| Destination | Why |
|---|---|
| `*.hcp.<region>.azmk8s.io` :443 | the API server (tunnel from kubelet) |
| `mcr.microsoft.com`, `*.data.mcr.microsoft.com` :443 | system container images |
| `management.azure.com` :443 | cluster operations |
| `login.microsoftonline.com` :443 | Entra ID auth |
| `packages.microsoft.com` :443 | OS packages |
| `acs-mirror.azureedge.net` :443 | kubenet/CNI binaries |
| `*.azurecr.io` + `*.blob.core.windows.net` :443 | **your** images |
| `*.ods.opinsights.azure.com`, `*.oms.opinsights.azure.com` :443 | Log Analytics agent |
| `*.monitor.azure.com` :443 | metrics |
| UDP 123 | NTP — **clock skew breaks TLS and Entra tokens** |
| UDP/TCP 53 | DNS |

The practical answer is: **use the `AzureKubernetesService` FQDN tag**, which
Microsoft maintains, instead of hand-maintaining the list. See
`destination_fqdn_tags = ["AzureKubernetesService"]` in
[`modules/firewall/main.tf`](../infra/terraform/modules/firewall/main.tf).

Two sharp edges worth naming:

- **Application rules need DNS proxy enabled** on the firewall policy,
  otherwise FQDN filtering cannot work — the firewall must resolve the name
  itself to correlate it with the IP.
- **Asymmetric routing kills the load balancer.** If you force
  `0.0.0.0/0` to the firewall on a subnet that also has an inbound public load
  balancer, return traffic goes out the firewall instead of back the way it
  came, and connections hang. The fix is a more specific UDR for the load
  balancer's own prefix, or `outbound_type = userDefinedRouting` with an
  internal-only load balancer. This exact problem is a great "something that
  went wrong" story.

### TURN IT OFF

```bash
terraform apply -var enable_firewall=false -auto-approve
./scripts/cost-check.sh     # confirm the firewall is gone
```

---

## 7. Exercise: Application Gateway WAF

> **COST:** ~₹20/hour. Cheaper than the firewall; still turn it off after.

```bash
terraform apply -var enable_appgw=true -auto-approve
terraform output appgw_fqdn
```

### Test the WAF actually blocks

```bash
FQDN=$(terraform output -raw appgw_fqdn)

# 1. Normal request - should succeed (or 502 if no backend yet, that is fine)
curl -sI "http://${FQDN}/"

# 2. SQL injection attempt - WAF should return 403
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://${FQDN}/api/v1/products?category=1'%20OR%20'1'='1"

# 3. Path traversal - 403
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://${FQDN}/../../etc/passwd"

# 4. XSS in a query string - 403
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://${FQDN}/?q=<script>alert(1)</script>"

# 5. The custom rule: /docs must be blocked from the internet
curl -s -o /dev/null -w "%{http_code}\n" "http://${FQDN}/docs"
```

### See what the WAF did

```bash
LAW_ID=$(terraform output -raw log_analytics_workspace_id)

az monitor log-analytics query \
  --workspace "$(az monitor log-analytics workspace show --ids "$LAW_ID" --query customerId -o tsv)" \
  --analytics-query '
    AzureDiagnostics
    | where Category == "ApplicationGatewayFirewallLog"
    | project TimeGenerated, action_s, ruleId_s, Message, requestUri_s, clientIp_s
    | order by TimeGenerated desc
    | take 20' \
  -o table
```

### Tuning false positives — the real skill

A WAF in Prevention mode **will** block legitimate traffic. The ERP posts JSON
with decimal strings and long free-text product descriptions, which trips
`942430` (restricted SQL character anomaly).

The remediation ladder, best to worst:

1. **Fix the application** if the request really is malformed
2. **Exclusion** scoped to one field (`RequestArgNames`, selector
   `unit_price`) — surgical
3. **Rule override** to `Log` for one rule id — narrow
4. Disable the whole **rule group** — rarely justifiable
5. Switch the policy to Detection mode — you no longer have a WAF

See the `rule_group_override` and `exclusion` blocks in
[`modules/appgw/main.tf`](../infra/terraform/modules/appgw/main.tf).

**The interview answer:** *"I never disable a rule group. I find the specific
rule id in the firewall log, then write the narrowest possible exclusion —
usually a single request-arg name. And I put the WAF in Detection mode for a
week before Prevention on a new app, so I tune against real traffic instead of
guessing."*

### TURN IT OFF

```bash
terraform apply -var enable_appgw=false -auto-approve
```

---

## 8. Break it on purpose

**Exercise A — break DNS resolution for a private endpoint**

```bash
RG_NET=$(cd infra/terraform/envs/dev && terraform output -json resource_groups | jq -r .network)

# Delete the VNet link (not the zone - the link)
az network private-dns link vnet delete -g "$RG_NET" \
  --zone-name "privatelink.postgres.database.azure.com" \
  --name "link-spoke-postgres" --yes

# Now resolve from a pod
kubectl run dnstest --rm -it --restart=Never --image=nicolaka/netshoot -- \
  nslookup psql-erp-dev-cin-01.postgres.database.azure.com
```

You now get a **public IP**, and the API pod's readiness probe starts failing
with a connection timeout. This is *the* private-endpoint failure mode.
Restore it:

```bash
cd infra/terraform/envs/dev && terraform apply -auto-approve
```

**Exercise B — overlapping CIDR**

```bash
# Try to peer two VNets with overlapping space
az network vnet create -g "$RG_NET" -n vnet-overlap-test \
  --address-prefix 10.10.0.0/16 --only-show-errors

az network vnet peering create -g "$RG_NET" \
  --vnet-name vnet-spoke-erp-dev-cin \
  --name peer-to-overlap \
  --remote-vnet vnet-overlap-test \
  --allow-vnet-access
```

Fails with an address-space conflict. Clean up:

```bash
az network vnet delete -g "$RG_NET" -n vnet-overlap-test
```

**Exercise C — the NSG that blocks your own health probe**

```bash
# Add a deny that catches the AzureLoadBalancer tag
az network nsg rule create -g "$RG_NET" --nsg-name nsg-aks-erp-dev-cin \
  --name Deny-Probes-Oops --priority 90 \
  --direction Inbound --access Deny --protocol '*' \
  --source-address-prefixes AzureLoadBalancer \
  --destination-port-ranges '*'
```

Within a minute the load balancer marks your nodes unhealthy and traffic
stops. The lesson: a deny rule at a *lower priority number* than your allows
wins, and `AzureLoadBalancer` is not optional. Remove it:

```bash
az network nsg rule delete -g "$RG_NET" --nsg-name nsg-aks-erp-dev-cin --name Deny-Probes-Oops
```

---

## 9. Interview answers this chapter gives you

**"Trace a request from a user's browser to the database."**

> The user hits the public IP of the Application Gateway. TLS terminates
> there, and the WAF evaluates the request against the OWASP 3.2 core rule set
> plus our custom rules — rate limiting per client IP and a block on
> `/docs` and `/metrics` from the internet. If it passes, the gateway forwards
> over HTTP to the AKS ingress controller in the spoke VNet; the NSG on the
> AKS subnet only permits that traffic from the gateway's subnet prefix.
> Ingress routes to the `erp-web` Service, a ClusterIP, which load balances to
> a web pod. The browser never talks to the API: the web tier is a BFF, so it
> calls `erp-api` server-side over ClusterIP on port 8000 — and the Calico
> NetworkPolicy only allows that one flow, because the namespace is
> default-deny. The API then connects to PostgreSQL on 5432. The hostname
> resolves through a private DNS zone linked to the spoke VNet, so it returns
> a private IP in the delegated subnet — the server has no public endpoint at
> all. Authentication is an Entra ID token the pod obtained through workload
> identity, so there is no password anywhere in the path.

**"How did you decide the CIDR ranges?"**

> I allocated a /16 per spoke from a documented corporate range so peering
> can never collide, and a separate /16 for the hub. Within the spoke, the AKS
> node subnets are /22 each — sized for the maximum node count we would ever
> scale to, not the current one, because you cannot resize a subnet while
> resources are in it. We use CNI Overlay so pods come from a non-routable
> 172.17/16 rather than consuming VNet space, which removes IP exhaustion as a
> failure mode entirely. The service CIDR is 172.16/16, deliberately outside
> the VNet space so it cannot clash with anything routable. And I left most of
> each /16 unallocated, because the thing you always need later is another
> subnet.

**"What is the difference between an NSG and Azure Firewall?"**

> Different layers and different jobs. An NSG is a stateful layer-3/4 ACL
> attached to a subnet or NIC — free, distributed, enforced in the host, and it
> filters on IP, port, protocol and service tag. Azure Firewall is a managed
> layer-7 NVA: it does FQDN filtering, TLS inspection on Premium, threat
> intelligence, IDPS, and it gives you centralised egress logging. It costs
> real money. The practical split is: NSGs for east-west segmentation inside
> the VNet, firewall for north-south egress control. For an ERP platform I
> would run both — NSGs because they are free and the segmentation is
> valuable, and the firewall because "which external domains did this cluster
> talk to" is a question you cannot answer with NSG flow logs alone.

**"A pod cannot reach the database. Walk me through your debugging."**

> I work outward from the pod. First, is it DNS or connectivity — `nslookup`
> from a netshoot pod in the same namespace. If DNS returns a public IP, the
> problem is the private DNS zone or, far more often, its VNet link, and I
> check the link before anything else. If DNS is right but the connection
> hangs, I test the port — `nc -zv <ip> 5432` — and if that fails I use
> `az network watcher test-ip-flow`, which tells me Allow or Deny *and the
> rule name*, so I am not guessing at NSGs. If the TCP connection succeeds but
> authentication fails, it is not networking at all: either the managed
> identity has no PostgreSQL principal — `pgaadauth_create_principal` is the
> step everyone forgets — or `ERP_DB_USER` is still the admin name instead of
> the identity name. Throughout, `kubectl logs` on the pod and
> `PostgreSQLLogs` in Log Analytics tell you which side rejected you.

---

## Checklist

- [ ] You can draw the hub-spoke with CIDRs from memory
- [ ] You can explain the AKS subnet sizing arithmetic, both CNI modes
- [ ] Peering shows `Connected` + `FullyInSync` on **both** sides
- [ ] You know why `AzureFirewallSubnet` must be named exactly that
- [ ] You know the `GatewayManager` 65200-65535 rule and what breaks without it
- [ ] You resolved all private endpoints **from inside a pod** and saw private IPs
- [ ] You can name the 3 conditions for private DNS to work, and which is forgotten
- [ ] You can state the VNet-injection vs private-endpoint trade-off
- [ ] Firewall exercise done **and turned off**
- [ ] WAF exercise done, you saw a 403, you read the firewall log, **and turned off**
- [ ] You used `az network watcher test-ip-flow` at least once
- [ ] All three "break it" exercises done and reverted
- [ ] `./scripts/cost-check.sh` shows no firewall and no app gateway

Next: [chapter 04 — Identity](04-identity.md)
