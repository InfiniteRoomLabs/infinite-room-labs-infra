# Introspection helper -- NOT an enforced policy.
#
# Lives outside policy/ on purpose so the enforcing run
# (`conftest test --policy policy ...`) never loads it. The conftest workflow
# runs it separately with --output json purely to enumerate facts about the
# rendered manifests.
#
# It emits one "failure" per container that currently sets
# securityContext.readOnlyRootFilesystem=true, formatted as the exact baseline
# key used by policy/readonly-rootfs-ratchet.rego. The workflow diffs that
# observed set against the ratchet baseline and fails on any baseline key that
# is missing -- catching a baselined workload being renamed or deleted, which
# the ratchet rule itself cannot see (conftest evaluates one document at a
# time, so a document that no longer exists is never checked).
#
# The pod_specs / all_containers helpers below are a deliberate copy of the
# ones in readonly-rootfs-ratchet.rego. Enumerating with the SAME rego
# semantics that build the keys is the point: a shell/YAML reimplementation
# could disagree about which container shapes count and quietly report a key
# as absent (or present) when the policy would say otherwise. If the ratchet's
# container coverage changes, change it here too.

package rofs_observed

import rego.v1

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
	c.securityContext.readOnlyRootFilesystem == true
	msg := sprintf("%s/%s/%s", [input.kind, input.metadata.name, c.name])
}
