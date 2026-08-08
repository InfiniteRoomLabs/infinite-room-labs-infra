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
# monitoring, ...; jobops for irl-jobops, cnpg-operator for the separately
# installed cnpg/cloudnative-pg release), so keys stay stable.
#
# When a NEW container gains readOnlyRootFilesystem=true, add it here to
# ratchet it in. When a baselined workload is intentionally renamed or removed,
# update the baseline in the same PR.
#
# LIMIT OF THIS RULE, and how it is covered: conftest evaluates one document at
# a time, so a rule can only fire on a document that exists. If a baselined
# workload is renamed or deleted, its key is simply never evaluated and the
# guarantee disappears silently -- a green build that proves nothing. The
# presence half of the ratchet therefore lives outside rego: the conftest
# workflow diffs this baseline against the container keys actually observed in
# the rendered output and fails on any baseline key that is absent. That is
# why the block below is fenced with ROFS-BASELINE-BEGIN/END markers -- the
# workflow parses them. Keep the one-key-per-line quoted format.

package k8s.rofs_ratchet

import rego.v1

baseline := {
	# ROFS-BASELINE-BEGIN
	# irl-jobops (release: jobops)
	"Deployment/jobops-irl-jobops/job-ops",
	"Deployment/jobops-irl-jobops/cloudflared",
	"CronJob/jobops-irl-jobops-cron-daily-agentic-ai/trigger",
	"CronJob/jobops-irl-jobops-cron-daily-midlevel-sustainable/trigger",
	"CronJob/jobops-irl-jobops-cron-daily-qa-automation/trigger",
	# irl-valkey (release: valkey)
	"Deployment/valkey/valkey",
	"Deployment/valkey/valkey-init",
	# cnpg/cloudnative-pg 0.28.3 (release: cnpg-operator, ns cnpg-system) --
	# installed as its own release by ansible/playbooks/helm-deploy.yml, NOT
	# as an irl-postgres subchart (irl-postgres deploys with
	# operator.enabled: false).
	"Deployment/cnpg-operator-cloudnative-pg/manager",
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
	# ROFS-BASELINE-END
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
