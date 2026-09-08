# Design: Migrating the Bare-Metal k3s Cluster into KVM/libvirt VMs

Date: 2026-08-27
Status: Design + runbook scaffold. Two decisions are deliberately OPEN (see
[Open decisions](#open-decisions)); nothing below resolves them.

Related: `docs/plans/2026-07-23-homelab-vm-gold-master-design.md`,
`docs/runbooks/vm-provisioning.md`, `docs/runbooks/vm-disk-rebase.md`,
`packer/README.md`, `docs/plans/infrastructure-roadmap.md`,
`docs/decisions/0005-nodeport-lan-game-pattern.md`.

## Goal and definition of done

Today k3s runs on bare metal on the HP Z600 alongside libvirt. The end state is:

- the bare-metal k3s cluster is **torn down**, not left running in parallel;
- the Z600 is a **minimal hypervisor** -- libvirt, storage, backups, a
  monitoring agent, and little else;
- every workload runs inside VMs built from the Packer gold master pipeline in
  `packer/` and provisioned by `ansible/playbooks/vms.yml`.

**Lift and shift first.** A workload moves as-is: same chart, same values, same
data. Improvements (resource right-sizing beyond what capacity forces,
restructuring storage, splitting services) come after the migration completes,
as their own changes. Every "while we're in there" is a chance for the
migration to fail for a reason that has nothing to do with the migration.

Done means: no workload runs on the host's k3s; `virsh list` accounts for
everything; the acceptance suite passes against the VM cluster; and the host's
k3s install has been removed rather than merely stopped.

## Current topology

**Single node.** The k3s cluster is one server node (`home`) on the Z600. The
DigitalOcean cloud agent was retired months ago and its configuration was
removed from this repo (see the CHANGELOG entry dated 2026-08-27); nothing in
the tree claims a second node exists. `[k3s_agents]` in
`ansible/inventory/hosts.ini` is present and deliberately empty, reserved for
the VM nodes this document is about.

One VM already exists: `ubuntu-vm-01` (4 vCPU / 8GB / 40GB), declared in
`irl_vms` and unrelated to the cluster. It is not a k3s node.

### Access model, stated precisely

Two distinct paths, often conflated:

- **Internal access is Tailscale + Traefik + CoreDNS split DNS.** CoreDNS runs
  with `hostNetwork: true` and owns port 53 on the host; Tailscale split DNS
  points `*.lab.infiniteroomlabs.cloud` and
  `*.internal.lab.infiniteroomlabs.cloud` at it. Traefik also runs
  `hostNetwork: true`, binding 80/443 directly on the node. This is how the
  laptop reaches every service.
- **Cloudflare Tunnel + Access is NOT a general public path.** It is specific
  to two services: JobOps (`jops.infiniteroomlabs.com`) and gunio-mcp
  (`gunio-mcp.infiniteroomlabs.com`). Each has its own tunnel and its own
  Access application; each app's cloudflared sidecar dials the pod, not the
  cluster. No other service is publicly reachable, and the migration must not
  make one so by accident.
- **A third path exists for exactly two workloads**: LAN NodePorts for the
  game servers, per ADR-0005. The Steam Deck has no Tailscale and connects at
  `192.168.2.2:30777` / `:30211`, with symmetric NodePorts, nftables allowlist
  entries, and per-game NetworkPolicies. This path is the one most easily
  broken by a change in VM networking.

## Wave pattern

The host has no spare capacity to stand up a full parallel cluster, so the
migration proceeds in waves, each of which funds the next:

1. **Measure** the workloads in the wave (see below -- this is the step most
   likely to be done badly).
2. **Expand capacity into free headroom.** Prefer adding a NEW, right-sized VM
   per wave over growing an existing one: `vms.yml` does not resize. It asserts
   that an existing domain still matches its `irl_vms` declaration and fails on
   drift; changing `ram_gb`, `vcpus`, or `disk_gb` for a live VM is an error,
   not an operation.
3. **Migrate the wave** into the new VM node.
4. **Tear down the freed workloads** on the host, and reclaim their memory.
5. **The reclaimed RAM funds the next wave.** Raise `irl_vm_ram_budget_gb` by
   what was actually freed, not by what was hoped for.

`irl_vm_ram_budget_gb` gets rewritten once per wave. It is a hard assertion in
`vms.yml`, which is the point: a wave that has not actually freed memory cannot
provision the VM for the next one.

### Capacity math

| Quantity | Value | Source |
|---|---|---|
| Total host RAM | 40GB | `irl_total_ram_gb` |
| OS reserve | 4GB | `irl_reserved_ram_gb` |
| ZFS ARC cap | 8GB | `irl_zfs_arc_max_gb` |
| Declared VM RAM budget | 12GB | `irl_vm_ram_budget_gb` |
| Currently declared in `irl_vms` | 8GB (`ubuntu-vm-01`) | `host_vars/homelab.yml` |

That leaves **4GB of ADMINISTRATIVE headroom** inside the declared budget --
administrative because it is arithmetic over declarations, not a measurement.
Whether 4GB is actually free on the host is a question only the host can
answer, and it must be answered before the first wave.

### Measurement guidance

The tempting number is a 30-day `container_memory_working_set_bytes` per
workload from Prometheus. **That is ONE INPUT, not the capacity number.**

- Use a **peak or a high percentile**, not a mean. A mean over 30 days hides
  every burst that would OOM the new node.
- **Record the exact query, aggregation window, and timestamp** in the wave's
  cutover checklist. A number without its query is not reproducible and cannot
  be re-checked after the migration.
- Then **add reserves that the metric does not contain**: k3s and system pods
  on the new node, host daemons inside the guest, QEMU/virtio overhead outside
  the guest, and a burst safety factor.
- Sanity-check against the declared limits in `irl_mem_limits` and the chart
  values. A workload whose working set sits far below its limit is not
  necessarily safe to size at the working set.

## Repository-declared storage inventory

**This is declared state, not live state.** Every row is sourced from what this
repository declares; none of it has been checked against the running cluster.
The known divergence at the bottom of this section is the reason the
distinction matters.

Sources: PV declarations in `ansible/playbooks/k3s.yml`, inline PVC
declarations in `ansible/playbooks/helm-deploy.yml`, every
`ansible/helm/*/values.yaml`, `irl_zfs_datasets` in
`ansible/inventory/group_vars/all/main.yml`, and `ansible/files/sanoid/sanoid.conf`.

Backing classification: **dataset** = its own ZFS dataset; **subdir** = a
directory inside another dataset; **root** = under `/var/lib/...` on the root
filesystem, i.e. NOT on the ZFS pool; **dynamic** = provisioned by
`local-path`, which also lands under `/var/lib/rancher/k3s/storage`.

Snapshot policy is read from `sanoid.conf`. `[main]` is `recursive = no`, so a
dataset with no explicit child section is **NOT covered** by any snapshot
policy -- written below as `none`. `garage-data` and both paperless datasets
are the notable examples.

| Service | PV / PVC | StorageClass | Declared binding | Backing path | Class | Snapshots | Criticality | Restore procedure / evidence | Live binding verified | Wave | Storage decision |
|---|---|---|---|---|---|---|---|---|---|---|---|
| postgres (CNPG) | `pv-postgres-data` / CNPG cluster storage | `zfs-local` declared; **`local-path` actually requested** | chart values vs `helm-deploy.yml` override -- see divergence note | `/var/lib/rancher/k3s/storage/postgres-data` | root | none | critical | `ansible/docs/runbooks/backup-and-restore.md` -- tested? | | | |
| gitea | `pv-gitea-lfs` / `gitea-lfs-pvc` | `zfs-local` | label selector `app=gitea` | `main/gitea-lfs` | dataset | `service_data` | high | backup-and-restore.md -- tested? | | | |
| gitea (app) | chart PVC | `local-path` | dynamic | `/var/lib/rancher/k3s/storage` | dynamic | none | high | -- | | | |
| ollama | `pv-ollama-models` / `ollama-models-pvc` | `zfs-local` | label selector `app=ollama` | `main/ollama-models` | dataset | `large_assets` | low (redownloadable) | re-pull models | | | |
| prometheus | `pv-prometheus-data` / volumeClaimTemplate | `zfs-local` | label selector `app=prometheus` | `/var/lib/rancher/k3s/storage/prometheus-data` | root | none | medium | metrics are not restored today | | | |
| loki | `pv-loki-data` / `loki-data-pvc` | `zfs-local` | label selector `app=loki` | `main/logs/loki` | subdir of `main/logs` | `logs` (via parent dataset) | medium | -- | | | |
| grafana | `pv-grafana-data` / chart PVC | `zfs-local` | label selector `app=grafana` | `/var/lib/rancher/k3s/storage/grafana-data` | root | none | medium | dashboards are provisioned as code | | | |
| garage | `pv-garage-data` / `garage-data-pvc` | `zfs-local` | label selector `app=garage` | `main/garage-data` | dataset (1M recordsize) | **none** | high | backup-and-restore.md -- tested? | | | |
| garage (meta) | `pv-garage-meta` / `garage-meta-pvc` | `zfs-local` | label selector `app=garage` | `/var/lib/garage/meta` | root | none | high | -- | | | |
| openviking | `pv-openviking-data` / `openviking-data-pvc` | `zfs-local` | label selector `app=openviking` | `/var/lib/rancher/k3s/storage/openviking-data` | root | none | medium | -- | | | |
| vault | `pv-vault-data` / chart PVC | `zfs-local` PV; chart declares `local-path` | mismatch to confirm live | `/var/lib/rancher/k3s/storage/vault-data` | root | none | critical | unseal keys in Bitwarden; data restore -- tested? | | | |
| jenkins | `pv-jenkins-data` / chart PVC | `zfs-local` | label selector `app=jenkins` | `/var/lib/rancher/k3s/storage/jenkins-data` | root | none | low | JCasC is code | | | |
| paperless (consume) | `pv-paperless-consume` / `paperless-consume-pvc` | `zfs-local` | label selector `app=paperless` | `main/nfs-share/paperless-consume` | subdir of hand-managed `nfs-share` | unknown (dataset not in `irl_zfs_datasets`) | low (transient) | n/a -- inbox | | | |
| paperless (media) | `pv-paperless-media` / `paperless-media-pvc` | `zfs-local` | label selector `app=paperless` | `main/paperless-media` | dataset | **none** | critical (irreplaceable scans) | backup-and-restore.md -- tested? | | | |
| paperless (data) | `pv-paperless-data` / `paperless-data-pvc` | `zfs-local` | label selector `app=paperless` | `main/paperless-data` | dataset | **none** | high | rebuildable from media + DB? confirm | | | |
| paperless (export) | `paperless-export-pvc` | `local-path` | dynamic, ephemeral between CronJob runs | `/var/lib/rancher/k3s/storage` | dynamic | none | none | n/a | | | |
| karakeep (data) | `pv-karakeep-data` / `karakeep-data` | `zfs-local` | explicit `volumeName` | `main/karakeep-data` | dataset | `service_data` | high | backup-and-restore.md -- tested? | | | |
| karakeep (meili) | `pv-karakeep-meilisearch` / `karakeep-meilisearch` | `zfs-local` | explicit `volumeName` | `main/karakeep-meilisearch` | dataset | `large_assets` | low (rebuildable index) | reindex | | | |
| satisfactory | `pv-satisfactory-config` / `satisfactory-data-pvc` | `zfs-local` | explicit `volumeName` | `main/satisfactory-config` | dataset | `service_data` | high (saves irreplaceable) | backup-and-restore.md -- tested? | | | |
| palworld | `pv-palworld-data` / `palworld-data-pvc` | `zfs-local` | explicit `volumeName` | `main/palworld-data` | dataset | `service_data` | high (saves irreplaceable) | backup-and-restore.md -- tested? | | | |
| nextcloud (app) | chart PVC | `local-path` | dynamic | `/var/lib/rancher/k3s/storage` | dynamic | none | medium | -- | | | |
| nextcloud (data) | chart `nextcloudData` PVC | `zfs-local` | dynamic against `zfs-local` -- no matching PV declared | unknown | unknown | none | high | -- | | | |
| vaultwarden | `vaultwarden-data` | `local-path` | dynamic | `/var/lib/rancher/k3s/storage` | dynamic | none | critical (password vault) | backup-and-restore.md -- tested? | | | |
| firefly | chart PVC | `local-path` | dynamic | `/var/lib/rancher/k3s/storage` | dynamic | none | high | -- | | | |
| redis / valkey | chart PVC | `local-path` | dynamic | `/var/lib/rancher/k3s/storage` | dynamic | none | low (cache) | n/a | | | |
| traefik | chart PVC (ACME storage) | `local-path` | dynamic | `/var/lib/rancher/k3s/storage` | dynamic | none | low | certs re-issue | | | |
| (unclaimed) | -- | -- | -- | `main/backups` | dataset | `service_data` | -- | -- | | | |
| (unclaimed) | -- | -- | -- | `main/artifacts` | dataset | `service_data` | -- | -- | | | |
| (unclaimed) | -- | -- | -- | `main/vms` | dataset (64K recordsize, 300G quota) | none | high (VM disks) | -- | | | |

The last four columns are deliberately blank. They are filled in by the
operator, not by this document:

- **Live binding verified** -- see the runbook step below.
- **Wave** -- which migration wave moves this service.
- **Storage decision** -- what happens to this volume once the cluster storage
  model is decided.

### Worked example of declared-vs-live divergence

`ansible/helm/postgres/values.yaml` declares `persistence.storageClass:
zfs-local` and `k3s.yml` creates `pv-postgres-data` on `zfs-local`. But
`helm-deploy.yml` overrides the CNPG cluster's storage at deploy time:

```yaml
cluster:
  storage:
    storageClass: local-path
```

The chart's own values are not what reaches the cluster. So the active
Postgres almost certainly binds a **dynamically provisioned `local-path`
volume**, not `pv-postgres-data` -- which, note, points at
`/var/lib/rancher/k3s/storage/postgres-data` on the ROOT filesystem anyway, not
at a ZFS dataset. Reading the repo alone would give you a confident, wrong
answer about where the database lives.

Vault shows the same shape (a `zfs-local` PV declared in `k3s.yml`, a
`local-path` storageClass in the chart values) and needs the same check.

### Runbook step (operator, outside this repo-only work)

Before any wave begins, reconcile this table against the live cluster:

```bash
kubectl get pv -o wide
kubectl get pvc -A -o wide
kubectl get pv <name> -o jsonpath='{.spec.hostPath.path}{"\n"}'
```

For each row: confirm which PV the PVC is actually **Bound** to, confirm the
`hostPath` on disk, and confirm whether that path is a ZFS dataset
(`zfs list -o name,mountpoint`) or a directory on root. Fill in the
**live binding verified** column. Any row whose live state contradicts the
declared state is a finding that must be resolved before that service is
migrated -- not carried forward.

## Ordering principle

**Stateless first, CNPG/Postgres last.**

Rationale: a stateless service that fails to migrate is a rollback of one
deployment. Postgres is the shared dependency of most of the stack, its data is
critical, its live storage binding is the one this repo demonstrably gets wrong,
and it is the workload where a botched migration is least recoverable. Moving it
last means every other workload has already proven the VM path, the network
model, and the storage model before the database goes anywhere near it.

## Open decisions

Neither of these is resolved by this document. Both must be decided before the
first wave, and both change the cutover checklist.

### (a) VM network model: bridged vs NAT plus host DNAT

Three things are coupled to this and must be considered together, not one at a
time:

1. **Traefik runs `hostNetwork: true`, binding 80/443 on the node.** In a VM
   cluster the "node" is a guest. Whether the LAN and tailnet can still reach
   80/443 depends entirely on this decision.
2. **CoreDNS runs `hostNetwork: true` on port 53** and is the target of
   Tailscale split DNS. Moving it into a guest moves the DNS listener; the
   split-DNS configuration in `terraform/environments/homelab/tailscale/split-dns/`
   points somewhere and that somewhere changes.
3. **ADR-0005's LAN NodePort path** for devices without Tailscale (the Steam
   Deck at `192.168.2.2:30777` / `:30211`). That ADR's central finding was that
   NodePort traffic arrives with its ORIGINAL LAN source IP, which is what
   makes the NetworkPolicy layer necessary. A NAT-plus-DNAT model changes the
   source address the pod sees, and the game protocols require **symmetric
   ports end to end** -- Satisfactory advertises its messaging port to clients,
   so no port translation is permissible anywhere in the path.

Bridged keeps guests as first-class LAN citizens and preserves the ADR-0005
assumptions most directly, at the cost of LAN addressing and firewall surface.
NAT plus host DNAT keeps guests off the LAN but must reproduce, per port, both
the symmetry and the source-address behavior ADR-0005 depends on.

Out of scope until this is decided: implementing either model, and moving
libvirt's nftables rules into the managed `nftables.conf.j2` template.

### (b) Cluster storage model: host-owned datasets vs data inside VM disks

Two shapes:

- **virtiofs or NFS from host-owned ZFS datasets.** The host keeps owning the
  data; guests mount it. Snapshots stay per-dataset and keep their current
  granularity and sanoid policies. Recordsize tuning (`garage-data` at 1M,
  `vms` at 64K) stays meaningful and stays where it is.
- **Data inside VM disks.** Everything a guest needs lives in its qcow2. Simple
  and self-contained, but the snapshot unit becomes the whole VM disk on the
  `main/vms` dataset -- one 64K-recordsize dataset for every workload,
  regardless of access pattern -- and the per-dataset sanoid policies stop
  applying. Restoring one service means restoring a VM.

Consequences beyond storage: whichever way this goes, the `irl.dev/tier: data`
node label stops meaning what it currently means. Today `home` is the data-tier
node because the data is on it. Once workloads live in guests, either the label
follows the data (host-owned datasets, so no node is data-tier in the old
sense) or it follows the guest that holds the disk. That relabeling, and the
`nodeSelector`s in the chart values that depend on it, follows this decision.

Also unresolved by this document: the snapshot-coverage gaps the inventory
above surfaces (`garage-data` and both paperless datasets have no sanoid
section). Whether to fix those before or during the migration is a call for the
first wave's checklist -- but fixing them is cheaper than discovering the gap
during a restore.

## Cutover checklist skeleton (per wave)

Fill one of these in per wave. It is a skeleton on purpose: the network and
storage decisions determine several of the steps.

**Before**

- [ ] Wave scope named: which services, and why these together.
- [ ] Measurement recorded for each service: query, aggregation, window,
      timestamp, resulting number, and the reserves added on top.
- [ ] Live storage bindings verified for every volume in the wave (the runbook
      step above); the inventory table's **live binding verified** column filled
      in for those rows.
- [ ] Restore procedure for each critical volume in the wave located AND
      tested -- an untested restore is not a restore.
- [ ] New VM sized and declared in `irl_vms`; `irl_vm_ram_budget_gb` raised to
      cover it by memory actually freed in the previous wave.
- [ ] `vms.yml` run: gold master resolved, disk created, VM joined the tailnet.
- [ ] VM joined the cluster as a k3s agent (`[k3s_agents]` in `hosts.ini`), with
      node labels and taints applied.

**Cutover**

- [ ] Service quiesced on the host node.
- [ ] Data moved or remounted per the storage decision.
- [ ] Service redeployed onto the VM node.
- [ ] Health verified: pod ready, service reachable by its normal path
      (Traefik + split DNS internally; Cloudflare Access only for JobOps and
      gunio-mcp; LAN NodePorts only for the game servers).
- [ ] `cd tests && task smoke` green; targeted acceptance tests for the wave's
      services green.

**After**

- [ ] Host-side workload removed, not merely stopped.
- [ ] Memory actually reclaimed, measured on the host.
- [ ] `irl_vm_ram_budget_gb` updated to reflect it.
- [ ] Rollback path recorded: what to do if the service misbehaves a day later.

## Host end-state

What remains on metal when the migration is done -- **to be confirmed** as the
waves proceed; this is the intent, not a settled list:

- libvirt / KVM and the VM disk store (`main/vms`)
- ZFS, its datasets, and sanoid snapshot automation
- backups
- a monitoring agent shipping host metrics
- Tailscale on the host
- SSH, nftables, and the base hardening from `security-hardening.yml`

Explicitly NOT on the host at the end: k3s, Traefik, CoreDNS, and every
workload chart. Whether CoreDNS and Traefik can move at all is question (a).
