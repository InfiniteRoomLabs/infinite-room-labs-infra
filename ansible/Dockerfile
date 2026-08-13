# Containerized Ansible runner for Infinite Room Labs homelab automation.
# Keeps the operator's workstation clean -- no local Ansible install needed.
#
# Build:  docker build -t irl-ansible ansible/
# Usage:  ./ansible/run-ansible.sh playbook site.yml

FROM python:3.12-slim

ARG ANSIBLE_CORE_VERSION=2.18.18
# helm binary version -- must match what k3s cluster supports
ARG HELM_VERSION=3.16.4

RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-client \
      git \
      sshpass \
      curl \
    && rm -rf /var/lib/apt/lists/*

# Install Helm binary
RUN curl -fsSL https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz \
    | tar -xz -C /usr/local/bin --strip-components=1 linux-amd64/helm

# Install kubectl (same minor as k3s v1.31)
RUN curl -fsSL "https://dl.k8s.io/release/v1.31.4/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

RUN pip install --no-cache-dir \
      "ansible-core==${ANSIBLE_CORE_VERSION}" \
      jmespath \
      kubernetes \
      openshift

WORKDIR /ansible
COPY requirements.yml /ansible/requirements.yml
RUN ansible-galaxy install -r /ansible/requirements.yml

ENTRYPOINT ["ansible-playbook"]
CMD ["--help"]
