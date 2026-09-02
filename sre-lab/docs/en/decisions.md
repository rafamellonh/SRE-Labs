# Technical decisions

A record of *why* each choice was made. Useful for picking the lab back up after
weeks away, and for explaining the design in an interview.

---

## Splitting VMs across the two hosts

**Decision:** workers and observability on `pc-01` (32 GB); control plane,
automation, and Zabbix on `pc-02` (16 GB).

**Rationale:** the bigger host carries the heavy workloads. But the central
point is different — **the two monitoring stacks live on separate physical
hosts**. When `pc-01` gets shut down during a chaos experiment, Zabbix on
`pc-02` stays alive and reports the outage. It solves "who watches the watcher"
in the topology rather than in theory.

---

## External vSwitch instead of Internal

**Decision:** bridged to the home LAN.

**Rationale:** VMs on both hosts see each other natively and have internet
access, with no router VM in between. The cost is consuming IPs from the home
LAN — hence the need to exclude `.151–.157` and `.200–.220` from the router's
DHCP range.

---

## Calico instead of Flannel

**Decision:** Calico v3.28.0.

**Rationale:** it supports NetworkPolicy, which is CKA material and yields real
SRE exercises (isolating namespaces, measuring blast radius). Flannel is lighter
and comes up faster, but doesn't do NetworkPolicy. Swapping CNIs later requires
`kubeadm reset` and rebuilding the cluster, so the choice had to be made
upfront.

---

## MetalLB + Ingress instead of NodePort

**Decision:** MetalLB in L2 mode + ingress-nginx.

**Rationale:** NodePort would work in a lab, but it doesn't exercise what you
find in production. MetalLB + Ingress lets you practice host-based routing, TLS
termination, and the one-IP-many-services model. Chaos bonus: you can take down
the node currently advertising the IP and measure how long another takes to pick
up the advertisement.

**Division of responsibility:** MetalLB operates at L2/L3 — it hands out the IP
and advertises it via gratuitous ARP. Ingress-nginx operates at L7 — it reads
the `Host:` header and decides the destination. Ingress-nginx is itself a
`Service type: LoadBalancer`, i.e. a MetalLB client. That's why install order
matters.

---

## MetalLB pool at `.200–.220`

**Decision:** pool kept well away from the VM range.

**Rationale:** the original intent was `192.168.2.15X`, but that range only has
10 addresses and the 7 VMs consume nearly all of them. MetalLB needs a
contiguous free range.

---

## local-path-provisioner as StorageClass

**Decision:** local-path-provisioner v0.0.30 as the default StorageClass.

**Rationale:** kubeadm ships no provisioner. Without a StorageClass, Prometheus'
30Gi PVC would sit `Pending` forever. The alternative — dropping `storageSpec`
and using `emptyDir` — loses all metrics on every pod restart, which is exactly
what breaks the chaos experiments.

---

## CentOS Stream 9 on `ansible-ctl`

**Decision:** CentOS Stream 9, over RHEL 9 or Rocky/Alma.

**Rationale:** it's the only non-Ubuntu VM, deliberately — it's where you
practice `dnf`, `firewalld`, SELinux, `nmcli`, and system roles, the Red Hat
ecosystem that shows up on EX294, without mixing it into the cluster nodes.

**Conscious trade-off:** Stream is *upstream* of RHEL and gets changes first.
Rocky and Alma are downstream and therefore 1:1 with RHEL, technically a closer
match for certification study. Stream was chosen out of interest in the CentOS
community and in how RHEL gets built. In practice the difference is minimal:
occasionally a package will be ahead of the RHEL 9 version.

---

## Zabbix **and** Prometheus, not one or the other

**Decision:** keep both, in distinct layers.

**Rationale:** they solve different problems and the job market asks for both.

| | Zabbix | Prometheus |
|---|---|---|
| Layer | Classic infra: hosts, OS, network, SNMP, appliances, databases | Cloud-native: k8s, pods, applications |
| Model | Agent-based push/pull, relational DB | Pull, time series, service discovery |
| Where it dominates | LATAM, telecom, MSPs, on-prem/hybrid | Kubernetes, cloud environments |

Grafana consumes both as datasources in a single pane. Knowing both is a
relatively uncommon combination.

---

## Autoregistration instead of manual host creation in Zabbix

**Decision:** an autoregistration action with no conditions.

**Rationale:** registering 6 hosts by hand is repetitive and teaches nothing
beyond the form layout. Autoregistration is what you use once the fleet grows.
Conditions were left empty because the lab is homogeneous — in a real fleet
you'd write something like "Host name contains `k8s-`" to link different
templates per machine type.

The name each host registers under comes from
`Hostname={{ inventory_hostname }}` in the agent's Jinja template — which is why
using the Ansible variable there paid off.

---

## Password-based Ansible authentication (temporary)

**Decision:** `--ask-pass --ask-become-pass` + `sshpass`, key migration deferred.

**Rationale:** it unblocked the work without stopping to set up keys. But it's
conscious technical debt: EX294 assumes key-based auth, and typing a password on
every playbook run gets old. Pending migration:

```bash
ssh-keygen -t ed25519
for ip in 151 152 153 154 155 157; do ssh-copy-id rafael@192.168.2.$ip; done
```

---

## `obs-01` and `svc-01` outside the cluster

**Current state:** both provisioned with a Zabbix agent, but carrying no
workload.

The original plan had them hosting the observability stack and the demo
application respectively. Since `kube-prometheus-stack` runs inside Kubernetes,
its pods landed on the workers and `obs-01` ended up idle.

**Two possible paths:**

- **A** — leave as is; `obs-01` becomes a standalone Loki host or something else.
- **B** — join `obs-01` to the cluster as a dedicated worker, with a taint and
  nodeSelector forcing the monitoring stack to run only there. That isolates
  observability from application load, which is how it's done in production, and
  uses the 8 GB that were sized for exactly this.

Option B is closer to the real world. Decision pending.

---

## Using `--check --diff` before applying playbooks

**Decision:** dry run as a habit.

**Rationale:** it validates the change before applying and shows exactly what
would be written. It's production practice and shows up on EX294. It's how it
became visible, for instance, that the playbook would correct the
`Server=127.0.0.1` that had been hand-configured on `zbx-01` — Ansible
converging to the declared state regardless of how the host got there.
