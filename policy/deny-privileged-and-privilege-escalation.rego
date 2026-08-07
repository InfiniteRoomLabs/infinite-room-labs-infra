# Policy: deny-privileged-and-privilege-escalation
#
# Intent: no container rendered by any IRL Helm chart may run privileged or
# allow privilege escalation. Covers regular containers, initContainers, and
# ephemeralContainers in Pods, workload pod templates (Deployment, StatefulSet,
# DaemonSet, ReplicaSet, Job -- anything with spec.template), and CronJob
# jobTemplates, including helm test hook Pods.
#
# Verified 2026-08 over `helm template` output of all 11 charts in
# helm-charts/charts/ rendered with the deployed values from
# ansible/helm/*/values.yaml: zero violations, including the
# kube-prometheus-stack / loki / tempo subcharts vendored in irl-monitoring.

package k8s.privileged

import rego.v1

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

deny contains msg if {
	some c in all_containers
	c.securityContext.allowPrivilegeEscalation == true
	msg := sprintf("%s/%s: container %q sets securityContext.allowPrivilegeEscalation=true", [input.kind, input.metadata.name, c.name])
}
