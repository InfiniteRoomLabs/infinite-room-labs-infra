# Policy: deny-privileged-and-privilege-escalation
#
# Intent: no container rendered by any IRL Helm chart may run privileged or
# allow privilege escalation. Covers regular containers, initContainers, and
# ephemeralContainers in Pods, workload pod templates (Deployment, StatefulSet,
# DaemonSet, ReplicaSet, Job -- anything with spec.template), and CronJob
# jobTemplates, including helm test hook Pods.
#
# allowPrivilegeEscalation is checked for an EXPLICIT false, not merely for the
# absence of true. Kubernetes treats an omitted allowPrivilegeEscalation as
# allowed (it defaults to true for non-privileged containers unless the
# container also sets a restrictive no_new_privs path), so "field not set" is
# the insecure default, not a neutral one. A policy that only denied an
# explicit true would pass every container that simply never mentions the
# field -- which is most of them.
#
# Requiring the explicit false newly fails 26 containers that render today,
# almost all of them in upstream/vendored charts we do not author. Rather than
# park the policy as a non-enforced candidate, those containers are carried in
# an explicit shrink-only baseline below and everything else is enforced. The
# result: no NEW container can enter the cluster without setting
# allowPrivilegeEscalation: false.
#
# Baseline rules:
#   - SHRINK ONLY. Entries come out when a container is fixed (set
#     allowPrivilegeEscalation: false, or override it via
#     ansible/helm/<svc>/values.yaml for a vendored subchart). Never add an
#     entry to make a new violation pass -- fix the container instead.
#   - The baseline excuses OMISSION only. An explicit
#     allowPrivilegeEscalation: true always denies, baselined or not, and
#     securityContext.privileged: true always denies.
#   - Keys are "<kind>/<metadata.name>/<container name>" and depend on the
#     release names used at render time, same as
#     policy/readonly-rootfs-ratchet.rego. The conftest workflow renders with
#     the release names ansible uses.
#   - A stale entry (workload renamed or removed) fails safe: the baseline
#     simply stops matching and the renamed container is enforced, so no
#     presence check is needed here. The readonly-rootfs ratchet is the
#     opposite case and does need one -- see .github/workflows/conftest.yml.
#
# Verified 2026-08 over `helm template` output of all 11 charts in
# helm-charts/charts/ rendered with the deployed values (ansible/helm/*/values.yaml
# plus the inline irl-postgres values from ansible/playbooks/helm-deploy.yml)
# and of cnpg/cloudnative-pg 0.28.3: zero violations outside the baseline.

package k8s.privileged

import rego.v1

# Containers that render WITHOUT an explicit allowPrivilegeEscalation: false
# as of 2026-08. Shrink-only -- see the header.
allow_missing_ape_baseline := {
	# irl-garage (release: garage)
	"Deployment/garage/garage",
	"Deployment/garage/garage-webui",
	# irl-gitea (release: gitea), incl. the vendored gitea-10.6.0 subchart
	"Deployment/gitea/gitea",
	"Deployment/gitea/configure-gitea",
	"Deployment/gitea/init-app-ini",
	"Deployment/gitea/init-directories",
	"Pod/gitea-test-connection/wget",
	# irl-monitoring (release: monitoring) -- vendored subcharts
	"DaemonSet/monitoring-prometheus-node-exporter/node-exporter",
	"Deployment/monitoring-grafana/init-chown-data",
	"Deployment/monitoring-opentelemetry-collector/opentelemetry-collector",
	"StatefulSet/monitoring-tempo/tempo",
	"Pod/loki-helm-test/loki-helm-test",
	"Pod/monitoring-grafana-test/monitoring-test",
	# irl-openviking (release: openviking)
	"Deployment/openviking/openviking",
	# irl-palworld (release: palworld)
	"Deployment/palworld/palworld",
	# irl-paperless (release: paperless)
	"Deployment/paperless/paperless",
	"Deployment/paperless-gotenberg/gotenberg",
	"Deployment/paperless-tika/tika",
	"CronJob/paperless-backup/exporter",
	"CronJob/paperless-backup/uploader",
	# irl-satisfactory (release: satisfactory)
	"Deployment/satisfactory/satisfactory",
	# irl-valkey (release: valkey)
	"Deployment/valkey/valkey",
	"Deployment/valkey/valkey-init",
	"Deployment/valkey/metrics",
	"Pod/valkey-test-auth-existing/test-auth",
	# irl-vaultwarden (release: vaultwarden)
	"StatefulSet/vaultwarden/vaultwarden",
}

# Pod specs from every shape of object that carries one.
pod_specs contains ps if {
	input.kind == "Pod"
	ps := input.spec
}

pod_specs contains ps if {
	ps := input.spec.template.spec
}

pod_specs contains ps if {
	ps := input.spec.jobTemplate.spec.template.spec
}

all_containers contains c if {
	some ps in pod_specs
	some c in ps.containers
}

all_containers contains c if {
	some ps in pod_specs
	some c in ps.initContainers
}

all_containers contains c if {
	some ps in pod_specs
	some c in ps.ephemeralContainers
}

deny contains msg if {
	some c in all_containers
	c.securityContext.privileged == true
	msg := sprintf("%s/%s: container %q sets securityContext.privileged=true", [input.kind, input.metadata.name, c.name])
}

# Explicit opt-in to escalation. Never excused by the baseline.
deny contains msg if {
	some c in all_containers
	c.securityContext.allowPrivilegeEscalation == true
	msg := sprintf("%s/%s: container %q sets securityContext.allowPrivilegeEscalation=true", [input.kind, input.metadata.name, c.name])
}

# Omitted (or non-boolean) allowPrivilegeEscalation. Kubernetes reads the
# omission as allowed, so this is a violation unless the container is
# baselined.
deny contains msg if {
	some c in all_containers
	not c.securityContext.allowPrivilegeEscalation == true
	not c.securityContext.allowPrivilegeEscalation == false
	key := sprintf("%s/%s/%s", [input.kind, input.metadata.name, c.name])
	not key in allow_missing_ape_baseline
	msg := sprintf("%s: container %q does not set securityContext.allowPrivilegeEscalation=false (an omitted field defaults to allowed)", [key, c.name])
}
