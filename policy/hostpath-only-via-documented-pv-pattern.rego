# Policy: hostpath-only-via-documented-pv-pattern
#
# Intent: rendered chart manifests must not declare hostPath pod volumes or
# hostPath PersistentVolumes. hostPath storage enters the cluster only via the
# documented Ansible pattern: PVs created in ansible/playbooks/k3s.yml
# (pointing at ZFS dataset mountpoints, chowned by ansible/playbooks/zfs.yml)
# and consumed by charts through PVC spec.volumeName.
#
# Single documented exemption: the kube-prometheus-stack node-exporter
# DaemonSet (vendored in irl-monitoring) mounts /proc, /sys, and / -- standard
# and required for node metrics. It is the only hostPath in all rendered
# output as of 2026-08; everything else renders PVCs only.

package k8s.hostpath

import rego.v1

# The node-exporter DaemonSet is the sole allowed hostPath consumer, and only
# for its three documented mounts. The exemption is per-volume, not
# object-wide: a future kube-prometheus-stack bump that adds a new hostPath
# mount to node-exporter is caught rather than silently exempted.
exempt_volume(v) if {
	input.kind == "DaemonSet"
	input.metadata.labels["app.kubernetes.io/name"] == "prometheus-node-exporter"
	v.hostPath.path in {"/proc", "/sys", "/"}
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

deny contains msg if {
	some ps in pod_specs
	some v in ps.volumes
	v.hostPath
	not exempt_volume(v)
	msg := sprintf("%s/%s uses hostPath volume %q (%s); use the Ansible PV + PVC spec.volumeName pattern (ansible/playbooks/k3s.yml)", [input.kind, input.metadata.name, v.name, v.hostPath.path])
}

deny contains msg if {
	input.kind == "PersistentVolume"
	input.spec.hostPath
	msg := sprintf("PersistentVolume/%s declares hostPath; PVs are Ansible-managed, charts must not create them", [input.metadata.name])
}
