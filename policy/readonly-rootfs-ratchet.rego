# Policy: readonly-rootfs-ratchet
#
# Intent: containers that already render with
# securityContext.readOnlyRootFilesystem=true must keep it. This is a ratchet,
# not a blanket mandate -- a blanket require-readOnlyRootFilesystem would fail
# today on gitea, paperless, satisfactory, palworld, garage, openviking,
# vaultwarden, grafana, and tempo. Instead the policy carries an explicit
# baseline of containers observed with readOnlyRootFilesystem=true in the
# 2026-08 rendered output, and denies if any baselined container drops or
# unsets it. Passes today by construction.
#
# Baseline keys are "<kind>/<metadata.name>/<container name>" and therefore
# depend on the release names used at render time. The conftest workflow
# renders with the same release names ansible uses (postgresql, valkey, gitea,
# monitoring, ...; jobops for irl-jobops), so keys stay stable.
#
# When a NEW container gains readOnlyRootFilesystem=true, add it here to
# ratchet it in. When a baselined workload is intentionally renamed or removed,
# update the baseline in the same PR.

package k8s.rofs_ratchet

import rego.v1

baseline := {
	# irl-jobops (release: jobops)
	"Deployment/jobops-irl-jobops/job-ops",
	"Deployment/jobops-irl-jobops/cloudflared",
	"CronJob/jobops-irl-jobops-cron-daily-agentic-ai/trigger",
	"CronJob/jobops-irl-jobops-cron-daily-midlevel-sustainable/trigger",
	"CronJob/jobops-irl-jobops-cron-daily-qa-automation/trigger",
	# irl-valkey (release: valkey)
	"Deployment/valkey/valkey",
	"Deployment/valkey/valkey-init",
	# irl-postgres (release: postgresql) -- CNPG operator subchart
	"Deployment/postgresql-cloudnative-pg/manager",
	# irl-monitoring (release: monitoring) -- vendored subcharts
	"DaemonSet/monitoring-prometheus-node-exporter/node-exporter",
	"DaemonSet/loki-canary/loki-canary",
	"Deployment/monitoring-kube-state-metrics/kube-state-metrics",
	"Deployment/monitoring-kube-prometheus-operator/kube-prometheus-stack",
	"Deployment/monitoring-loki-gateway/nginx",
	"StatefulSet/monitoring-loki/loki",
	"StatefulSet/monitoring-loki/loki-sc-rules",
	"Job/monitoring-kube-prometheus-admission-create/create",
	"Job/monitoring-kube-prometheus-admission-patch/patch",
}

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

deny contains msg if {
	some c in all_containers
	key := sprintf("%s/%s/%s", [input.kind, input.metadata.name, c.name])
	key in baseline
	not c.securityContext.readOnlyRootFilesystem == true
	msg := sprintf("%s dropped readOnlyRootFilesystem=true (ratchet: baselined containers must keep it)", [key])
}
