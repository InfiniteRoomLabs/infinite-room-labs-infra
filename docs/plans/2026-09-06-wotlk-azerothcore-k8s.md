# WotLK (AzerothCore + Playerbots) on k3s, tailnet-only

Date: 2026-09-06. Status: implementing (branch `feat/wotlk-azerothcore`).

## Goal

Run the dads-mmo-lab "WoW WotLK" stack (the mod-playerbots fork of AzerothCore, 1600-2000 AI players) in the `irl` namespace, reachable only over the tailnet, and point a stock 3.3.5a client (ChromieCraft build) at it from the laptop.

## Prior work

A 2026-08-08 claude.ai assessment ranked the five dads-mmo-lab games for k8s migration difficulty (OpenMU easiest, 2009scape hardest) and called WotLK the one worth doing first because it exercises the whole pipeline: image build, data hydration, DB import, advertised-address handling. Its conclusions carried over here: the server needs the client-derived data set (dbc/maps/vmaps/mmaps, ~15G, downloadable pre-extracted), the Playerbot fork must be compiled from source, and the realm address the authserver hands out must be an address the client can actually reach. That assessment lives in the local claude.ai export, not in this repo.

The user previously ran the dads-mmo-lab installer on a Steam Deck with the homelab as a remote buildx builder; the buildkit state volume (`buildx_buildkit_homelab0_state`) on the homelab is the warm cache this deployment's build reuses.

## Design

Follows ADR 0005 (symmetric NodePorts for game servers) minus its two LAN layers.

- **Exposure**: authserver listens on 30724, worldserver on 30085, each behind its own NodePort Service on the same numbers. nftables already accepts `tailscale0` and the namespace's `allow-ingress-tailscale` NetworkPolicy already covers NodePorts, so tailnet clients work with zero new rules. No nftables LAN entries and no `allow-wotlk-game-lan` policy are added; that omission is the tailnet-only guarantee.
- **Realm advertisement**: `acore_auth.realmlist` row 1 is stamped with `address=100.86.213.22, port=30085` by the worldserver's `db-import` initContainer on every start. Client `realmlist.wtf`: `set realmlist wow.lab.infiniteroomlabs.cloud:30724` (split-DNS name from the `irl_services` registry).
- **Images**: built on the homelab (24 threads) by `scripts/wotlk-build-images.sh` and imported straight into k3s containerd; no registry. The worldserver image gets one extra layer (`docker/ac-wotlk-worldserver/Dockerfile`) restoring `/azerothcore/modules`, which the upstream runtime stage drops but mod-playerbots' SQL auto-update needs. A copy of the image tarball sits in `/var/lib/rancher/k3s/agent/images/` so k3s re-imports it after a restart. Trade-off accepted knowingly: the images exist on one node only, so the chart pins `nodeSelector: irl.dev/tier: data`.
- **Database**: MySQL 8.4 StatefulSet inside the chart, first MySQL in the cluster. Root password from `wotlk-secrets` (bw-sync lane, item `wotlk-mysql-root-password`).
- **Hydration and import** are initContainers on the worldserver pod (client-data download, then dbimport + realmlist stamp), not Jobs: nothing to garbage-collect, idempotent on restart, and helm hooks would have blocked the ansible run for the duration of a 15G download. The authserver's initContainer simply waits for `acore_auth.realmlist` to exist.
- **Console**: worldserver container runs with stdin/tty; `scripts/wotlk-console.sh` (a `kubectl attach` wrapper that swallows Ctrl-C and detaches on Ctrl-]) replaces `docker attach` for `account create`. SOAP stays off.
- **Storage**: ZFS datasets `main/wotlk-db` (20G, recordsize 16K, chown 999) and `main/wotlk-data` (30G, chown 1000) as hostPath PVs on `zfs-local`.

Skipped on purpose: Wrath Unbound (no longer in dads-mmo-lab), MetalLB/LoadBalancer (cluster runs with servicelb disabled), LAN access, phpmyadmin, ac-tools.

## Files

- `helm-charts/charts/irl-wotlk/` (chart 0.1.0)
- `ansible/helm/wotlk/values.yaml`, `ansible/playbooks/helm-deploy.yml` (tag `wotlk`), `ansible/playbooks/zfs.yml`, `ansible/playbooks/k3s.yml`, `ansible/inventory/group_vars/all/main.yml`
- `scripts/wotlk-build-images.sh`, `scripts/wotlk-console.sh`, `docker/ac-wotlk-worldserver/Dockerfile`, `scripts/bw-sync-config.yaml`
- `ansible/docs/runbooks/wotlk-down.md`

## Client (laptop)

ChromieCraft's 3.3.5a client bundle, run through Steam as a non-Steam game with GE-Proton (installed via ProtonUp-Qt), set in the shortcut's Properties > Compatibility. `Data/enUS/realmlist.wtf` and `WTF/Config.wtf` point at `wow.lab.infiniteroomlabs.cloud:30724`; `Config.wtf` also sets windowed/maximized mode and skips the intro movie. Verified in-world 2026-09-07.

Lessons from the first launch, so nobody repeats them:

- **Never put a wine/Proton prefix inside the game directory.** The client walks its own folder tree at startup; a prefix's `drive_c/users/<you>` symlinks lead back into `$HOME`, so the walk crawled the whole home directory (every `node_modules`) and the window sat grey and "not responding" for minutes. Symptom in a stack sample: main thread stuck in `NtQueryDirectoryFile` / `NtOpenFile`. Prefixes live in `~/Games/.wine-prefixes/`.
- `SET gxApi "OpenGL"` is not supported by this build ("Failed to find a suitable display device"). D3D9 via DXVK is fine.
- System wine on this laptop cannot get `wine32:i386` because the Sury PHP repo's newer `libgd3:amd64` blocks Ubuntu's `libgd3:i386`. GE-Proton bundles its own 32-bit wine, which is why Steam is the runner here.
- Steam Overlay off and `PROTON_USE_WINED3D=1` were tried during diagnosis; neither was the cause and neither is required.

## Open questions

- Whether the k3s image GC ever evicts the imported images under disk pressure in practice; the tarball fallback covers a restart but not a GC pass followed by a pod reschedule without restart. If it bites, the fix is the Gitea OCI registry (`docs/plans/2026-07-21-gitea-registry-forgejo-migration.md`).
- LLM-augmented bots (mod-ollama-chat / mod-llm-chatter, surveyed in the 2026-08-08 assessment) are a separate follow-up once the base server is stable.
